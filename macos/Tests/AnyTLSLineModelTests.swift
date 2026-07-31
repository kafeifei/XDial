import XCTest

final class AnyTLSLineModelTests: XCTestCase {
    func testNewAnyTLSLineUsesExplicitRecommendedOptions() {
        let line = Line(id: "new", name: "New", type: "anytls")

        XCTAssertEqual(line.anytlsClientFingerprint, "chrome")
        XCTAssertEqual(line.anytlsALPN, ["h2"])
        XCTAssertEqual(line.anytlsIdleSessionCheckInterval, 30)
        XCTAssertEqual(line.anytlsIdleSessionTimeout, 30)
        XCTAssertEqual(line.anytlsMinIdleSession, 0)
        XCTAssertTrue(line.udp)
        XCTAssertFalse(line.tfo)
        XCTAssertFalse(line.allowInsecure)
        XCTAssertNil(line.anyTLSOptionsValidationIssue)
    }

    func testLegacyLineDoesNotGainFingerprintOrALPNDuringDecode() throws {
        let data = Data("""
        {
          "id": "legacy",
          "name": "Legacy",
          "type": "anytls",
          "anytls_server": "legacy.example.com",
          "anytls_port": 443,
          "anytls_password": "secret",
          "allow_insecure": true
        }
        """.utf8)

        let line = try JSONDecoder().decode(Line.self, from: data)

        XCTAssertEqual(line.anytlsClientFingerprint, "")
        XCTAssertEqual(line.anytlsALPN, [])
        XCTAssertEqual(line.anytlsIdleSessionCheckInterval, 0)
        XCTAssertEqual(line.anytlsIdleSessionTimeout, 0)
        XCTAssertEqual(line.anytlsMinIdleSession, 0)
        XCTAssertFalse(line.udp)
        XCTAssertFalse(line.tfo)
        XCTAssertTrue(line.allowInsecure)
        XCTAssertNil(line.anyTLSOptionsValidationIssue)
    }

    func testAnyTLSOptionsRoundTripWithStableJSONKeys() throws {
        let source = Line(
            id: "taiwan",
            name: "Taiwan",
            type: "anytls",
            anytlsServer: "node.example.com",
            anytlsPort: 3489,
            anytlsPassword: "secret",
            anytlsSNI: "video.example.com",
            anytlsClientFingerprint: "chrome",
            anytlsALPN: ["h2", "http/1.1"],
            anytlsIdleSessionCheckInterval: 30,
            anytlsIdleSessionTimeout: 45,
            anytlsMinIdleSession: 2,
            udp: true,
            tfo: false,
            allowInsecure: true
        )

        let data = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(
            object["anytls_client_fingerprint"] as? String,
            "chrome"
        )
        XCTAssertEqual(
            object["anytls_alpn"] as? [String],
            ["h2", "http/1.1"]
        )
        XCTAssertEqual(
            object["anytls_idle_session_check_interval"] as? Int,
            30
        )
        XCTAssertEqual(
            object["anytls_idle_session_timeout"] as? Int,
            45
        )
        XCTAssertEqual(
            object["anytls_min_idle_session"] as? Int,
            2
        )
        XCTAssertEqual(object["udp"] as? Bool, true)
        XCTAssertEqual(object["tfo"] as? Bool, false)
        XCTAssertEqual(object["allow_insecure"] as? Bool, true)

        let decoded = try JSONDecoder().decode(Line.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    func testALPNValidationUsesProtocolLevelBoundaries() {
        XCTAssertNil(Line.validateAnyTLSALPN([]))
        XCTAssertNil(Line.validateAnyTLSALPN([
            "h2",
            "协议",
            "custom,protocol",
        ]))
        XCTAssertNotNil(Line.validateAnyTLSALPN(["h2", "h2"]))
        XCTAssertNotNil(Line.validateAnyTLSALPN([""]))
        XCTAssertNotNil(Line.validateAnyTLSALPN(["bad\u{0000}name"]))
        XCTAssertNotNil(Line.validateAnyTLSALPN([
            String(repeating: "a", count: 256),
        ]))
        XCTAssertNotNil(Line.validateAnyTLSALPN(
            (0...Line.anyTLSMaximumALPNCount).map { "p\($0)" }
        ))
    }

    func testUnsupportedFingerprintAndUnboundedPoolOptionsAreVisible() {
        var line = Line(id: "bad", name: "Bad", type: "anytls")

        line.anytlsClientFingerprint = "made-up"
        XCTAssertNotNil(line.anyTLSOptionsValidationIssue)

        line.anytlsClientFingerprint = "chrome"
        line.anytlsIdleSessionCheckInterval = 5
        XCTAssertNotNil(line.anyTLSOptionsValidationIssue)

        line.anytlsIdleSessionCheckInterval = 6
        XCTAssertNil(line.anyTLSOptionsValidationIssue)

        line.anytlsIdleSessionCheckInterval = 3601
        XCTAssertNotNil(line.anyTLSOptionsValidationIssue)

        line.anytlsIdleSessionCheckInterval = 30
        line.anytlsMinIdleSession = 65
        XCTAssertNotNil(line.anyTLSOptionsValidationIssue)
    }

    func testImportedAnyTLSTFOIsPreservedForFailClosedValidation() throws {
        let data = Data("""
        {
          "id": "imported",
          "name": "Imported",
          "type": "anytls",
          "udp": true,
          "tfo": true
        }
        """.utf8)

        let line = try JSONDecoder().decode(Line.self, from: data)
        XCTAssertTrue(line.udp)
        XCTAssertTrue(line.tfo)
        XCTAssertEqual(
            line.anyTLSOptionsValidationIssue,
            "AnyTLS 不支持 TCP Fast Open，请关闭 TFO"
        )

        let encoded = try JSONEncoder().encode(line)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        XCTAssertEqual(object["udp"] as? Bool, true)
        XCTAssertEqual(object["tfo"] as? Bool, true)
    }
}
