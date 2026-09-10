import Darwin
import Foundation

/// Only used on the installer's private, signature-validated copy. A copied
/// download otherwise keeps its quarantine and LaunchServices may translocate
/// even /Applications/XDial.app, sending its successor back into installation.
enum ApplicationInstallationQuarantine {
    static func prepareValidatedCopy(at bundleURL: URL) throws {
        try visitBundle(at: bundleURL) { url in
            guard removexattr(
                url.path, "com.apple.quarantine", XATTR_NOFOLLOW
            ) == 0 else {
                let code = errno
                if code != ENOATTR { throw posixError(code, at: url) }
                return
            }
        }
    }

    /// Check again inside the replacement transaction, before discarding the
    /// backup: replacement must not restore the old destination's quarantine.
    static func validateInstalledCopy(at bundleURL: URL) throws {
        try visitBundle(at: bundleURL) { url in
            let size = getxattr(
                url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW
            )
            if size >= 0 {
                throw NSError(
                    domain: "XDial.ApplicationInstallationQuarantine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "安装副本仍带有下载隔离属性，无法从应用程序目录启动。"]
                )
            }
            let code = errno
            if code != ENOATTR { throw posixError(code, at: url) }
        }
    }

    private static func visitBundle(
        at bundleURL: URL,
        visit: (URL) throws -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        let root = try bundleURL.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw posixError(EINVAL, at: bundleURL)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw posixError(EIO, at: bundleURL)
        }
        try visit(bundleURL)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            try visit(url)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func posixError(_ code: Int32, at url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
