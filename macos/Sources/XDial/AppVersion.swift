import Foundation

enum VersionUpdatePolicy {
    static func stableReleaseVersion(fromTag tag: String) -> String? {
        guard tag.first == "v" else { return nil }
        let value = tag.dropFirst()
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts.allSatisfy({ part in
                  !part.isEmpty
                      && part.utf8.allSatisfy { (48 ... 57).contains($0) }
                      && (part == "0" || part.first != "0")
              }) else {
            return nil
        }
        return String(value)
    }

    static func stableVersion(fromTag tag: String) -> String? {
        var value = tag.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }
        return value
    }

    static func isNewer(
        latestTag: String,
        than currentVersion: String
    ) -> Bool {
        guard let latest = NumericVersion(latestTag),
              let current = NumericVersion(currentVersion) else {
            return false
        }
        return current < latest
    }

    private struct NumericVersion: Comparable {
        let components: [Int]

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if value.first == "v" || value.first == "V" {
                value.removeFirst()
            }
            guard let core = value.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: true
            ).first else {
                return nil
            }
            let parts = core.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !parts.isEmpty else { return nil }
            let parsed = parts.compactMap { Int($0) }
            guard parsed.count == parts.count else { return nil }
            components = parsed
        }

        static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count
                    ? lhs.components[index]
                    : 0
                let right = index < rhs.components.count
                    ? rhs.components[index]
                    : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
