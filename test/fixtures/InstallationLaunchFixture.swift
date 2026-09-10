import AppKit
import Darwin
import Security

/// Exercises real LaunchServices with an ad-hoc signed, randomly identified
/// app. It never starts XDial, touches /Applications, or launches a quarantined
/// fixture. Production signature validation is not replaced by this fixture.
@main
enum InstallationLaunchFixture {
    private static let fixtureArgument = "--installation-launch-fixture"
    private static let reportArgument = "--installation-launch-report"
    private static let quarantineName = "com.apple.quarantine"

    private struct LaunchReport: Codable {
        let bundlePath: String
        let bundleIdentifier: String?
        let processIdentifier: Int32
        let arguments: [String]
    }

    private final class LaunchResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (NSRunningApplication?, Error?) = (nil, nil)

        func record(_ app: NSRunningApplication?, _ error: Error?) {
            lock.lock()
            value = (app, error)
            lock.unlock()
        }

        func snapshot() -> (NSRunningApplication?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func main() throws {
        if CommandLine.arguments.contains(fixtureArgument) {
            runFixtureApplication()
            return
        }
        try require(CommandLine.arguments.count == 2, "missing test directory")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try runInstallation(in: root, replacingExisting: false)
        try runInstallation(in: root, replacingExisting: true)
        print("installation LaunchServices tests passed (2 real app launches)")
    }

    private static func runFixtureApplication() {
        guard let index = CommandLine.arguments.firstIndex(of: reportArgument),
              CommandLine.arguments.indices.contains(index + 1),
              Bundle.main.bundleIdentifier?.hasPrefix(
                "local.xdialdiagnostic.installlaunch."
              ) == true else {
            exit(2)
        }
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let application = NSApplication.shared
        DispatchQueue.main.async {
            do {
                let report = LaunchReport(
                    bundlePath: canonical(Bundle.main.bundleURL).path,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    arguments: CommandLine.arguments
                )
                try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
            } catch {
                exit(3)
            }
            // Let LaunchServices observe launch completion, then exit ourselves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
        application.run()
    }

    private static func runInstallation(
        in root: URL,
        replacingExisting: Bool
    ) throws {
        let caseName = replacingExisting ? "replacement" : "first-install"
        let caseRoot = root.appendingPathComponent(caseName, isDirectory: true)
        let source = caseRoot.appendingPathComponent("download/LaunchFixture.app")
        let destination = caseRoot.appendingPathComponent("Applications/LaunchFixture.app")
        let staging = caseRoot.appendingPathComponent("Applications/.staged.app")
        let reportURL = caseRoot.appendingPathComponent("launch-report.json")
        let identifier = "local.xdialdiagnostic.installlaunch."
            + UUID().uuidString.lowercased()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: source.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let executable = source.appendingPathComponent(
            "Contents/MacOS/InstallationLaunchFixture"
        )
        try fileManager.copyItem(
            at: URL(fileURLWithPath: CommandLine.arguments[0]),
            to: executable
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Isolated Installation Launch Fixture",
            "CFBundleExecutable": "InstallationLaunchFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ).write(to: source.appendingPathComponent("Contents/Info.plist"))
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", source.path]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        try require(signer.terminationStatus == 0, "fixture signing failed")
        try validateSignature(at: source)

        let quarantine = Data("0083;12345678;InstallationLaunchFixture;\(UUID())".utf8)
        try setQuarantine(quarantine, at: source)
        try setQuarantine(quarantine, at: executable)
        if replacingExisting {
            try fileManager.copyItem(at: source, to: destination)
            try require(
                try quarantineData(at: destination) == quarantine,
                "replacement did not begin with quarantined destination"
            )
        }
        try fileManager.copyItem(at: source, to: staging)
        try validateSignature(at: staging)
        try ApplicationInstallationQuarantine.prepareValidatedCopy(at: staging)
        try ApplicationInstallationQuarantine.validateInstalledCopy(at: staging)
        try validateSignature(at: staging)
        if replacingExisting {
            try ApplicationBundleReplacer.replace(
                destinationURL: destination,
                newBundleURL: staging,
                backupName: ".backup.app"
            ) { installed in
                try ApplicationInstallationQuarantine.validateInstalledCopy(at: installed)
                try validateSignature(at: installed)
                return true
            }
            try require(
                !fileManager.fileExists(atPath: caseRoot.appendingPathComponent(
                    "Applications/.backup.app"
                ).path),
                "replacement backup was not removed"
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        try ApplicationInstallationQuarantine.validateInstalledCopy(at: destination)
        try validateSignature(at: destination)

        let predecessor = ProcessInfo.processInfo.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(
            configuration,
            relocationPredecessorProcessIdentifier: predecessor,
            isInstalledSuccessor: true
        )
        configuration.arguments += [fixtureArgument, reportArgument, reportURL.path]
        let completion = DispatchSemaphore(value: 0)
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(
            at: destination, configuration: configuration
        ) { application, error in
            result.record(application, error)
            completion.signal()
        }
        try require(
            completion.wait(timeout: .now() + 10) == .success,
            "LaunchServices completion timed out"
        )
        let (application, launchError) = result.snapshot()
        if let launchError { throw launchError }
        guard let application else { throw failure("no launched fixture process") }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while kill(application.processIdentifier, 0) == 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try require(
            kill(application.processIdentifier, 0) != 0 && errno == ESRCH,
            "fixture did not exit itself"
        )
        let report = try JSONDecoder().decode(
            LaunchReport.self, from: Data(contentsOf: reportURL)
        )
        try require(report.bundlePath == canonical(destination).path,
                    "unexpected actual bundle path: \(report.bundlePath)")
        try require(report.bundleIdentifier == identifier, "fixture identity changed")
        try require(report.processIdentifier == application.processIdentifier,
                    "launch report came from another process")
        try require(report.arguments.contains(ApplicationLaunchPolicy.installedSuccessorArgument),
                    "installed successor argument missing")
        try require(
            ApplicationLaunchPolicy.relocationPredecessorProcessIdentifier(
                arguments: report.arguments
            ) == predecessor,
            "predecessor PID not preserved"
        )
        try require(
            !ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: report.bundlePath == canonical(destination).path,
                arguments: report.arguments
            ),
            "installed successor rejected its target path"
        )
        try require(try quarantineData(at: source) == quarantine,
                    "download source quarantine changed")
        try require(try quarantineData(at: executable) == quarantine,
                    "download executable quarantine changed")
        print("\(caseName): actual=\(report.bundlePath) pid=\(report.processIdentifier) "
              + "predecessor=\(predecessor) final-marker=present source-quarantine=preserved")
    }

    private static func validateSignature(at url: URL) throws {
        var code: SecStaticCode?
        try require(
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
            "cannot read fixture signature"
        )
        guard let code else { throw failure("fixture signature missing") }
        try require(
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:
                kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
            ), nil) == errSecSuccess,
            "fixture signature invalid"
        )
    }

    private static func setQuarantine(_ data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes {
            setxattr(url.path, quarantineName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        try require(result == 0, "cannot quarantine fixture")
    }

    private static func quarantineData(at url: URL) throws -> Data {
        let size = getxattr(url.path, quarantineName, nil, 0, 0, XATTR_NOFOLLOW)
        try require(size >= 0, "fixture quarantine missing")
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes {
            getxattr(url.path, quarantineName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        try require(result == size, "cannot read fixture quarantine")
        return data
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "InstallationLaunchFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
