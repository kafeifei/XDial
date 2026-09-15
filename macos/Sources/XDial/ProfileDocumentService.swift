import Foundation
import Libbox

enum ProfileDocumentService {
    static func reimportSavedScenario(_ profile: Profile, scenarioID: String, newProfileID: String) async throws -> Profile {
        let data = try JSONEncoder().encode(profile)
        return try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            let result = LibboxReimportProfileScenario(String(decoding: data, as: UTF8.self), scenarioID, newProfileID, &error)
            if let error { throw error }
            guard !result.isEmpty else { throw ProfileLibraryError.invalid("无法重新导入已保存配置") }
            return try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
        }.value
    }

    static func validateMatchingContent(_ content: RuleSet) throws {
        var draft = Profile()
        draft.lines = [Line(id: "direct", name: "Direct", type: "direct")]
        draft.ruleSets = [content]
        draft.scenarios = [Scenario(id: "validation", name: "Validation", defaultLineID: "direct")]
        try validate(draft)
    }

    static func groupRulesByDestination(_ profile: Profile, referenceScenarioID: String) throws -> Profile {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        let result = LibboxGroupProfileRulesByDestination(String(decoding: data, as: UTF8.self), referenceScenarioID, &error)
        if let error { throw error }
        let candidate = try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
        guard candidate.scenarios.map(\.id) == profile.scenarios.map(\.id) else {
            throw ProfileLibraryError.invalid("场景身份发生变化，已取消迁移")
        }
        var updated = profile
        updated.ruleSets = candidate.ruleSets
        for index in updated.scenarios.indices {
            updated.scenarios[index].bindings = candidate.scenarios[index].bindings
            updated.scenarios[index].matchOrder = candidate.scenarios[index].matchOrder
        }
        return updated
    }

    static func separateImportedRuleResources(_ profile: Profile) throws -> Profile {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        // The bridge verifies the compiled fingerprint of every Scenario.
        let result = LibboxSeparateImportedRuleResources(String(decoding: data, as: UTF8.self), &error)
        if let error { throw error }
        let candidate = try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
        guard candidate.scenarios.map(\.id) == profile.scenarios.map(\.id) else {
            throw ProfileLibraryError.invalid("场景身份发生变化，已取消迁移")
        }
        // Go does not own Swift-only defaults or local line/UI state.
        var updated = profile
        updated.ruleSets = candidate.ruleSets
        for index in updated.scenarios.indices {
            updated.scenarios[index].bindings = candidate.scenarios[index].bindings
        }
        return updated
    }

    static func compactRuleSets(_ profile: Profile) throws -> Profile {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        let result = LibboxCompactProfileRuleSets(String(decoding: data, as: UTF8.self), &error)
        if let error { throw error }
        return try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
    }

    static func importExistingDebug(id: String) throws -> Profile {
        let original = try ExistingXDialProfileReader.readDebug()
        var imported = try copy(original, id: id)
        if imported.lines.contains(where: { $0.type == "tailscale" }) {
            imported.tailscale.hostname = "xdial-next-" + String(id.prefix(8))
        }
        try validate(imported)
        return imported
    }

    static func copy(_ profile: Profile, id: String) throws -> Profile {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        let result = LibboxCloneProfile(String(decoding: data, as: UTF8.self), id, &error)
        if let error { throw error }
        guard !result.isEmpty else { throw ProfileLibraryError.invalid("无法复制配置") }
        return try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
    }
    static func read(content: String, url: String, profileID: String, nodesOnly: Bool = false) async throws -> Profile {
        var input = content
        if !url.isEmpty {
            guard let source = URL(string: url), source.scheme == "https", source.host != nil else {
                throw ProfileLibraryError.invalid("请填写完整的 HTTPS 订阅链接")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: source)
                request.setValue("XDial-Next/1", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      http.url?.scheme == "https", http.expectedContentLength <= 4 * 1024 * 1024 else {
                    throw ProfileLibraryError.invalid("订阅服务器响应无效，或文件超过 4 MiB")
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 4 * 1024 * 1024 else { throw ProfileLibraryError.invalid("订阅超过 4 MiB") }
                    data.append(byte)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw ProfileLibraryError.invalid("订阅不是 UTF-8 文本") }
                input = text
            } catch is CancellationError { throw CancellationError() }
            catch let error as ProfileLibraryError { throw error }
            catch { throw ProfileLibraryError.invalid("无法获取订阅，请检查链接及当前网络；原配置已保留") }
        }
        guard !input.isEmpty, input.utf8.count <= 4 * 1024 * 1024 else { throw ProfileLibraryError.invalid("配置为空或超过 4 MiB") }
        let text = input
        return try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            let result = LibboxImportProfile(text, "auto", profileID, nodesOnly, &error)
            if let error { throw error }
            guard !result.isEmpty else { throw ProfileLibraryError.invalid("无法解析配置") }
            return try JSONDecoder().decode(Profile.self, from: Data(result.utf8))
        }.value
    }

    static func export(_ profile: Profile) throws -> Data {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        let result = LibboxExportProfile(String(decoding: data, as: UTF8.self), &error)
        if let error { throw error }
        guard !result.isEmpty else { throw ProfileLibraryError.invalid("无法导出配置") }
        return Data(result.utf8)
    }

    static func validate(_ profile: Profile) throws {
        let data = try JSONEncoder().encode(profile)
        var error: NSError?
        LibboxValidateProfileDocument(String(decoding: data, as: UTF8.self), &error)
        if let error { throw error }
    }
}

extension AppState {
    func refreshProfile(_ id: String) {
        guard let record = profileLibrary.profiles.first(where: { $0.id == id }),
              let source = record.source, !refreshingProfileIDs.contains(id) else { return }
        refreshingProfileIDs.insert(id)
        profileOperationError = nil
        Task {
            defer { refreshingProfileIDs.remove(id) }
            do {
                let incoming = try await ProfileDocumentService.read(content: "", url: source.url, profileID: id, nodesOnly: source.nodesOnly)
                guard let index = profileLibrary.profiles.firstIndex(where: { $0.id == id }),
                      profileLibrary.profiles[index].source == source else { return }
                let latest = profileLibrary.profiles[index]
                let updated = try latest.refreshed(with: incoming)
                profileRefreshRetryAfter.removeValue(forKey: id)
                try ProfileDocumentService.validate(updated.profile)
                profileLibrary.profiles[index] = updated
                guard persistProfileLibrary() else { profileLibrary.profiles[index] = latest; return }
                if profileLibrary.activeProfileID == id {
                    profile = updated.profile
                    save()
                }
            } catch {
                profileRefreshRetryAfter[id] = Date().addingTimeInterval(15 * 60)
                profileOperationError = "「\(record.name)」更新失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshDueProfiles() {
        guard profileLibraryLoaded else { return }
        let now = Date()
        for record in profileLibrary.profiles {
            guard let source = record.source, source.refreshInterval > 0,
                  now >= (profileRefreshRetryAfter[record.id] ?? .distantPast),
                  now.timeIntervalSince(source.updatedAt ?? .distantPast) >= source.refreshInterval else { continue }
            refreshProfile(record.id)
        }
    }
}
