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
        let cloned = LibboxCloneProfile(encoded, "copy-check", &error)
        if let error { throw error }
        let copy = try JSONDecoder().decode(Profile.self, from: Data(cloned.utf8))
        let exported = LibboxExportProfile(encoded, &error)
        if let error { throw error }
        let reimported = LibboxImportProfile(exported, "auto", "roundtrip-check", false, &error)
        if let error { throw error }
        let roundTrip = try JSONDecoder().decode(Profile.self, from: Data(reimported.utf8))
        guard profile.lines.count == copy.lines.count,
              profile.ruleSets.count == roundTrip.ruleSets.count,
              profile.scenarios.count == roundTrip.scenarios.count else {
            throw NSError(domain: "ProfileDocumentCheck", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Round trip lost resources"])
        }
        print("Profile document bridge passed: \(profile.lines.count) Lines, \(profile.ruleSets.count) RuleSets, \(profile.scenarios.count) Scenarios")
    }
}
