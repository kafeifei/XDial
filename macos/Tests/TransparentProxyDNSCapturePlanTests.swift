import XCTest

final class TransparentProxyDNSCapturePlanTests: XCTestCase {
    func testNormalizesDomainsFromTailscaleRuntime() throws {
        XCTAssertEqual(
            try TransparentProxyDNSCapturePlan.validate([
                "MBA32K",
                "example-tailnet.ts.net.",
                "corp.example.com",
                "mba32k",
            ]),
            [
                "corp.example.com",
                "example-tailnet.ts.net",
                "mba32k",
            ]
        )
    }

    func testRejectsGlobalOrMalformedCaptureDomains() {
        for domains in [["."], ["bad domain"], ["a..example.com"]] {
            XCTAssertThrowsError(
                try TransparentProxyDNSCapturePlan.validate(domains)
            )
        }
    }

    func testRejectsUnboundedCaptureDomainSet() {
        XCTAssertThrowsError(
            try TransparentProxyDNSCapturePlan.validate(
                (0 ... TransparentProxyDNSCapturePlan.maximumDomainCount)
                    .map { "host-\($0)" }
            )
        )
    }
}
