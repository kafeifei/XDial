import XCTest

final class TransparentProxyDNSCapturePlanTests: XCTestCase {
    func testDecodesOnlyBoundedRuntimeMetadata() throws {
        XCTAssertEqual(
            try TransparentProxyDNSCapturePlan
                .decodePreparedTailscaleDNS(
                    """
                    {
                      "capture_domains": [
                        "Example-Tailnet.ts.net.",
                        "MBA32K"
                      ],
                      "record_count": 2,
                      "owned_domain_count": 1
                    }
                    """
                ),
            TransparentProxyPreparedTailscaleDNS(
                captureDomains: [
                    "example-tailnet.ts.net",
                    "mba32k",
                ],
                recordCount: 2
            )
        )
    }

    func testRejectsMissingOrEmptyRuntimeRecords() {
        for metadataJSON in [
            "{}",
            """
            {
              "capture_domains": ["example-tailnet.ts.net"],
              "record_count": 0
            }
            """,
        ] {
            XCTAssertThrowsError(
                try TransparentProxyDNSCapturePlan
                    .decodePreparedTailscaleDNS(metadataJSON)
            )
        }
    }

    func testRejectsUnboundedRuntimeRecordCount() {
        XCTAssertThrowsError(
            try TransparentProxyDNSCapturePlan
                .decodePreparedTailscaleDNS(
                    """
                    {
                      "capture_domains": ["example-tailnet.ts.net"],
                      "record_count": \(TransparentProxyDNSCapturePlan.maximumRecordCount + 1)
                    }
                    """
                )
        )
    }

    func testRejectsImpossibleOwnedDomainCount() {
        XCTAssertThrowsError(
            try TransparentProxyDNSCapturePlan
                .decodePreparedTailscaleDNS(
                    """
                    {
                      "capture_domains": ["example-tailnet.ts.net"],
                      "record_count": 1,
                      "owned_domain_count": 2
                    }
                    """
                )
        )
    }

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
