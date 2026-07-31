import Network
import NetworkExtension
import XCTest

final class AppProxyFlowCloseErrorTests: XCTestCase {
    func testNilRemainsNil() {
        XCTAssertNil(AppProxyFlowCloseError.normalize(nil))
    }

    func testExistingAppProxyErrorIsPreserved() {
        let existing = NSError(
            domain: NEAppProxyErrorDomain,
            code: NEAppProxyFlowError.peerReset.rawValue
        )

        XCTAssertTrue(
            AppProxyFlowCloseError.normalize(existing) === existing
        )
    }

    func testCancellationMapsToAborted() {
        assertCloseError(
            AppProxyFlowCloseError.normalize(CancellationError()),
            code: .aborted
        )
    }

    func testNetworkErrorsMapToSupportedSourceErrors() {
        assertCloseError(
            AppProxyFlowCloseError.normalize(
                NWError.posix(.ECONNRESET)
            ),
            code: .peerReset
        )
        assertCloseError(
            AppProxyFlowCloseError.normalize(
                NWError.posix(.ETIMEDOUT)
            ),
            code: .timedOut
        )
        assertCloseError(
            AppProxyFlowCloseError.normalize(
                NWError.posix(.ENETUNREACH)
            ),
            code: .hostUnreachable
        )
    }

    func testUnknownErrorNeverEscapesItsOriginalDomain() {
        let original = NSError(domain: "untrusted.relay", code: 42)
        assertCloseError(
            AppProxyFlowCloseError.normalize(original),
            code: .internal
        )
    }

    private func assertCloseError(
        _ error: NSError?,
        code: NEAppProxyFlowError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            error?.domain,
            NEAppProxyErrorDomain,
            file: file,
            line: line
        )
        XCTAssertEqual(
            error?.code,
            code.rawValue,
            file: file,
            line: line
        )
    }
}
