import Foundation
import Libbox

/// Exercises the same Go → Swift model boundary used by the import sheet.
/// This command never starts an engine, installs components, or writes profiles.
@main
struct ProfileDocumentCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ProfileDocumentCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pass one UTF-8 Profile document"])
        }
        let content = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        var error: NSError?
        let imported = LibboxImportProfile(content, "auto", "document-check", false, &error)
        if let error { throw error }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(imported.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        let separated = LibboxSeparateImportedRuleResources(encoded, &error)
        if let error { throw error }
        let separatedProfile = try JSONDecoder().decode(Profile.self, from: Data(separated.utf8))
        guard separatedProfile.scenarios == profile.scenarios else {
            throw NSError(domain: "ProfileDocumentCheck", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Migration changed an ungrouped document"])
        }
        let grouped = LibboxGroupProfileRulesByDestination(encoded, profile.scenarios[0].id, &error)
        if let error { throw error }
        let groupedProfile = try JSONDecoder().decode(Profile.self, from: Data(grouped.utf8))
        guard groupedProfile.scenarios.count == profile.scenarios.count,
              groupedProfile.lines.count == profile.lines.count else {
            throw NSError(domain: "ProfileDocumentCheck", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Grouping lost resources"])
        }
        let cloned = LibboxCloneProfile(encoded, "copy-check", &error)
        if let error { throw error }
        let copy = try JSONDecoder().decode(Profile.self, from: Data(cloned.utf8))
        let fresh = LibboxReimportProfileScenario(encoded, profile.scenarios[0].id, "fresh-import", &error)
        if let error { throw error }
        let freshProfile = try JSONDecoder().decode(Profile.self, from: Data(fresh.utf8))
        guard freshProfile.profileID == "fresh-import", freshProfile.scenarios.count == 1 else {
            throw NSError(domain: "ProfileDocumentCheck", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Saved reimport did not create a fresh Profile"])
        }
        let exported = LibboxExportProfile(encoded, &error)
        if let error { throw error }
        let reimported = LibboxImportProfile(exported, "auto", "roundtrip-check", false, &error)
        if let error { throw error }
        let roundTrip = try JSONDecoder().decode(Profile.self, from: Data(reimported.utf8))
        guard profile.lines.count == copy.lines.count,
              profile.ruleSets.count == roundTrip.ruleSets.count,
              profile.scenarios.count == roundTrip.scenarios.count,
              profile.importWarnings == roundTrip.importWarnings,
              profile.matchingResources.filter(\.noResolve).count == roundTrip.matchingResources.filter(\.noResolve).count,
              profile.matchingResources.count == copy.matchingResources.count,
              profile.matchingResources.count == roundTrip.matchingResources.count else {
            throw NSError(domain: "ProfileDocumentCheck", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Round trip lost resources"])
        }
        print("Profile document bridge passed: \(profile.lines.count) Lines, \(profile.ruleSets.count) RuleSets, \(profile.scenarios.count) Scenarios, \(profile.importWarnings.count) compatibility warnings")
    }
}
