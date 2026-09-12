import Foundation

/// Tahoe can retain our menu-item location under the app that once launched us.
/// Recreating an NSStatusItem cannot change that bundle-level association.
/// Repair only foreign references to this host, through CFPreferences, after
/// validating the complete known schema and keeping a byte-for-byte backup.
enum MenuBarTrackingRepair {
    enum Failure: Error { case unsupportedSystem, unexpectedSchema, targetNotRegistered, concurrentChange, writeFailed, verificationFailed }

    struct Plan {
        let original: Data
        let outer: [String: Any]
        let repairedTracking: Data?
        let owners: [String]
        let ownEntryDisabled: Bool
    }

    struct Report: Sendable {
        let status: String
        let owners: [String]
        let backupPath: String?
    }

    static var preferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
        )
    }

    private static func bundleID(_ location: Any) -> String? {
        guard let location = location as? [String: Any], location.count == 1,
              let bundle = location["bundle"] as? [String: Any], bundle.count == 1 else { return nil }
        return bundle["_0"] as? String
    }

    static func plan(_ original: Data, target: String) throws -> Plan {
        guard let outer = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              let trackedData = outer["trackedApplications"] as? Data,
              var tracked = try PropertyListSerialization.propertyList(from: trackedData, format: nil) as? [Any],
              tracked.count.isMultiple(of: 2) else { throw Failure.unexpectedSchema }
        var owners: [String] = []
        var ownEntryEnabled: Bool?
        for index in stride(from: 0, to: tracked.count, by: 2) {
            guard var record = tracked[index + 1] as? [String: Any],
                  let location = record["location"] as? [String: Any],
                  let locations = record["menuItemLocations"] as? [Any],
                  let allowed = record["isAllowed"] as? Bool,
                  NSDictionary(dictionary: location).isEqual(tracked[index]) else { throw Failure.unexpectedSchema }
            if bundleID(location) == target {
                guard ownEntryEnabled == nil else { throw Failure.unexpectedSchema }
                ownEntryEnabled = allowed
            } else {
                let retained = locations.filter { bundleID($0) != target }
                if retained.count != locations.count {
                    record["menuItemLocations"] = retained
                    owners.append(bundleID(location) ?? String(describing: location))
                }
            }
            tracked[index + 1] = record
        }
        guard let ownEntryEnabled else { throw Failure.targetNotRegistered }
        // An explicit system setting hiding XDial is not a foreign-owner bug.
        // Do not silently enable the user's own disabled entry.
        let repaired = !owners.isEmpty && ownEntryEnabled
            ? try PropertyListSerialization.data(fromPropertyList: tracked, format: .binary, options: 0)
            : nil
        return Plan(original: original, outer: outer, repairedTracking: repaired,
                    owners: owners, ownEntryDisabled: !ownEntryEnabled)
    }

    static func inspect(target: String) throws -> Plan {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
            throw Failure.unsupportedSystem
        }
        return try plan(Data(contentsOf: preferencesURL), target: target)
    }

    static func repair(target: String, backupDirectory: URL) throws -> Report {
        let plan = try inspect(target: target)
        guard let repaired = plan.repairedTracking else {
            return Report(status: plan.ownEntryDisabled ? "own-entry-disabled" : "already-clean",
                          owners: plan.owners, backupPath: nil)
        }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupURL = backupDirectory.appendingPathComponent("controlcenter-\(UUID().uuidString).plist")
        try plan.original.write(to: backupURL, options: .withoutOverwriting)
        guard try Data(contentsOf: preferencesURL) == plan.original else { throw Failure.concurrentChange }

        // An absolute preferences domain addresses this container through the
        // preferences daemon. It also notifies the live Control Center; neither
        // cfprefsd nor Control Center needs to be killed to reload the change.
        let domain = preferencesURL.deletingPathExtension().path as CFString
        CFPreferencesSetValue("trackedApplications" as CFString, repaired as CFData,
                             domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw Failure.writeFailed
        }
        guard var after = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: preferencesURL), format: nil
        ) as? [String: Any], after["trackedApplications"] as? Data == repaired else {
            throw Failure.verificationFailed
        }
        var before = plan.outer
        before.removeValue(forKey: "trackedApplications")
        after.removeValue(forKey: "trackedApplications")
        guard NSDictionary(dictionary: before).isEqual(to: after) else { throw Failure.concurrentChange }
        return Report(status: "repaired", owners: plan.owners, backupPath: backupURL.path)
    }
}
