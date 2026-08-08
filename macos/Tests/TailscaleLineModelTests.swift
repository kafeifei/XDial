import Foundation
import XCTest

final class TailscaleLineModelTests: XCTestCase {
    func testLegacyTailscaleLineDefaultsMagicDNSOff() throws {
        let data = Data(#"{"id":"tail","name":"Tailnet","type":"tailscale"}"#.utf8)
        let line = try JSONDecoder().decode(Line.self, from: data)

        XCTAssertFalse(line.tailscaleMagicDNS)
    }

    func testMagicDNSToggleRoundTripsThroughProfileJSON() throws {
        let source = Line(
            id: "tail",
            name: "Tailnet",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.9",
            tailscaleMagicDNS: true
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Line.self, from: encoded)

        XCTAssertTrue(decoded.tailscaleMagicDNS)
        XCTAssertEqual(decoded.tailscaleExitNode, "100.64.0.9")
    }
}
