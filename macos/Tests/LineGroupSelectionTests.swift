import XCTest

final class LineGroupSelectionTests: XCTestCase {
    private func profile() -> Profile {
        var value = Profile()
        var group = Line(id: "g", name: "Group", type: "selector")
        group.groupMembers = ["a", "b"]; group.groupDefault = "a"
        value.lines = [Line(id: "direct", name: "Direct", type: "direct"),
                       Line(id: "a", name: "A", type: "anytls"),
                       Line(id: "b", name: "B", type: "anytls"), group]
        return value
    }
    func testAutoAndPinnedUseSameMembershipAndRetainProbeSettings() throws {
        var value = profile()
        value.lines[3].groupURL = "https://example.com/test"
        value.lines[3].groupInterval = "5m"
        try value.selectLineGroupMember(nil, in: "g")
        XCTAssertEqual(value.lines[3].type, "urltest")
        try value.selectLineGroupMember("b", in: "g")
        XCTAssertEqual(value.lines[3].type, "selector")
        XCTAssertEqual(value.lines[3].groupDefault, "b")
        XCTAssertEqual(value.lines[3].groupMembers, ["a", "b"])
        XCTAssertEqual(value.lines[3].groupInterval, "5m")
        XCTAssertEqual(value.lines[3].groupURL, "https://example.com/test")
    }
    func testInvalidAutoConversionLeavesProfileUntouched() throws {
        var value = profile()
        value.lines[3].groupMembers.append("direct")
        let original = value
        XCTAssertThrowsError(try value.selectLineGroupMember(nil, in: "g"))
        XCTAssertEqual(value, original)
        XCTAssertThrowsError(try value.selectLineGroupMember("unknown", in: "g"))
        XCTAssertEqual(value, original)
    }
    func testSubscriptionRetainsProbePreferencesWithoutSelectionChange() throws {
        var record = ProfileRecord(name: "Test", profile: profile())
        record.baseline = record.profile
        record.profile.lines[3].groupURL = "https://example.com/test"
        record.profile.lines[3].groupInterval = "10m"
        let updated = try record.refreshed(with: record.baseline!)
        XCTAssertEqual(updated.profile.lines[3].groupURL, "https://example.com/test")
        XCTAssertEqual(updated.profile.lines[3].groupInterval, "10m")
    }
    func testSubscriptionKeepsAutoOverrideAndRejectsLostPinnedMember() throws {
        var record = ProfileRecord(name: "Test", profile: profile())
        record.baseline = record.profile
        try record.profile.selectLineGroupMember(nil, in: "g")
        let auto = try record.refreshed(with: record.baseline!)
        XCTAssertEqual(auto.profile.lines[3].type, "urltest")
        try record.profile.selectLineGroupMember("b", in: "g")
        let pinned = try record.refreshed(with: record.baseline!)
        XCTAssertEqual(pinned.profile.lines[3].groupDefault, "b")
        var incoming = record.baseline!
        incoming.lines[3].groupMembers = ["a"]
        XCTAssertThrowsError(try record.refreshed(with: incoming))
    }
}

@MainActor
final class LineLatencyStoreTests: XCTestCase {
    func testMeasurementsCannotCrossProfilesTransactionsOrEditedLine() {
        let store = LineLatencyStore()
        var line = Line(id: "a", name: "A", type: "anytls")
        store.bind(transactionID: "one", profileID: "p", lines: [line])
        store.accept([ProviderLineLatency(lineID: "a", milliseconds: 41, observedAt: 100, selectedLineID: nil)])
        XCTAssertTrue(store.isAvailable(line, profileID: "p"))
        XCTAssertFalse(store.isAvailable(line, profileID: "other"))
        line.type = "trojan"
        XCTAssertFalse(store.isAvailable(line, profileID: "p"))
        store.bind(transactionID: "two", profileID: "p", lines: [line])
        XCTAssertNil(store.facts["a"])
        store.bind(transactionID: nil)
        XCTAssertFalse(store.isAvailable(line, profileID: "p"))
    }
    func testManualBatchDeduplicatesMembersWithoutChangingPinnedSelection() async throws {
        let store = LineLatencyStore()
        let a = Line(id: "a", name: "A", type: "anytls")
        let b = Line(id: "b", name: "B", type: "anytls")
        var group = Line(id: "g", name: "G", type: "selector")
        group.groupMembers = ["a", "b"]; group.groupDefault = "b"
        var probes: [String] = []
        store.request = { _, id, _, reply in
            if let id { probes.append(id) }
            reply(.success(id.map { [ProviderLineLatency(lineID: $0, milliseconds: 30, observedAt: 100, selectedLineID: nil)] } ?? []))
        }
        store.bind(transactionID: "one", profileID: "p", lines: [a, b, group])
        store.test([group, a], profileID: "p")
        for _ in 0..<30 where !store.testing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probes, ["a", "b"])
        XCTAssertEqual(group.groupDefault, "b")
        XCTAssertEqual(store.facts["a"]?.milliseconds, 30)
        XCTAssertTrue(store.testing.isEmpty)
    }
    func testUnknownAndOlderResultsAreIgnored() {
        let store = LineLatencyStore()
        store.bind(transactionID: "one", profileID: "p", lines: [Line(id: "a", name: "A", type: "anytls")])
        store.accept([ProviderLineLatency(lineID: "a", milliseconds: 20, observedAt: 100, selectedLineID: nil)])
        store.accept([ProviderLineLatency(lineID: "a", milliseconds: 50, observedAt: 90, selectedLineID: nil),
                      ProviderLineLatency(lineID: "unknown", milliseconds: 1, observedAt: 110, selectedLineID: nil)])
        XCTAssertEqual(store.facts["a"]?.milliseconds, 20)
        XCTAssertNil(store.facts["unknown"])
    }
    func testLateSnapshotAfterDisconnectIsDiscarded() async throws {
        let store = LineLatencyStore()
        var reply: ((Result<[ProviderLineLatency], Error>) -> Void)?
        store.request = { _, _, _, completion in reply = completion }
        store.bind(transactionID: "one", profileID: "p", lines: [Line(id: "a", name: "A", type: "anytls")])
        store.bind(transactionID: nil)
        reply?(.success([ProviderLineLatency(lineID: "a", milliseconds: 20, observedAt: 100, selectedLineID: nil)]))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(store.facts.isEmpty)
    }
}

final class LineLatencyIPCTests: XCTestCase {
    func testAcceptsOnlyCommittedCapabilityAndNoURL() throws {
        for command in [ProviderDiagnosticsCommand.lineLatencySnapshot, .probeLineLatency] {
            let request = ProviderDiagnosticsRequest(cmd: command, transactionID: "tx", lineID: command == .probeLineLatency ? "a" : nil)
            let encoded = try ProviderDiagnosticsCodec.encodeRequest(request)
            XCTAssertEqual(try ProviderDiagnosticsCodec.decodeRequest(encoded), request)
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["test_url"] = "https://example.com/"
            XCTAssertThrowsError(try ProviderDiagnosticsCodec.decodeRequest(JSONSerialization.data(withJSONObject: object)))
        }
    }
}

@MainActor
final class StandaloneLineLatencyStoreTests: XCTestCase {
    private func record(_ ids: [String] = ["a"]) -> ProfileRecord {
        var profile = Profile()
        profile.lines = ids.map { Line(id: $0, name: $0, type: "anytls") }
        return ProfileRecord(id: "p", name: "P", profile: profile)
    }
    func testDisconnectedLineCanBeTestedButBrowsingDoesNotProbe() async throws {
        let store = LineLatencyStore()
        let profile = record()
        let line = profile.profile.lines[0]
        var calls = 0
        store.standaloneRequest = { line, _ in
            calls += 1
            return ProviderLineLatency(lineID: line.id, milliseconds: 43, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([profile])
        XCTAssertNil(store.transactionID)
        XCTAssertTrue(store.canTest(line, profileID: "p"))
        XCTAssertEqual(calls, 0)
        store.test([line], profileID: "p")
        for _ in 0..<40 where store.isTesting(line, profileID: "p") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.measurement(line, profileID: "p")?.milliseconds, 43)
        XCTAssertNil(store.measurement(line, profileID: "other"))
        var edited = line; edited.anytlsPassword = "changed"
        XCTAssertNil(store.measurement(edited, profileID: "p"))
    }
    func testUnconnectedGroupTestsMembersAndNeverInventsAutomaticChoice() async throws {
        let store = LineLatencyStore()
        var profile = record(["a", "b"])
        var group = Line(id: "group", name: "G", type: "selector")
        group.groupMembers = ["a", "b"]; group.groupDefault = "b"
        profile.profile.lines.append(group)
        store.standaloneRequest = { line, _ in
            ProviderLineLatency(lineID: line.id, milliseconds: line.id == "a" ? 10 : 90, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([profile])
        XCTAssertTrue(store.canTest(group, profileID: "p"))
        store.test([group], profileID: "p")
        for _ in 0..<40 where store.isTesting(group, profileID: "p") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.measurement(group, profileID: "p")?.milliseconds, 90)
        group.type = "urltest"; group.groupDefault = ""
        XCTAssertNil(store.measurement(group, profileID: "p"))
    }
    func testBatchBoundsConcurrencyAndDeduplicatesLines() async throws {
        let store = LineLatencyStore()
        let profile = record(["a", "b", "c", "d", "e", "f"])
        var active = 0; var peak = 0; var calls = 0
        store.standaloneRequest = { line, _ in
            active += 1; calls += 1; peak = max(peak, active)
            try await Task.sleep(for: .milliseconds(25))
            active -= 1
            return ProviderLineLatency(lineID: line.id, milliseconds: 27, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([profile])
        store.test(profile.profile.lines + profile.profile.lines, profileID: "p")
        for _ in 0..<50 where profile.profile.lines.contains(where: { store.isTesting($0, profileID: "p") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(peak, 3)
        XCTAssertTrue(profile.profile.lines.allSatisfy { store.measurement($0, profileID: "p") != nil })
    }
    func testImmediateRetryAfterCancelKeepsSingleLeaseForSameLine() async throws {
        let store = LineLatencyStore()
        let profile = record(); let line = profile.profile.lines[0]
        var active = 0; var peak = 0
        store.standaloneRequest = { line, _ in
            active += 1; peak = max(peak, active)
            // Model an already-started bounded C/Go request that cannot be cancelled by Swift.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            active -= 1
            return ProviderLineLatency(lineID: line.id, milliseconds: 31, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([profile]); store.test([line], profileID: "p")
        await Task.yield()
        store.cancelTests(); store.test([line], profileID: "p")
        for _ in 0..<40 where store.isTesting(line, profileID: "p") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(store.measurement(line, profileID: "p")?.milliseconds, 31)
    }
    func testFailureNeverBecomesZeroMilliseconds() async throws {
        let store = LineLatencyStore()
        let profile = record(); let line = profile.profile.lines[0]
        store.standaloneRequest = { _, _ in throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey:"测速超时"]) }
        store.updateCatalogs([profile]); store.test([line], profileID: "p")
        for _ in 0..<40 where store.isTesting(line, profileID: "p") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.measurement(line, profileID: "p"))
        XCTAssertEqual(store.failure(line, profileID: "p"), "测速超时")
    }
    func testProfileEditAndCancellationDiscardLateResults() async throws {
        let store = LineLatencyStore()
        var profile = record(); let original = profile.profile.lines[0]
        store.standaloneRequest = { line, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return ProviderLineLatency(lineID: line.id, milliseconds: 17, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([profile]); store.test([original], profileID: "p")
        await Task.yield()
        profile.profile.lines[0].anytlsPassword = "new-credentials"
        store.updateCatalogs([profile])
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(store.measurement(original, profileID: "p"))
        store.test(profile.profile.lines, profileID: "p")
        await Task.yield()
        store.cancelTests()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(store.isTesting(profile.profile.lines[0], profileID: "p"))
        XCTAssertNil(store.measurement(profile.profile.lines[0], profileID: "p"))
    }
}


@MainActor
final class NativeGroupLatencyIntegrationTests: XCTestCase {
    private func profile() -> ProfileRecord {
        var value = Profile()
        var group = Line(id: "g", name: "Auto", type: "urltest")
        group.groupMembers = ["a", "b"]
        group.groupURL = "https://example.com/latency"
        value.lines = [Line(id: "a", name: "A", type: "anytls"),
                       Line(id: "b", name: "B", type: "anytls"), group]
        return ProfileRecord(id: "p", name: "P", profile: value)
    }
    func testOfflineRecommendationAndGroupURLDoNotChangeConfiguration() async throws {
        let store = LineLatencyStore()
        let record = profile(), group = record.profile.lines[2]
        var targets: [String] = []
        store.standaloneRequest = { line, url in
            targets.append(url)
            return ProviderLineLatency(lineID: line.id, milliseconds: line.id == "a" ? 300 : 40,
                                       observedAt: 100, selectedLineID: nil)
        }
        store.groupSelectionRequest = { lines, facts in
            XCTAssertEqual(lines.count, 3)
            XCTAssertEqual(Set(facts.map(\.lineID)), Set(["a", "b"]))
            return [ProviderLineLatency(lineID: "g", milliseconds: 40, observedAt: 100, selectedLineID: "b")]
        }
        store.updateCatalogs([record])
        XCTAssertNil(store.measurement(group, profileID: "p"))
        store.test([group], profileID: "p")
        for _ in 0..<100 where store.recommendations["p"]?["g"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(targets, [group.groupURL, group.groupURL])
        XCTAssertEqual(store.measurement(group, profileID: "p")?.selectedLineID, "b")
        XCTAssertEqual(store.measurement(group, profileID: "p")?.milliseconds, 40)
        XCTAssertEqual(group.type, "urltest")
        XCTAssertTrue(group.groupDefault.isEmpty)
        XCTAssertNil(store.transactionID)
        XCTAssertNil(store.measurement(group, profileID: "other"))
    }
    func testRuntimeGroupRequestCarriesCapabilityAndAcceptsOlderWinningHistory() async throws {
        let store = LineLatencyStore(), record = profile()
        let group = record.profile.lines[2]
        var groups: [String?] = []
        store.request = { _, id, groupID, reply in
            guard let id else { reply(.success([])); return }
            groups.append(groupID)
            reply(.success([ProviderLineLatency(lineID: id, milliseconds: 300, observedAt: 200, selectedLineID: nil),
                            ProviderLineLatency(lineID: "g", milliseconds: 40, observedAt: 100, selectedLineID: "b")]))
        }
        store.updateCatalogs([record]); store.bind(transactionID: "tx", profileID: "p", lines: record.profile.lines)
        store.accept([ProviderLineLatency(lineID: "g", milliseconds: 300, observedAt: 190, selectedLineID: "a")])
        store.test([group], profileID: "p")
        for _ in 0..<40 where store.isTesting(group, profileID: "p") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(groups, ["g", "g"])
        XCTAssertEqual(store.measurement(group, profileID: "p")?.selectedLineID, "b")
        var edited = record
        edited.profile.lines[1].anytlsPassword = "new"
        store.updateCatalogs([edited])
        XCTAssertFalse(store.isAvailable(group, profileID: "p"))
    }
    func testEditingMembershipDiscardsLateNativeRecommendation() async throws {
        let store = LineLatencyStore()
        var record = profile()
        let group = record.profile.lines[2]
        store.standaloneRequest = { line, _ in
            ProviderLineLatency(lineID: line.id, milliseconds: 30, observedAt: 100, selectedLineID: nil)
        }
        var started = false
        store.groupSelectionRequest = { _, _ in
            started = true
            try await Task.sleep(for: .milliseconds(60))
            return [ProviderLineLatency(lineID: "g", milliseconds: 30, observedAt: 100, selectedLineID: "b")]
        }
        store.updateCatalogs([record]); store.test([group], profileID: "p")
        for _ in 0..<40 where !started { try await Task.sleep(for: .milliseconds(5)) }
        record.profile.lines.removeAll { $0.id == "g" }
        store.updateCatalogs([record])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.recommendations["p"]?["g"])
    }
}

@MainActor
final class ScenarioLatencyAvailabilityTests: XCTestCase {
    private func fixture() -> ProfileRecord {
        var value = Profile()
        var fixed = Line(id: "fixed", name: "Fixed", type: "selector")
        fixed.groupMembers = ["a", "b"]; fixed.groupDefault = "b"
        value.lines = [Line(id: "direct", name: "Direct", type: "direct"),
                       Line(id: "vpn", name: "VPN", type: "vpn"),
                       Line(id: "ts", name: "Tailscale", type: "tailscale"),
                       Line(id: "a", name: "A", type: "anytls"),
                       Line(id: "b", name: "B", type: "anytls"), fixed]
        return ProfileRecord(id: "p", name: "P", profile: value)
    }
    func testMissingVPNMeasurementRequiresItsOwnCommittedCapability() {
        let store = LineLatencyStore(), record = fixture()
        store.standaloneRequest = { _, _ in throw CancellationError() }
        store.updateCatalogs([record])
        let direct = record.profile.lines[0], vpn = record.profile.lines[1], ts = record.profile.lines[2]
        XCTAssertEqual(store.testRequirement(direct, profileID: "p"), .ready)
        XCTAssertEqual(store.testRequirement(vpn, profileID: "p"), .connection)
        XCTAssertEqual(store.testRequirement(ts, profileID: "p"), .connection)
        store.bind(transactionID: "tx", profileID: "other", lines: [vpn])
        XCTAssertEqual(store.testRequirement(vpn, profileID: "p"), .connection)
        store.bind(transactionID: "tx2", profileID: "p", lines: [vpn])
        XCTAssertEqual(store.testRequirement(vpn, profileID: "p"), .ready)
        var fixed = record.profile.lines[5]
        fixed.groupMembers = ["a", "ts"]; fixed.groupDefault = "ts"
        XCTAssertTrue(store.canTest(fixed, profileID: "p"))
        XCTAssertEqual(store.testRequirement(fixed, profileID: "p"), .connection)
        fixed.groupMembers = []
        XCTAssertEqual(store.testRequirement(fixed, profileID: "p"), .members)
    }
    func testAutomaticFillUsesOnlyCurrentScenarioAndFixedSelectionOnce() async throws {
        let store = LineLatencyStore(), record = fixture()
        var calls: [String] = []
        store.standaloneRequest = { line, _ in
            calls.append(line.id)
            return ProviderLineLatency(lineID: line.id, milliseconds: 30, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let scenario = Scenario(id: "s", name: "Current", bindings: [RuleBinding(ruleSetID: "one", lineID: "vpn"), RuleBinding(ruleSetID: "two", lineID: "fixed")], defaultLineID: "direct")
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        for _ in 0..<50 where record.profile.lines.contains(where: { store.isTesting($0, profileID: "p") }) { try await Task.sleep(for: .milliseconds(10)) }
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        XCTAssertEqual(Set(calls), Set(["direct", "b"]))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(record.profile.lines[5].groupDefault, "b")
        XCTAssertNil(store.measurement(record.profile.lines[1], profileID: "p"))
    }
    func testFailureOrStopDoesNotAutomaticallyRetry() async throws {
        let store = LineLatencyStore(), record = fixture()
        var calls = 0
        store.standaloneRequest = { _, _ in calls += 1; throw CancellationError() }
        store.updateCatalogs([record])
        let scenario = Scenario(id: "s", name: "Current", defaultLineID: "direct")
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        try await Task.sleep(for: .milliseconds(30))
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        XCTAssertEqual(calls, 1)
        let second = Scenario(id: "s", name: "Current", defaultLineID: "a")
        store.ensureScenarioMeasurements(second, profileID: "p")
        store.cancelTests()
        try await Task.sleep(for: .milliseconds(30))
        let afterStop = calls
        store.ensureScenarioMeasurements(second, profileID: "p")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, afterStop)
    }
    func testVPNBecomesEligibleAfterConnectAndNativeAutoGroupIsNotDuplicated() async throws {
        let store = LineLatencyStore()
        var record = fixture()
        var group = Line(id: "auto", name: "Auto", type: "urltest")
        group.groupMembers = ["a", "b"]; record.profile.lines.append(group)
        let scenario = Scenario(id: "s", name: "Current", bindings: [RuleBinding(ruleSetID: "one", lineID: "vpn")], defaultLineID: "auto")
        var calls: [String] = []
        store.request = { _, id, _, reply in
            if let id { calls.append(id) }
            reply(.success(id.map { [ProviderLineLatency(lineID: $0, milliseconds: 40, observedAt: 100, selectedLineID: nil)] } ?? []))
        }
        store.updateCatalogs([record])
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        XCTAssertTrue(calls.isEmpty)
        store.bind(transactionID: "tx", profileID: "p", lines: record.profile.lines)
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        for _ in 0..<50 where !store.testing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, ["vpn"])
    }
}

@MainActor
final class ScopedLineLatencyTests: XCTestCase {
    private func fixture() -> ProfileRecord {
        var profile = Profile()
        var group = Line(id: "g", name: "Group", type: "urltest")
        group.groupMembers = ["a", "b"]
        var nested = Line(id: "outer", name: "Outer", type: "selector")
        nested.groupMembers = ["g", "c"]; nested.groupDefault = "g"
        profile.lines = ["a", "b", "c"].map { Line(id: $0, name: $0, type: "anytls") } + [group, nested]
        return ProfileRecord(id: "p", name: "P", profile: profile)
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    func testRowUsesChosenConcreteExitIncludingNestedGroups() async throws {
        let store = LineLatencyStore(), record = fixture()
        let group = record.profile.lines[3], nested = record.profile.lines[4]
        var calls: [String] = []
        store.request = { _, id, _, reply in
            if let id { calls.append(id) }
            reply(.success([]))
        }
        store.updateCatalogs([record]); store.bind(transactionID: "tx", profileID: "p", lines: record.profile.lines)
        store.accept([ProviderLineLatency(lineID: "g", milliseconds: 30, observedAt: 100, selectedLineID: "b")])
        XCTAssertEqual(store.currentExit(nested, profileID: "p")?.id, "b")
        let job = store.test([group, nested], profileID: "p", scope: .currentExit)
        try await settle { !store.isRunning(job) }
        XCTAssertEqual(calls, ["b"])
        XCTAssertEqual(nested.groupDefault, "g")
    }
    func testUnchosenAutomaticRowDoesNotSecretlyTestWholeGroup() async throws {
        let store = LineLatencyStore(), record = fixture(), group = record.profile.lines[3]
        var calls: [String] = []
        store.standaloneRequest = { line, _ in
            calls.append(line.id)
            return ProviderLineLatency(lineID: line.id, milliseconds: 30, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        XCTAssertNil(store.test([group], profileID: "p", scope: .currentExit))
        XCTAssertEqual(store.targetCount([group], profileID: "p", scope: .currentExit), 0)
        let job = store.test([group], profileID: "p", scope: .allMembers)
        try await settle { !store.isRunning(job) }
        XCTAssertEqual(Set(calls), Set(["a", "b"]))
        XCTAssertEqual(calls.count, 2)
    }
    func testRuntimeStopKeepsOtherJobAndSharedProbe() async throws {
        let store = LineLatencyStore(), record = fixture()
        let a = record.profile.lines[0], b = record.profile.lines[1], c = record.profile.lines[2]
        var pending: [(String, (Result<[ProviderLineLatency], Error>) -> Void)] = []
        store.request = { _, id, _, reply in
            if let id { pending.append((id, reply)) } else { reply(.success([])) }
        }
        store.updateCatalogs([record]); store.bind(transactionID: "tx", profileID: "p", lines: record.profile.lines)
        let first = store.test([a, b], profileID: "p")
        let second = store.test([a, c], profileID: "p")
        try await settle { pending.count == 1 }
        store.cancel(first)
        XCTAssertFalse(store.isRunning(first)); XCTAssertTrue(store.isRunning(second))
        XCTAssertFalse(store.isTesting(b, profileID: "p"))
        XCTAssertTrue(store.isTesting(a, profileID: "p"))
        pending[0].1(.success([ProviderLineLatency(lineID: "a", milliseconds: 42, observedAt: 100, selectedLineID: nil)]))
        try await settle { pending.count == 2 }
        XCTAssertEqual(pending.map(\.0), ["a", "c"])
        pending[1].1(.success([]))
        try await settle { !store.isRunning(second) }
        XCTAssertEqual(store.measurement(a, profileID: "p")?.milliseconds, 42)
    }
    func testRuntimeImmediateRetryWaitsForCancelledCallAndDiscardsItsResult() async throws {
        let store = LineLatencyStore(), record = fixture(), line = record.profile.lines[0]
        var replies: [(Result<[ProviderLineLatency], Error>) -> Void] = []
        store.request = { _, id, _, reply in
            if id != nil { replies.append(reply) } else { reply(.success([])) }
        }
        store.bind(transactionID: "tx", profileID: "p", lines: record.profile.lines)
        let first = store.test([line], profileID: "p")
        try await settle { replies.count == 1 }
        store.cancel(first)
        let second = store.test([line], profileID: "p")
        await Task.yield()
        XCTAssertEqual(replies.count, 1)
        replies[0](.success([ProviderLineLatency(lineID: "a", milliseconds: 999, observedAt: 100, selectedLineID: nil)]))
        try await settle { replies.count == 2 }
        XCTAssertTrue(store.isRunning(second)); XCTAssertNil(store.measurement(line, profileID: "p"))
        replies[1](.success([ProviderLineLatency(lineID: "a", milliseconds: 21, observedAt: 200, selectedLineID: nil)]))
        try await settle { !store.isRunning(second) }
        XCTAssertEqual(store.measurement(line, profileID: "p")?.milliseconds, 21)
    }
    func testStandaloneStopKeepsSharedProbeAndDoesNotMarkOtherGroupsBusy() async throws {
        let store = LineLatencyStore(), record = fixture()
        var calls: [String] = []
        store.standaloneRequest = { line, _ in
            calls.append(line.id)
            try await Task.sleep(for: .milliseconds(40))
            return ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let first = store.test([record.profile.lines[3]], profileID: "p")
        let second = store.test([record.profile.lines[0], record.profile.lines[2]], profileID: "p")
        XCTAssertFalse(store.isTesting(record.profile.lines[4], profileID: "p"))
        await Task.yield()
        store.cancel(first)
        XCTAssertFalse(store.isTesting(record.profile.lines[3], profileID: "p"))
        XCTAssertTrue(store.isRunning(second))
        try await settle { !store.isRunning(second) }
        XCTAssertEqual(calls.filter { $0 == "a" }.count, 1)
        XCTAssertNotNil(store.measurement(record.profile.lines[0], profileID: "p"))
        XCTAssertNotNil(store.measurement(record.profile.lines[2], profileID: "p"))
        XCTAssertNil(store.failure(record.profile.lines[1], profileID: "p"))
    }
    func testStoppedManualProbeIsNotRequeuedByAutomaticFill() async throws {
        let store = LineLatencyStore(), record = fixture()
        var calls = 0
        store.standaloneRequest = { line, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return ProviderLineLatency(lineID: line.id, milliseconds: 20, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let job = store.test([record.profile.lines[0]], profileID: "p", scope: .currentExit)
        await Task.yield()
        store.cancel(job)
        let scenario = Scenario(id: "s", name: "Current", defaultLineID: "a")
        store.ensureScenarioMeasurements(scenario, profileID: "p")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isTesting(record.profile.lines[0], profileID: "p"))
    }
    func testUnrelatedProbeRetainsNativeRecommendationAndFilteredBatchScope() async throws {
        let store = LineLatencyStore(), record = fixture(), group = record.profile.lines[3]
        store.standaloneRequest = { line, _ in
            ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.groupSelectionRequest = { _, _ in
            [ProviderLineLatency(lineID: "g", milliseconds: 25, observedAt: 100, selectedLineID: "a")]
        }
        store.updateCatalogs([record]); store.test([group], profileID: "p")
        try await settle { store.measurement(group, profileID: "p") != nil }
        var calls: [String] = []
        store.standaloneRequest = { line, _ in
            calls.append(line.id)
            try await Task.sleep(for: .milliseconds(30))
            return ProviderLineLatency(lineID: line.id, milliseconds: 50, observedAt: 200, selectedLineID: nil)
        }
        let filtered = record.profile.lines.filter { $0.name == "c" }
        XCTAssertEqual(store.targetCount(filtered, profileID: "p"), 1)
        let job = store.test(filtered, profileID: "p")
        XCTAssertEqual(store.measurement(group, profileID: "p")?.selectedLineID, "a")
        XCTAssertFalse(store.isTesting(group, profileID: "p"))
        try await settle { !store.isRunning(job) }
        XCTAssertEqual(calls, ["c"])
    }
}

@MainActor
final class LineLatencyControlLifetimeTests: XCTestCase {
    private func fixture(id: String = "p") -> ProfileRecord {
        var profile = Profile()
        var group = Line(id: "group", name: "Group", type: "selector")
        group.groupMembers = ["a", "b"]; group.groupDefault = "a"
        profile.lines = ["a", "b", "c"].map { Line(id: $0, name: $0, type: "anytls") } + [group]
        return ProfileRecord(id: id, name: id, profile: profile)
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    func testRecreatedCatalogControlFindsOriginalJobAndFilteredSnapshot() async throws {
        let store = LineLatencyStore(), record = fixture()
        var calls: [String] = []
        store.standaloneRequest = { line, _ in
            calls.append(line.id)
            try await Task.sleep(for: .milliseconds(50))
            return ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let original = store.test(Array(record.profile.lines.prefix(2)), profileID: "p", control: .catalog(groupsOnly: false))
        // A fresh view has no local state; it reconstructs only the control identity.
        let restored = try XCTUnwrap(store.activeJob(for: .catalog(groupsOnly: false), profileID: "p"))
        XCTAssertEqual(restored.id, original)
        XCTAssertEqual(restored.count, 2)
        // Search can reset/change while away, but cannot enlarge the running job.
        let repeated = store.test([record.profile.lines[2]], profileID: "p", control: .catalog(groupsOnly: false))
        XCTAssertEqual(repeated, original)
        try await settle { !store.isRunning(original) }
        XCTAssertEqual(Set(calls), Set(["a", "b"]))
        XCTAssertNil(store.activeJob(for: .catalog(groupsOnly: false), profileID: "p"))
    }
    func testTabProfileAndGroupControlsRetainIndependentStopOwnership() async throws {
        let store = LineLatencyStore(), record = fixture(), other = fixture(id: "other")
        store.standaloneRequest = { line, _ in
            try await Task.sleep(for: .milliseconds(50))
            return ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record, other])
        let catalog = store.test([record.profile.lines[0]], profileID: "p", control: .catalog(groupsOnly: false))
        let group = store.test([record.profile.lines[3]], profileID: "p", control: .group("group"))
        let otherProfile = store.test([other.profile.lines[0]], profileID: "other", control: .catalog(groupsOnly: false))
        XCTAssertNil(store.activeJob(for: .catalog(groupsOnly: true), profileID: "p"))
        XCTAssertNil(store.activeJob(for: .candidates("group"), profileID: "p"))
        store.cancel(store.activeJob(for: .catalog(groupsOnly: false), profileID: "p")?.id)
        XCTAssertFalse(store.isRunning(catalog))
        XCTAssertTrue(store.isRunning(group)); XCTAssertTrue(store.isRunning(otherProfile))
        XCTAssertTrue(store.isTesting(record.profile.lines[0], profileID: "p"))
        try await settle { !store.isRunning(group) && !store.isRunning(otherProfile) }
        XCTAssertNil(store.activeJob(for: .group("group"), profileID: "p"))
    }
    func testRecreatedLineControlCanStopItsQueuedTaskWithoutCancellingBatch() async throws {
        let store = LineLatencyStore(), record = fixture(), line = record.profile.lines[0]
        store.standaloneRequest = { line, _ in
            try await Task.sleep(for: .milliseconds(40))
            return ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let row = store.test([line], profileID: "p", scope: .currentExit, control: .line(line.id, groupID: nil))
        let batch = store.test([line], profileID: "p", control: .catalog(groupsOnly: false))
        let restored = try XCTUnwrap(store.activeJob(for: .line(line.id, groupID: nil), profileID: "p"))
        XCTAssertEqual(restored.id, row)
        store.cancel(restored.id)
        XCTAssertNil(store.activeJob(for: .line(line.id, groupID: nil), profileID: "p"))
        XCTAssertTrue(store.isRunning(batch))
        try await settle { !store.isRunning(batch) }
        XCTAssertEqual(store.measurement(line, profileID: "p")?.milliseconds, 25)
    }
    func testChangingGroupChildRemovesUnusableTaskAndDoesNotReviveItOnReturn() async throws {
        let store = LineLatencyStore()
        var record = fixture()
        store.standaloneRequest = { line, _ in
            try? await Task.sleep(for: .milliseconds(30))
            return ProviderLineLatency(lineID: line.id, milliseconds: 25, observedAt: 100, selectedLineID: nil)
        }
        store.updateCatalogs([record])
        let old = store.test([record.profile.lines[3]], profileID: "p", control: .group("group"))
        await Task.yield()
        record.profile.lines[0].anytlsPassword = "changed"
        store.updateCatalogs([record])
        XCTAssertFalse(store.isRunning(old))
        XCTAssertNil(store.activeJob(for: .group("group"), profileID: "p"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(store.activeJob(for: .group("group"), profileID: "p"))
    }
    func testFailureOrRuntimeReplacementClearsRestoredButtonState() async throws {
        let store = LineLatencyStore(), record = fixture(), line = record.profile.lines[0]
        store.standaloneRequest = { _, _ in throw CancellationError() }
        store.updateCatalogs([record])
        let failed = store.test([line], profileID: "p", control: .catalog(groupsOnly: false))
        try await settle { !store.isRunning(failed) }
        XCTAssertNil(store.activeJob(for: .catalog(groupsOnly: false), profileID: "p"))
        store.bind(transactionID: "old", profileID: "p", lines: record.profile.lines)
        let runtime = store.test([line], profileID: "p", control: .line(line.id, groupID: nil))
        store.bind(transactionID: nil)
        XCTAssertFalse(store.isRunning(runtime))
        XCTAssertNil(store.activeJob(for: .line(line.id, groupID: nil), profileID: "p"))
    }
}
