import AppKit
import Foundation

private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    private var error: Error?

    func record(
        application: NSRunningApplication?,
        error: Error?
    ) {
        lock.lock()
        self.application = application
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (NSRunningApplication?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (application, error)
    }
}

@main
private enum ApplicationLauncher {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs(
                "usage: launch-macos-app /path/to/Application.app\n",
                stderr
            )
            exit(2)
        }

        let applicationURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let configuration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(configuration)

        let completion = DispatchSemaphore(value: 0)
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { application, error in
            result.record(application: application, error: error)
            completion.signal()
        }

        guard completion.wait(timeout: .now() + 30) == .success else {
            fputs("application launch timed out\n", stderr)
            exit(1)
        }

        let (application, error) = result.snapshot()
        if let error {
            fputs(
                "application launch failed: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
        guard application != nil else {
            fputs(
                "application launch returned no running application\n",
                stderr
            )
            exit(1)
        }
    }
}
