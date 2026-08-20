import Foundation

/// Reads the current bundle metadata from disk instead of using `Bundle(url:)`.
/// Foundation caches `Bundle` instances by URL, so an atomic app replacement at
/// the same path can otherwise keep exposing the replaced bundle's identifiers.
enum ApplicationBundleInfo {
    static func string(
        forKey key: String,
        at bundleURL: URL
    ) -> String? {
        guard
            let data = try? Data(
                contentsOf: bundleURL.appendingPathComponent(
                    "Contents/Info.plist"
                ),
                options: [.mappedIfSafe]
            ),
            let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let value = dictionary[key] as? String,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    static func identifier(at bundleURL: URL) -> String? {
        string(forKey: "CFBundleIdentifier", at: bundleURL)
    }
}
