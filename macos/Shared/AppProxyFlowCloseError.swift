import Foundation
import Network
@preconcurrency import NetworkExtension

/// Normalizes errors exposed to a source application by an app-proxy flow.
///
/// NetworkExtension requires every non-nil close error to use
/// `NEAppProxyErrorDomain`. Passing an `NWError` or `CancellationError`
/// directly can leave the source-side socket in an undefined teardown state.
enum AppProxyFlowCloseError {
    static var aborted: NSError {
        make(.aborted)
    }

    static func normalize(_ error: Error?) -> NSError? {
        guard let error else {
            return nil
        }
        let nsError = error as NSError
        if nsError.domain == NEAppProxyErrorDomain {
            return nsError
        }
        if error is CancellationError {
            return make(.aborted)
        }
        if let networkError = error as? NWError {
            return make(code(for: networkError))
        }
        if nsError.domain == NSPOSIXErrorDomain,
           let posixCode = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return make(code(for: posixCode))
        }
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorTimedOut {
            return make(.timedOut)
        }
        return make(.internal)
    }

    private static func code(
        for networkError: NWError
    ) -> NEAppProxyFlowError.Code {
        switch networkError {
        case let .posix(code):
            return self.code(for: code)
        case .dns:
            return .hostUnreachable
        case .tls:
            return .internal
#if compiler(>=6.2)
        case .wifiAware:
            return .internal
#endif
        @unknown default:
            return .internal
        }
    }

    private static func code(
        for posixCode: POSIXErrorCode
    ) -> NEAppProxyFlowError.Code {
        switch posixCode {
        case .ECANCELED:
            return .aborted
        case .ECONNRESET, .EPIPE:
            return .peerReset
        case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN:
            return .hostUnreachable
        case .ECONNREFUSED:
            return .refused
        case .ETIMEDOUT:
            return .timedOut
        case .EMSGSIZE:
            return .datagramTooLarge
        default:
            return .internal
        }
    }

    private static func make(
        _ code: NEAppProxyFlowError.Code
    ) -> NSError {
        NSError(
            domain: NEAppProxyErrorDomain,
            code: code.rawValue,
            userInfo: nil
        )
    }
}
