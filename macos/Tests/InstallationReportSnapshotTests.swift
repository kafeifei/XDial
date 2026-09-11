import XCTest

final class InstallationReportSnapshotTests: XCTestCase {
    func testNewProcessReplacesOldReportAndPreservesStructuredFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("installation-report.json")
        let old = InstallationReportSnapshot(
            processIdentifier: 10, bundleIdentifier: "com.kafeifei.xdial.app",
            bundleVersion: "100", recordedAt: Date(),
            report: .fresh(applicationAlreadyInstalled: true)
        )
        try old.write(to: url)
        var failure = InstallationReport.fresh(applicationAlreadyInstalled: true)
        failure.fail(code: "helper-denied", message: "Registration denied", taskID: "helper")
        let current = InstallationReportSnapshot(
            processIdentifier: 20, bundleIdentifier: old.bundleIdentifier,
            bundleVersion: "101", recordedAt: Date(), report: failure
        )
        try current.write(to: url)
        let saved = try JSONDecoder().decode(
            InstallationReportSnapshot.self, from: Data(contentsOf: url)
        )
        XCTAssertEqual(saved, current)
        XCTAssertEqual(saved.report.error?.taskID, "helper")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
