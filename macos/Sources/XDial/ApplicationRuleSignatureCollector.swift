import Foundation

enum ApplicationRuleBundleCollector {
    enum CollectionError: LocalizedError {
        case notApplication(URL)

        var errorDescription: String? {
            switch self {
            case .notApplication(let url):
                return "\(url.lastPathComponent) 不是应用程序包"
            }
        }
    }

    /// Surge-style App Bundle selector: persist only the canonical bundle path.
    /// The Provider resolves the real executable path from each flow's audit
    /// token, so nested helpers are covered by path ancestry without becoming
    /// independent global identities.
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

        let displayName = Bundle(url: applicationURL)?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ApplicationRuleApplication(
            name: (name?.isEmpty == false)
                ? name!
                : applicationURL.deletingPathExtension().lastPathComponent,
            path: applicationURL.path
        )
    }
}
