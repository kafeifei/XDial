import Foundation
import XCTest

final class ServiceManagementErrorDiagnosticsTests: XCTestCase {
    func testForeignDomainsWithSameServiceErrorCodesDoNotMatch() {
        for code in [6, 12] { // JobNotFound and AlreadyRegistered.
            for domain in [NSPOSIXErrorDomain, NSCocoaErrorDomain] {
                XCTAssertFalse(ServiceManagementErrorDiagnostics.matches(
                    NSError(domain: domain, code: code), domain: "SMAppServiceErrorDomain", code: code
                ))
            }
        }
    }

    func testServiceDomainAndCodeMustBothMatch() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 12)
        XCTAssertTrue(ServiceManagementErrorDiagnostics.matches(
            error, domain: "SMAppServiceErrorDomain", code: 12
        ))
        XCTAssertFalse(ServiceManagementErrorDiagnostics.matches(
            error, domain: "SMAppServiceErrorDomain", code: 6
        ))
    }

    func testSummaryPreservesUnderlyingCodesWithoutArbitraryUserInfo() {
        let cause = NSError(domain: NSPOSIXErrorDomain, code: 1)
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [
            NSUnderlyingErrorKey: cause, "privatePayload": "must-not-be-logged",
        ])
        let summary = ServiceManagementErrorDiagnostics.summary(error)
        XCTAssertTrue(summary.contains("error.domain=SMAppServiceErrorDomain error.code=1"))
        XCTAssertTrue(summary.contains("underlying1.domain=NSPOSIXErrorDomain underlying1.code=1"))
        XCTAssertFalse(summary.contains("must-not-be-logged"))
    }
}
