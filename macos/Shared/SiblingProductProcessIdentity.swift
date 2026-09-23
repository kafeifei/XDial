import AppKit
import Darwin

/// An overwritten executable can keep running after proc_pidpath returns
/// ENOENT. Resolve known sibling channels using live OS facts, not argv or
/// a same-name process. This only excludes siblings; it never authorizes
/// terminating a process or treating an unknown process as absent.
enum SiblingProductProcessIdentity {
    struct Application {
        let identifier: String
        let bundleURL: URL
    }
    struct Peer {
        let pid: Int32
        let uid: uid_t
    }

    static func contains(
        _ pid: Int32,
        channels: [XDialBuildIdentity.InstalledChannel] = XDialBuildIdentity.siblingChannels,
        application: (Int32) -> Application? = runningApplication,
        daemonPeer: (String) -> Peer? = socketPeer
    ) -> Bool {
        guard pid > 0 else { return false }
        if let app = application(pid), channels.contains(where: {
            $0.applicationIdentifier == app.identifier &&
            $0.bundleURL.standardizedFileURL == app.bundleURL.standardizedFileURL
        }) { return true }
        return channels.contains { channel in
            guard let peer = daemonPeer(channel.daemonSocketPath) else { return false }
            return peer.pid == pid && peer.uid == 0
        }
    }

    private static func runningApplication(_ pid: Int32) -> Application? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let identifier = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        return Application(identifier: identifier, bundleURL: url)
    }

    private static func socketPeer(_ path: String) -> Peer? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Identity checks must not block on an unresponsive sibling service.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 104)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return nil }
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              getpeereid(fd, &uid, &gid) == 0, pid > 0 else { return nil }
        return Peer(pid: pid, uid: uid)
    }
}
