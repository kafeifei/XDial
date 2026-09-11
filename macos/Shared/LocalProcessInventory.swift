import Darwin
import Foundation

/// Kernel process facts, including command-line helpers absent from AppKit's
/// runningApplications list. Missing paths are explicit, never proof of exit.
enum LocalProcessInventory {
    struct Entry: Equatable {
        let pid: Int32
        let name: String?
        let executableURL: URL?

        /// proc_name can be denied for another user's process even when the
        /// kernel exposes its executable path. Use either fact to identify a
        /// candidate; only absence of both facts is an unknown identity.
        func matchesExecutableName(in names: Set<String>) -> Bool? {
            let observed = [name, executableURL?.lastPathComponent]
                .compactMap { $0?.lowercased() }
                .filter { !$0.isEmpty }
            guard !observed.isEmpty else { return nil }
            return observed.contains { names.contains($0) }
        }

        /// Resolve a daemon process to one installed product channel. A path
        /// in the explicit sibling bundle is unrelated to this channel; a
        /// matching name at any other external or unavailable path stays
        /// unknown because build and recovery copies remain possible.
        func belongsToProductBundle(
            _ bundleURL: URL,
            excludingSiblingBundleURLs: [URL],
            executableNames: Set<String>
        ) -> Bool? {
            if let executableURL {
                guard matchesExecutableName(in: executableNames) == true
                else { return false }
                let executablePath = executableURL.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                func isInside(_ candidate: URL) -> Bool {
                    let path = candidate.resolvingSymlinksInPath()
                        .standardizedFileURL.path
                    return executablePath == path
                        || executablePath.hasPrefix(path + "/")
                }
                if isInside(bundleURL) { return true }
                if excludingSiblingBundleURLs.contains(where: isInside) {
                    return false
                }
                return nil
            }
            switch matchesExecutableName(in: executableNames) {
            case .some(true), .none: return nil
            case .some(false): return false
            }
        }
    }

    enum Snapshot: Equatable {
        case available([Entry])
        case unknown
    }

    static func capture() -> Snapshot {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return .unknown }
        var capacity = Int(estimate) + 64
        for _ in 0..<3 {
            var identifiers = [Int32](repeating: 0, count: capacity)
            let count = identifiers.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return .unknown }
            if count >= capacity {
                capacity *= 2
                continue
            }
            var entries: [Entry] = []
            for pid in Set(identifiers.prefix(Int(count))) where pid > 0 {
                // PROC_PIDPATHINFO_MAXSIZE is the C expression 4 * MAXPATHLEN.
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
                let pathError = errno
                var name = [CChar](repeating: 0, count: 1024)
                let nameLength = proc_name(pid, &name, UInt32(name.count))
                let nameError = errno
                if pathLength == 0, nameLength == 0,
                   (pathError == ESRCH || pathError == ENOENT),
                   (nameError == ESRCH || nameError == ENOENT) {
                    continue
                }
                entries.append(Entry(
                    pid: pid,
                    name: nameLength > 0 ? String(cString: name) : nil,
                    executableURL: pathLength > 0
                        ? URL(fileURLWithPath: String(cString: path)) : nil
                ))
            }
            return .available(entries.sorted { $0.pid < $1.pid })
        }
        return .unknown
    }
}
