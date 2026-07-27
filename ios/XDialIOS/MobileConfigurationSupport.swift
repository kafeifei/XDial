import Foundation
import CoreFoundation
import SwiftUI
import UniformTypeIdentifiers

enum MobileConfigurationError: Error, Equatable {
    case invalidJSON
    case unsupportedFormat
    case missingField(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case unsupportedLineType(String)
    case invalidActiveMode
    case invalidReference(String)
    case fileTooLarge
}

extension MobileConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The selected file is not a valid XDial JSON configuration."
        case .unsupportedFormat:
            return "This XDial configuration format is not supported."
        case .missingField(let field):
            return "The configuration is missing the required field: \(field)."
        case .invalidIdentifier(let kind):
            return "The configuration contains an empty \(kind) identifier."
        case .duplicateIdentifier(let kind):
            return "The configuration contains a duplicate \(kind) identifier."
        case .unsupportedLineType(let type):
            return "The configuration contains an unsupported line type: \(type)."
        case .invalidActiveMode:
            return "The active mode does not exist in this configuration."
        case .invalidReference(let reference):
            return "The configuration contains an invalid reference: \(reference)."
        case .fileTooLarge:
            return "The selected configuration is too large."
        }
    }
}

private struct MobileConfigurationEnvelope: Codable {
    static let currentFormat = "xdial-mobile-configuration"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let containsCredentials: Bool
    let containsSubscriptionURLs: Bool
    let profile: Profile

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case containsCredentials = "contains_credentials"
        case containsSubscriptionURLs = "contains_subscription_urls"
        case profile
    }
}

enum MobileConfigurationService {
    // 最终扩展配置硬上限为 2 MiB；导入也使用同一边界，避免先接受一份注定
    // 无法跨进程启动的巨大 profile。
    static let maxImportBytes = 2 * 1_024 * 1_024

    static func exportData(for profile: Profile) throws -> Data {
        let envelope = MobileConfigurationEnvelope(
            format: MobileConfigurationEnvelope.currentFormat,
            schemaVersion: MobileConfigurationEnvelope.currentSchemaVersion,
            containsCredentials: false,
            containsSubscriptionURLs: false,
            profile: sanitizedForExport(profile)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func importProfile(from data: Data) throws -> Profile {
        guard data.count <= maxImportBytes else {
            throw MobileConfigurationError.fileTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MobileConfigurationError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw MobileConfigurationError.invalidJSON
        }

        let profileObject: [String: Any]
        if root["format"] != nil || root["profile"] != nil {
            guard root["format"] as? String == MobileConfigurationEnvelope.currentFormat,
                  let schema = root["schema_version"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(),
                  schema.doubleValue == Double(MobileConfigurationEnvelope.currentSchemaVersion),
                  let nestedProfile = root["profile"] as? [String: Any] else {
                throw MobileConfigurationError.unsupportedFormat
            }
            profileObject = nestedProfile
        } else {
            profileObject = root
        }

        try validateRequiredFields(in: profileObject)

        let profileData: Data
        do {
            profileData = try JSONSerialization.data(withJSONObject: profileObject)
        } catch {
            throw MobileConfigurationError.invalidJSON
        }

        var profile: Profile
        do {
            profile = try JSONDecoder().decode(Profile.self, from: profileData)
        } catch {
            throw MobileConfigurationError.invalidJSON
        }
        normalizeLegacyLineTypes(in: &profile)
        sanitizeRuntimeProbeAddresses(in: &profile)
        try validate(profile)
        return profile
    }

    static func sanitizedForExport(_ profile: Profile) -> Profile {
        var sanitized = profile
        for ruleIndex in sanitized.ruleSets.indices {
            guard sanitized.ruleSets[ruleIndex].type == "url" else { continue }
            // 签名地址的 token 既可能在 query，也可能在 path。截掉其中一部分会生成
            // 看似有效、实际必然失败的规则，因此导出时清空并停用，等待用户重新填写。
            sanitized.ruleSets[ruleIndex].url = ""
            sanitized.ruleSets[ruleIndex].enabled = false
        }
        for index in sanitized.lines.indices {
            removeCredentials(from: &sanitized.lines[index])
        }
        for subscriptionIndex in sanitized.subscriptions.indices {
            sanitized.subscriptions[subscriptionIndex].url = ""
            sanitized.subscriptions[subscriptionIndex].testURL = ""
            for groupIndex in sanitized.subscriptions[subscriptionIndex].proxyGroups.indices {
                sanitized.subscriptions[subscriptionIndex].proxyGroups[groupIndex].url = ""
            }
            sanitized.subscriptions[subscriptionIndex].rules.removeAll { $0.type.uppercased() == "RULE-SET" }
            for lineIndex in sanitized.subscriptions[subscriptionIndex].lines.indices {
                removeCredentials(from: &sanitized.subscriptions[subscriptionIndex].lines[lineIndex])
            }
        }
        return sanitized
    }

    private static func removeCredentials(from line: inout Line) {
        line.vpnUsername = ""
        line.vpnPassword = ""
        line.trojanPassword = ""
        line.ssPassword = ""
        line.vmessUUID = ""
        line.vpnServer = removingURLCredentials(line.vpnServer)
        line.trojanServer = removingURLCredentials(line.trojanServer)
        line.ssServer = removingURLCredentials(line.ssServer)
        line.vmessServer = removingURLCredentials(line.vmessServer)
    }

    private static func normalizeLegacyLineTypes(in profile: inout Profile) {
        for index in profile.lines.indices where profile.lines[index].type == "ss" {
            profile.lines[index].type = "shadowsocks"
        }
        for subscriptionIndex in profile.subscriptions.indices {
            for lineIndex in profile.subscriptions[subscriptionIndex].lines.indices
            where profile.subscriptions[subscriptionIndex].lines[lineIndex].type == "ss" {
                profile.subscriptions[subscriptionIndex].lines[lineIndex].type = "shadowsocks"
            }
        }
    }

    private static func sanitizeRuntimeProbeAddresses(in profile: inout Profile) {
        for subscriptionIndex in profile.subscriptions.indices {
            // 移动生成器只使用固定探测地址。导入文件里的自定义地址既不会生效，
            // 也不应被保留成下一次运行时请求入口。
            if !profile.subscriptions[subscriptionIndex].testURL.isEmpty {
                profile.subscriptions[subscriptionIndex].testURL = "https://www.gstatic.com/generate_204"
            }
            for groupIndex in profile.subscriptions[subscriptionIndex].proxyGroups.indices {
                profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].url = ""
            }
        }
    }

    private static func removingURLCredentials(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue),
              components.scheme != nil, components.host != nil else { return rawValue }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    private static func validateRequiredFields(in object: [String: Any]) throws {
        for field in ["lines", "rule_sets", "modes", "subscriptions"] {
            guard object[field] is [Any] else {
                throw MobileConfigurationError.missingField(field)
            }
        }
        guard object["active_mode_id"] is String else {
            throw MobileConfigurationError.missingField("active_mode_id")
        }
    }

    private static func validate(_ profile: Profile) throws {
        try validateIDs(profile.lines.map(\.id), kind: "line")
        try validateIDs(profile.ruleSets.map(\.id), kind: "rule")
        try validateIDs(profile.modes.map(\.id), kind: "mode")
        try validateIDs(profile.subscriptions.map(\.id), kind: "subscription")

        let supportedLineTypes: Set<String> = [
            "direct", "vpn", "trojan", "shadowsocks", "ss", "vmess", "tailscale",
        ]
        let allLines = profile.lines + profile.subscriptions.flatMap(\.lines)
        if let unsupported = allLines.first(where: { !supportedLineTypes.contains($0.type) }) {
            throw MobileConfigurationError.unsupportedLineType(unsupported.type)
        }
        for subscription in profile.subscriptions {
            try validateIDs(subscription.lines.map(\.id), kind: "subscription line")
            let lineNames = subscription.lines.map(\.name)
            try validateIDs(lineNames, kind: "subscription node name")
            let lineNameSet = Set(lineNames)
            guard ["selector", "urltest", "url-test"].contains(subscription.strategy.lowercased()) else {
                throw MobileConfigurationError.invalidReference("subscription.strategy")
            }
            if !subscription.selected.isEmpty, !lineNameSet.contains(subscription.selected) {
                throw MobileConfigurationError.invalidReference("subscription.selected")
            }
            let groupNames = subscription.proxyGroups.map(\.name)
            try validateIDs(groupNames, kind: "subscription group name")
            let groupNameSet = Set(groupNames)
            guard subscription.proxyGroups.allSatisfy({
                ["select", "selector", "url-test", "urltest"].contains($0.type.lowercased())
            }) else {
                throw MobileConfigurationError.invalidReference("subscription.group.type")
            }
            let builtInMembers: Set<String> = [
                "DIRECT", "Direct", "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK",
            ]
            let validMembers = lineNameSet.union(groupNameSet).union(builtInMembers)
            for group in subscription.proxyGroups {
                guard !group.proxies.isEmpty,
                      group.proxies.allSatisfy(validMembers.contains) else {
                    throw MobileConfigurationError.invalidReference("subscription.group.member")
                }
                if !group.selected.isEmpty, !group.proxies.contains(group.selected) {
                    throw MobileConfigurationError.invalidReference("subscription.group.selected")
                }
            }
            let supportedSubscriptionRuleTypes = Set([
                "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP", "FINAL",
            ])
            guard subscription.rules.allSatisfy({
                supportedSubscriptionRuleTypes.contains($0.type.uppercased())
            }) else {
                throw MobileConfigurationError.invalidReference("subscription.rule.type")
            }
            let validRuleTargets = groupNameSet.union(["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK"])
            guard subscription.rules.allSatisfy({ validRuleTargets.contains($0.group) }) else {
                throw MobileConfigurationError.invalidReference("subscription.rule.group")
            }
        }

        let lineIDs = Set(profile.lines.map(\.id))
        let ruleIDs = Set(profile.ruleSets.map(\.id))
        let subscriptionIDs = Set(profile.subscriptions.map(\.id))
        let modeIDs = Set(profile.modes.map(\.id))

        if !profile.activeModeID.isEmpty, !modeIDs.contains(profile.activeModeID) {
            throw MobileConfigurationError.invalidActiveMode
        }
        if profile.activeModeID.isEmpty, !profile.modes.isEmpty {
            throw MobileConfigurationError.invalidActiveMode
        }

        let supportedRuleTypes: Set<String> = ["url", "manual"]
        for rule in profile.ruleSets {
            guard supportedRuleTypes.contains(rule.type) else {
                throw MobileConfigurationError.invalidReference("rule.type")
            }
            if rule.enabled, rule.type == "url",
               rule.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MobileConfigurationError.invalidReference("rule.url")
            }
            if !rule.url.isEmpty, rule.type == "url", !isHTTPSRemoteAddress(rule.url) {
                throw MobileConfigurationError.invalidReference("rule.url")
            }
            if rule.type == "url", !["", "auto", "srs", "json", "text"].contains(rule.format) {
                throw MobileConfigurationError.invalidReference("rule.format")
            }
        }

        for mode in profile.modes {
            let hasDefaultLine = !mode.defaultLineID.isEmpty
            let hasDefaultSubscription = !mode.defaultSubscriptionID.isEmpty
            guard hasDefaultLine != hasDefaultSubscription else {
                throw MobileConfigurationError.invalidReference("mode.default_target")
            }
            if !mode.defaultLineID.isEmpty, !lineIDs.contains(mode.defaultLineID) {
                throw MobileConfigurationError.invalidReference("mode.default_line_id")
            }
            if !mode.defaultSubscriptionID.isEmpty,
               !subscriptionIDs.contains(mode.defaultSubscriptionID) {
                throw MobileConfigurationError.invalidReference("mode.default_subscription_id")
            }
            try validateIDs(mode.bindings.map(\.ruleSetID), kind: "mode binding rule")
            for binding in mode.bindings {
                guard ruleIDs.contains(binding.ruleSetID) else {
                    throw MobileConfigurationError.invalidReference("binding.rule_set_id")
                }
                let hasLine = !binding.lineID.isEmpty
                let hasSubscription = !binding.subscriptionID.isEmpty
                guard hasLine != hasSubscription else {
                    throw MobileConfigurationError.invalidReference("binding.target")
                }
                if !binding.lineID.isEmpty, !lineIDs.contains(binding.lineID) {
                    throw MobileConfigurationError.invalidReference("binding.line_id")
                }
                if !binding.subscriptionID.isEmpty,
                   !subscriptionIDs.contains(binding.subscriptionID) {
                    throw MobileConfigurationError.invalidReference("binding.subscription_id")
                }
            }
        }
    }

    private static func isHTTPSRemoteAddress(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local")
    }

    private static func validateIDs(_ ids: [String], kind: String) throws {
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MobileConfigurationError.invalidIdentifier(kind)
        }
        guard Set(ids).count == ids.count else {
            throw MobileConfigurationError.duplicateIdentifier(kind)
        }
    }
}

struct MobileJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum MobileDiagnosticsService {
    static func report(
        version: String,
        status: String,
        systemProfileInstalled: Bool,
        profile: Profile,
        lastError: String?,
        dataPathSummary: String?,
        isChinese: Bool
    ) -> String {
        let safeStatus = redacted(status, using: profile) ?? status
        let error = redacted(lastError?.trimmingCharacters(in: .whitespacesAndNewlines), using: profile)
        // 探针摘要由 DataPathProbe 用已校验的 IP 地址生成。通用 URL 脱敏器会把裸 IP
        // 也识别为链接并抹掉，反而失去这项诊断的唯一目的。
        let probe = dataPathSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedError = error.flatMap { $0.isEmpty ? nil : $0 }
        let renderedProbe = probe.flatMap { $0.isEmpty ? nil : $0 }
        if isChinese {
            return """
            XDial 诊断
            版本：\(version)
            状态：\(safeStatus)
            系统描述文件：\(systemProfileInstalled ? "已安装" : "未安装")
            对象计数：线路 \(profile.lines.count)，规则 \(profile.ruleSets.count)，模式 \(profile.modes.count)，订阅 \(profile.subscriptions.count)
            出口探针：\(renderedProbe ?? "未运行")
            最近错误：\(renderedError ?? "无")
            """
        }
        return """
        XDial Diagnostics
        Version: \(version)
        Status: \(safeStatus)
        System profile: \(systemProfileInstalled ? "Installed" : "Not installed")
        Object counts: lines \(profile.lines.count), rules \(profile.ruleSets.count), modes \(profile.modes.count), subscriptions \(profile.subscriptions.count)
        Egress probe: \(renderedProbe ?? "Not run")
        Last error: \(renderedError ?? "None")
        """
    }

    static func redacted(_ text: String?, using profile: Profile) -> String? {
        guard var result = text, !result.isEmpty else { return text }

        let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = urlDetector?.matches(in: result, range: range) ?? []
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "<redacted-url>")
        }

        for value in sensitiveValues(in: profile).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: value, with: "<redacted>")
        }
        return userFacingConnectionText(result)
    }

    private static func sensitiveValues(in profile: Profile) -> Set<String> {
        var values = Set<String>()

        func collect(_ line: Line) {
            for value in [
                line.vpnServer, line.vpnUsername, line.vpnPassword,
                line.trojanServer, line.trojanPassword, line.trojanSNI,
                line.ssServer, line.ssPassword,
                line.vmessServer, line.vmessUUID,
                line.tailscaleExitNode,
            ] where !value.isEmpty {
                values.insert(value)
            }
        }

        for line in profile.lines { collect(line) }
        if !profile.tailscale.hostname.isEmpty {
            values.insert(profile.tailscale.hostname)
        }
        for ruleSet in profile.ruleSets where !ruleSet.url.isEmpty {
            values.insert(ruleSet.url)
        }
        for subscription in profile.subscriptions {
            if !subscription.url.isEmpty { values.insert(subscription.url) }
            if !subscription.testURL.isEmpty { values.insert(subscription.testURL) }
            for group in subscription.proxyGroups where !group.url.isEmpty {
                values.insert(group.url)
            }
            for line in subscription.lines { collect(line) }
        }
        return values
    }
}
