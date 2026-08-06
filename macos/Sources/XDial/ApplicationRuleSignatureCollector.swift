import Foundation

enum ApplicationRuleBundleCollector {
    enum CollectionError: LocalizedError {
        case notApplication(URL)
        case missingBundleIdentifier(URL)

        var errorDescription: String? {
            switch self {
            case .notApplication(let url):
                return "\(url.lastPathComponent) 不是应用程序包"
            case .missingBundleIdentifier(let url):
                return "\(url.lastPathComponent) 缺少可验证的应用标识"
            }
        }
    }

    /// Persist the root Bundle ID and canonical Bundle path. Do not recursively
    /// collect helper signing identifiers: macOS attributes delegated helper
    /// flows to the selected root app, while path ancestry remains a precise
    /// fallback for nested executables.
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

        let bundle = Bundle(url: applicationURL)
        guard
            let bundleIdentifier = bundle?.bundleIdentifier,
            RuleSet.isValidBundleIdentifier(bundleIdentifier)
        else {
            throw CollectionError.missingBundleIdentifier(applicationURL)
        }
        let displayName = bundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ApplicationRuleApplication(
            name: (name?.isEmpty == false)
                ? name!
                : applicationURL.deletingPathExtension().lastPathComponent,
            path: applicationURL.path,
            bundleIdentifier: bundleIdentifier
        )
    }
}
