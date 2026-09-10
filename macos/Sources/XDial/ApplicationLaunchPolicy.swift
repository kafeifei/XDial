import AppKit

enum ApplicationLaunchPolicy {
    static let relocationPredecessorArgument =
        "--xdial-relocation-predecessor-pid"
    static let installedSuccessorArgument = "--xdial-installed-successor"

    static func configure(
        _ configuration: NSWorkspace.OpenConfiguration,
        relocationPredecessorProcessIdentifier: Int32? = nil,
        isInstalledSuccessor: Bool = false
    ) {
        // XDial is a menu-bar agent. It becomes a regular application only
        // while the settings window is open, so relaunching it must not create
        // a recent-application tile that outlives that window.
        configuration.addsToRecentItems = false
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        if let processIdentifier =
            relocationPredecessorProcessIdentifier,
            processIdentifier > 0
        {
            configuration.arguments = [
                relocationPredecessorArgument,
                String(processIdentifier),
            ]
        }
        if isInstalledSuccessor {
            configuration.arguments.append(installedSuccessorArgument)
        }
    }

    // Staged updates also carry a predecessor PID, but are expected to install
    // themselves first. Only the final installed successor must already be at
    // the canonical location; otherwise it would enter installation again.
    static func shouldRejectInstalledSuccessor(
        currentIsCanonical: Bool,
        arguments: [String]
    ) -> Bool {
        !currentIsCanonical && arguments.contains(installedSuccessorArgument)
    }

    static func relocationPredecessorProcessIdentifier(
        arguments: [String]
    ) -> Int32? {
        guard
            let argumentIndex = arguments.firstIndex(
                of: relocationPredecessorArgument
            ),
            arguments.indices.contains(argumentIndex + 1),
            let processIdentifier = Int32(arguments[argumentIndex + 1]),
            processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }
}

enum ApplicationRelaunchHandoffPolicy {
    static func shouldIgnoreCandidate(
        currentIsCanonical: Bool,
        candidateProcessIdentifier: Int32,
        candidateBundleIdentifierMatches: Bool,
        candidateBundleIsCanonical: Bool,
        expectedPredecessorProcessIdentifier: Int32?
    ) -> Bool {
        currentIsCanonical
            && candidateProcessIdentifier
                == expectedPredecessorProcessIdentifier
            && candidateBundleIdentifierMatches
            && !candidateBundleIsCanonical
    }
}
