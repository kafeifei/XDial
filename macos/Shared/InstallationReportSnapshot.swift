import Foundation

struct InstallationReportSnapshot: Codable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let bundleVersion: String
    let recordedAt: Date
    let report: InstallationReport

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}
