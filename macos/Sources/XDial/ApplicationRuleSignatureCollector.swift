import Foundation
import Security

enum ApplicationRuleSignatureCollector {
    enum CollectionError: LocalizedError {
        case notApplication(URL)
        case signatureUnreadable(URL)
        case signatureInvalid(URL)
        case signatureMetadataMissing(URL)
        case unsupportedSigningIdentity(URL)

        var errorDescription: String? {
            switch self {
            case .notApplication(let url):
                return "\(url.lastPathComponent) 不是应用程序包"
            case .signatureUnreadable(let url):
                return "无法读取 \(url.lastPathComponent) 的代码签名"
            case .signatureInvalid(let url):
                return "\(url.lastPathComponent) 的代码签名无效"
            case .signatureMetadataMissing(let url):
                return "\(url.lastPathComponent) 缺少 Team ID 或 signing identifier"
            case .unsupportedSigningIdentity(let url):
                return "\(url.lastPathComponent) 的签名身份格式不受支持"
            }
        }
    }

    /// 收集主 app 和其包内所有可执行/嵌套签名组件的 Team ID + signing identifier。
    /// 静态签名验证在控制面完成；运行时 Provider 仍只把系统交付的身份事实传给数据面。
    static func collect(at selectedURL: URL) throws -> ApplicationRuleApplication {
        let applicationURL = selectedURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard
            applicationURL.pathExtension.lowercased() == "app",
            (try? applicationURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
        else {
            throw CollectionError.notApplication(applicationURL)
        }

        let rootIdentity = try signingIdentity(at: applicationURL)
        var identities = Set([rootIdentity])

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isExecutableKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: applicationURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw CollectionError.signatureUnreadable(applicationURL)
        }

        // 遇到嵌套 app/framework 后主动 skip descendants，既收集该签名对象，
        // 又避免把它的资源树逐个扫描；普通可执行文件同样覆盖 Helper 工具。
        while let nestedURL = enumerator.nextObject() as? URL {
            let values = try? nestedURL.resourceValues(forKeys: resourceKeys)
            guard values?.isSymbolicLink != true else { continue }
            if isNestedCodeBundle(nestedURL) || values?.isExecutable == true {
                if let identity = try? signingIdentity(at: nestedURL) {
                    identities.insert(identity)
                }
                if isNestedCodeBundle(nestedURL) {
                    enumerator.skipDescendants()
                }
            }
        }

        let displayName = Bundle(url: applicationURL)?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ApplicationRuleApplication(
            name: (name?.isEmpty == false)
                ? name!
                : applicationURL.deletingPathExtension().lastPathComponent,
            path: applicationURL.path,
            identities: Array(identities)
        )
    }

    private static func isNestedCodeBundle(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "app", "appex", "bundle", "framework", "kext", "mdimporter",
            "plugin", "prefpane", "qlgenerator", "saver", "systemextension", "xpc":
            return true
        default:
            return false
        }
    }

    private static func signingIdentity(at url: URL) throws -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
            == errSecSuccess, let staticCode else {
            throw CollectionError.signatureUnreadable(url)
        }
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            throw CollectionError.signatureInvalid(url)
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [String: Any],
        let identifier = information[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier = information[
            kSecCodeInfoTeamIdentifier as String
        ] as? String else {
            throw CollectionError.signatureMetadataMissing(url)
        }
        guard let identity = ApplicationRuleApplication.canonicalIdentity(
            teamIdentifier: teamIdentifier,
            signingIdentifier: identifier
        ) else {
            throw CollectionError.unsupportedSigningIdentity(url)
        }
        return identity
    }
}
