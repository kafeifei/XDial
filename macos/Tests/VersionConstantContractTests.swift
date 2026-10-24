import CryptoKit
import Foundation
import XCTest

/// Stable, beta and Debug share these persistent formats and cross-process
/// protocols (D22). test/version_constants_test.py pins every site, including
/// the ones outside this test target (PrivilegeManager, KeychainStore and the
/// Go side); this suite checks the values through the code that writes and
/// reads them.
final class VersionConstantContractTests: XCTestCase {
    private let policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"

    func testHelperRegistrationIntentVersionIsPinned() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("intent").path
        _ = try HelperRegistrationMaintenanceIntent.establish(targetHash: "hash", previousPID: nil, at: path)
        XCTAssertEqual(try jsonObject(at: URL(fileURLWithPath: path))["version"] as? Int, 1, policy)

        // The Go helper only accepts version 1 too; any other version must stop maintenance.
        let newer = HelperRegistrationMaintenanceIntent.Record(
            version: 2, token: "token", targetHash: "hash", phase: "prepared",
            previousPID: nil, registrationFingerprint: nil
        )
        try FileManager.default.removeItem(atPath: path)
        try JSONEncoder().encode(newer).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertThrowsError(try HelperRegistrationMaintenanceIntent.read(at: path), policy)
    }

    func testSharedProfileLibraryFormatIsPinned() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let authenticatedData = Data("XDial Profile Library v1".utf8)
        let file = directory.appendingPathComponent("profiles.enc")
        let plaintext: Data
        do {
            try ProfileLibraryStore(directory: directory, keyProvider: { _ in key }).save(ProfileLibrary())
            plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key, authenticating: authenticatedData
            )
        } catch {
            return XCTFail("a default library must save as schema 3 sealed with \"XDial Profile Library v1\": \(error); \(policy)")
        }
        let library = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(library["schemaVersion"] as? Int, 3, policy)
        XCTAssertEqual(
            try ProfileLibraryStore(directory: directory, keyProvider: { _ in key }).load()?.schemaVersion, 3, policy
        )

        // Stable and Debug read the same file: a newer schema is refused, never rewritten.
        // Launch goes through loadOrCreate, the path that could replace the library.
        var newer = ProfileLibrary()
        newer.schemaVersion = 4
        let sealed = try AES.GCM.seal(JSONEncoder().encode(newer), using: key, authenticating: authenticatedData)
        let written = try XCTUnwrap(sealed.combined)
        try written.write(to: file)
        XCTAssertThrowsError(
            try ProfileLibraryStore(directory: directory, keyProvider: { _ in key }).loadOrCreate {
                XCTFail("a newer library must not be replaced by a migrated one; \(self.policy)")
                return ProfileLibrary()
            }, policy
        )
        XCTAssertEqual(try Data(contentsOf: file), written, "a newer library was rewritten; \(policy)")
    }

    func testUpdateFormatsArePinned() throws {
        XCTAssertEqual(AppUpdateRelaunchIntent.schemaVersion, 2, policy)
        let now = Date(timeIntervalSince1970: 1000)
        // Schema 1 (written by v0.9.x and earlier, no targetBuild) stays readable;
        // schema 2 also binds the build; anything newer is refused.
        for (schemaVersion, permitted) in [(1, true), (2, true), (3, false)] {
            let intent = AppUpdateRelaunchIntent(
                schemaVersion: schemaVersion, targetVersion: "0.8.0",
                targetBuild: schemaVersion == 1 ? nil : "100",
                reconnectScenarioID: nil, createdAt: now
            )
            XCTAssertEqual(
                AppUpdateRelaunchIntentPolicy.permitsTarget(intent, version: "0.8.0", build: "100", now: now),
                permitted, "relaunch intent schemaVersion \(schemaVersion); \(policy)"
            )
        }

        // stable.json and beta.json share one manifest schema.
        func manifest(schemaVersion: Int, channel: AppUpdateChannel) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": schemaVersion, "revision": 1, "channel": channel.rawValue,
                "generatedAt": "1970-01-01T00:15:00Z", "release": NSNull(),
            ])
        }
        for channel in AppUpdateChannel.allCases {
            XCTAssertEqual(
                try AppUpdateManifestParser.parse(
                    manifest(schemaVersion: 1, channel: channel), expectedChannel: channel
                ).schemaVersion, 1, policy
            )
            XCTAssertThrowsError(
                try AppUpdateManifestParser.parse(
                    manifest(schemaVersion: 2, channel: channel), expectedChannel: channel
                ), policy
            ) { error in
                XCTAssertEqual(error as? AppUpdateManifestError, .unsupportedSchema, self.policy)
            }
        }
    }

    func testInstallationFormatsArePinned() throws {
        XCTAssertEqual(InstallationReport.schemaVersion, 4, policy)
        XCTAssertEqual(
            InstallationBuildMarker.make(bundleIdentifier: "bundle", bundleVersion: "7"),
            "bundle:7:installation-v4", policy
        )

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(XDialBuildIdentity.applicationBundleName)
        let artifacts = ApplicationInstallationArtifacts(
            destinationURL: destination,
            applicationIdentifier: XDialBuildIdentity.applicationIdentifier,
            teamIdentifier: "test-team",
            isTrustedApplication: { _ in false },
            isInUse: { _ in false },
            unregisterApplication: { _ in }
        )
        try artifacts.perform { transaction in
            let receipt = try jsonObject(at: root.appendingPathComponent(transaction.receiptName))
            XCTAssertEqual(receipt["schemaVersion"] as? Int, 1, policy)
        }

        // A receipt in another schema is not authority to delete anything.
        let newer = ApplicationInstallationArtifacts.Transaction(
            schemaVersion: 2, id: UUID(),
            applicationIdentifier: XDialBuildIdentity.applicationIdentifier,
            teamIdentifier: "test-team"
        )
        let receipt = root.appendingPathComponent(newer.receiptName)
        try JSONEncoder().encode(newer).write(to: receipt)
        try FileManager.default.createDirectory(
            at: artifacts.stagingURL(for: newer), withIntermediateDirectories: false
        )
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path), policy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.stagingURL(for: newer).path), policy)
    }

    func testDiagnosticRecordVersionsArePinned() throws {
        let plan = ConnectionPlan(
            schemaVersion: 3, scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"), tasks: []
        )
        let report = ConnectionReport(transactionID: "transaction", plan: plan)
        XCTAssertEqual(report.schemaVersion, 3, policy)
        XCTAssertEqual(try jsonObject(report)["schema_version"] as? Int, 3, policy)
        XCTAssertEqual(try jsonObject(ReconnectIncidentHistory())["schema_version"] as? Int, 1, policy)
        XCTAssertEqual(HostUnderlayCaptureEvidence.missingPathUpdate.schemaVersion, 1, policy)
        XCTAssertEqual(
            HostUnderlayCaptureDiagnosticClassifier.classify(
                pathStatus: "unsatisfied", routeInterface: "", routeError: "",
                candidateInterfaces: [], indexedInterfaces: []
            )?.schemaVersion, 1, policy
        )
    }

    func testHostExtensionIPCVersionsArePinned() throws {
        XCTAssertEqual(ProviderScenarioSwitchCodec.version, 1, policy)
        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeRequest(Data(#"{"v":2,"cmd":"status"}"#.utf8)), policy
        ) {
            XCTAssertEqual($0 as? ProviderScenarioSwitchCodecError, .unsupportedVersion, self.policy)
        }

        XCTAssertEqual(ProviderDiagnosticsCodec.version, 1, policy)
        XCTAssertThrowsError(try ProviderDiagnosticsCodec.decodeRequest(
            Data(#"{"v":2,"cmd":"routing-probe-snapshot","transaction_id":"transaction"}"#.utf8)
        ), policy) {
            XCTAssertEqual($0 as? ProviderDiagnosticsCodecError, .unsupportedVersion, self.policy)
        }

        XCTAssertEqual(LocalSOCKSShareRequest.version, 1, policy)
        let request = LocalSOCKSShareRequest(transactionID: "transaction", port: nil)
        XCTAssertTrue(request.isValid, policy)
        var object = try jsonObject(request)
        XCTAssertEqual(object["version"] as? Int, 1, policy)
        object["version"] = 2
        let newer = try JSONDecoder().decode(
            LocalSOCKSShareRequest.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(newer.isValid, policy)

        let control = TailscaleControlRequest(transactionID: "transaction", identityProfileID: "profile", command: .status)
        XCTAssertTrue(control.isValid, policy)
        var controlObject = try jsonObject(control)
        XCTAssertEqual(controlObject["kind"] as? String, "tailscale-control", policy)
        XCTAssertEqual(controlObject["version"] as? Int, 1, policy)
        controlObject["version"] = 2
        let newerControl = try JSONDecoder().decode(
            TailscaleControlRequest.self, from: JSONSerialization.data(withJSONObject: controlObject)
        )
        XCTAssertFalse(newerControl.isValid, policy)
        XCTAssertEqual(
            TailscaleControlPolicy.rejection(
                request: newerControl, transactionID: "transaction",
                committed: true, switching: false, activeIdentity: "profile"
            ), "invalid-request", policy
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xdial-version-contract-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
