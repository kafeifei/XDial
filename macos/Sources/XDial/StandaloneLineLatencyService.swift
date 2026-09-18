import Foundation
import Libbox

enum StandaloneLineLatencyService {
    /// Credentials stay in memory; no helper, system extension, or system network settings.
    static func probe(_ line: Line, testURL: String) async throws -> ProviderLineLatency {
        let data = try JSONEncoder().encode(line)
        return try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            let json = LibboxProbeStandaloneLineLatencyAtURL(String(decoding: data, as: UTF8.self), testURL, 5_000, &error)
            if let error { throw error }
            return try JSONDecoder().decode(ProviderLineLatency.self, from: Data(json.utf8))
        }.value
    }
    static func evaluateGroups(_ lines: [Line], facts: [ProviderLineLatency]) async throws -> [ProviderLineLatency] {
        // Selection needs only membership and measurements; never copy credentials.
        let catalog = lines.map { line in
            var entry = Line(id: line.id, name: "", type: line.type)
            entry.groupMembers = line.groupMembers; entry.groupDefault = line.groupDefault
            return entry
        }
        let lineData = try JSONEncoder().encode(catalog)
        let factData = try JSONEncoder().encode(facts)
        return try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            let json = LibboxEvaluateLineGroupLatencies(String(decoding: lineData, as: UTF8.self),
                                                      String(decoding: factData, as: UTF8.self), &error)
            if let error { throw error }
            return try JSONDecoder().decode([ProviderLineLatency].self, from: Data(json.utf8))
        }.value
    }
}
