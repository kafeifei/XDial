import Combine
import Foundation

/// Ephemeral native and explicit measurements, never saved with a Profile.
@MainActor
final class LineLatencyStore: ObservableObject {
    @Published private(set) var facts: [String: ProviderLineLatency] = [:]
    @Published private(set) var testing: Set<String> = []
    @Published private(set) var failures: Set<String> = []
    private(set) var transactionID: String?
    private(set) var profileID: String?
    private var lines: [String: Line] = [:]
    private var snapshotInFlight = false
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var queue: [String] = []
    private var queueGroups: [String: String] = [:]
    typealias Request = (String, String?, String?, @escaping (Result<[ProviderLineLatency], Error>) -> Void) -> Void
    var request: Request?

    // Explicit tests of ordinary proxies are independent of the active Scenario.
    // Complete connection parameters form the cache key; IDs alone can be reused.
    struct ProbeKey: Hashable {
        let profileID: String
        let line: Line
        init(_ line: Line, profileID: String) {
            self.profileID = profileID
            var connection = line
            connection.name = ""; connection.verified = false
            self.line = connection
        }
    }
    enum ProbeState: Equatable {
        case queued, running
        case measured(ProviderLineLatency)
        case failed(String, Int64)
    }
    @Published private(set) var standalone: [ProbeKey: ProbeState] = [:]
    private var catalogs: [String: [String: Line]] = [:]
    private var standaloneQueue: [ProbeKey] = []
    private var standaloneTasks: [ProbeKey: (UUID, Task<Void, Never>)] = [:]
    private var standaloneTargets: [ProbeKey: String] = [:]
    var standaloneRequest: ((Line, String) async throws -> ProviderLineLatency)?
    var groupSelectionRequest: (([Line], [ProviderLineLatency]) async throws -> [ProviderLineLatency])?
    @Published private(set) var recommendations: [String: [String: ProviderLineLatency]] = [:]
    private var evaluationTokens: [String: UUID] = [:]
    private var automaticAttempts: Set<ProbeKey> = []

    enum TestScope { case currentExit, allMembers }
    /// Stable control identity survives tab, popover, and lazy-row recreation.
    /// The Profile is part of ownership, but search results are a job snapshot.
    enum TestControl: Hashable {
        case line(String, groupID: String?)
        case catalog(groupsOnly: Bool)
        case group(String)
        case candidates(String)
    }
    private struct TestOwner: Hashable {
        let profileID: String
        let control: TestControl
    }
    struct ActiveJob: Equatable {
        let id: UUID
        let count: Int
    }
    private enum PendingProbe: Hashable {
        case runtime(String, ProbeKey)
        case standalone(ProbeKey)
    }
    private struct Job {
        var probes: Set<PendingProbe>
        let roots: [ProbeKey: Set<PendingProbe>]
        let owner: TestOwner?
        let count: Int
    }
    @Published private var jobs: [UUID: Job] = [:]
    private var runtimeTokens: [String: UUID] = [:]

    func activeJob(for control: TestControl, profileID: String) -> ActiveJob? {
        let owner = TestOwner(profileID: profileID, control: control)
        guard let entry = jobs.first(where: { $0.value.owner == owner }) else { return nil }
        return ActiveJob(id: entry.key, count: entry.value.count)
    }

    func isRunning(_ jobID: UUID?) -> Bool { jobID.map { jobs[$0] != nil } ?? false }

    /// Shared probes may belong to several clicks. Stopping one click only
    /// drops its ownership; an in-flight native call retains its concurrency lease.
    func cancel(_ jobID: UUID?) {
        guard let jobID, let job = jobs.removeValue(forKey: jobID) else { return }
        for probe in job.probes where !jobs.values.contains(where: { $0.probes.contains(probe) }) {
            switch probe {
            case let .runtime(tx, key):
                guard tx == transactionID else { continue }
                queue.removeAll { $0 == key.line.id }
                queueGroups.removeValue(forKey: key.line.id)
                runtimeTokens.removeValue(forKey: key.line.id)
                testing.remove(key.line.id)
            case let .standalone(key):
                standaloneQueue.removeAll { $0 == key }
                standaloneTargets.removeValue(forKey: key)
                standaloneTasks[key]?.1.cancel()
                standalone.removeValue(forKey: key)
            }
        }
    }
    private func finish(_ probe: PendingProbe) {
        var next = jobs
        for id in next.keys {
            next[id]?.probes.remove(probe)
            if next[id]?.probes.isEmpty == true { next.removeValue(forKey: id) }
        }
        if next.keys.contains(where: { jobs[$0]?.probes != next[$0]?.probes }) || next.count != jobs.count { jobs = next }
    }

    /// Resolve a displayed group to its authoritative current exit. An offline
    /// automatic group without a native recommendation has no chosen exit yet.
    func currentExit(_ line: Line, profileID: String) -> Line? {
        let catalog = catalogs[profileID] ?? (self.profileID == profileID ? lines : [:])
        var visited: Set<String> = []
        func resolve(_ item: Line) -> Line? {
            guard visited.insert(item.id).inserted else { return nil }
            guard item.isGroup else { return item }
            if let selected = measurement(item, profileID: profileID)?.selectedLineID,
               let child = catalog[selected], selected != item.id,
               leaves(item, profileID: profileID).contains(where: { $0.id == selected }) {
                return resolve(child)
            }
            if item.type == "selector" {
                let id = item.groupDefault.isEmpty ? item.groupMembers.first : item.groupDefault
                if let id, item.groupMembers.contains(id), let child = catalog[id] { return resolve(child) }
            }
            return nil
        }
        return resolve(line)
    }

    func targetCount(_ requested: [Line], profileID: String, scope: TestScope = .allMembers) -> Int {
        Set(requested.flatMap { line -> [Line] in
            scope == .allMembers ? leaves(line, profileID: profileID) : currentExit(line, profileID: profileID).map { [$0] } ?? []
        }.filter { canTest($0, profileID: profileID) }.map(\.id)).count
    }

    enum TestRequirement: Equatable {
        case ready, connection, members, unavailable
    }

    /// Explain the missing measurement for the selected exit, not merely
    /// whether some other member of its group could be tested.
    func testRequirement(_ line: Line, profileID: String) -> TestRequirement {
        testRequirement(line, profileID: profileID, visited: [])
    }
    private func testRequirement(_ line: Line, profileID: String, visited: Set<String>) -> TestRequirement {
        guard !visited.contains(line.id) else { return .unavailable }
        if line.isGroup {
            guard !line.groupMembers.isEmpty else { return .members }
            let catalog = catalogs[profileID] ?? (self.profileID == profileID ? lines : [:])
            if line.type == "selector" {
                let selected = line.groupDefault.isEmpty ? line.groupMembers.first : line.groupDefault
                guard let selected, let member = catalog[selected] else { return .unavailable }
                return testRequirement(member, profileID: profileID, visited: visited.union([line.id]))
            }
            let requirements = line.groupMembers.compactMap { catalog[$0] }.map {
                testRequirement($0, profileID: profileID, visited: visited.union([line.id]))
            }
            if requirements.contains(.ready) { return .ready }
            return requirements.contains(.connection) ? .connection : .unavailable
        }
        if isAvailable(line, profileID: profileID) || supportsStandalone(line) { return .ready }
        return ["vpn", "tailscale"].contains(line.type) ? .connection : .unavailable
    }

    /// Fill only the current Scenario's missing measurements, once per line
    /// configuration/runtime. Native active URLTests keep their own schedule.
    func ensureScenarioMeasurements(_ scenario: Scenario, profileID: String) {
        guard let catalog = catalogs[profileID] else { return }
        let ids = scenario.bindings.filter { $0.subscriptionID.isEmpty }.map(\.lineID)
            + (scenario.defaultSubscriptionID.isEmpty ? [scenario.defaultLineID] : [])
        test(ids.compactMap { catalog[$0] }, profileID: profileID, onlyMissing: true)
    }

    func updateCatalogs(_ profiles: [ProfileRecord]) {
        let previous = catalogs
        catalogs = Dictionary(profiles.map { record in
            (record.id, Dictionary(record.profile.lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }, uniquingKeysWith: { a, _ in a })
        func current(_ key: ProbeKey) -> Bool {
            guard let line = catalogs[key.profileID]?[key.line.id] else { return false }
            return key == ProbeKey(line, profileID: key.profileID)
        }
        standaloneQueue.removeAll { !current($0) }
        for (key, entry) in standaloneTasks where !current(key) { entry.1.cancel() }
        let retained = standalone.filter { current($0.key) }
        if retained != standalone { standalone = retained }
        automaticAttempts = automaticAttempts.filter { current($0) }
        for (id, job) in jobs {
            let invalidProbe = job.probes.contains { probe in
                switch probe {
                case let .runtime(_, key), let .standalone(key): return !current(key)
                }
            }
            if invalidProbe || job.roots.keys.contains(where: { !current($0) }) { cancel(id) }
        }
        for id in Set(previous.keys).union(catalogs.keys) where previous[id] != catalogs[id] {
            recommendations.removeValue(forKey: id)
            evaluationTokens.removeValue(forKey: id)
            evaluateGroupsIfIdle(profileID: id)
        }
    }

    private func supportsStandalone(_ line: Line) -> Bool {
        standaloneRequest != nil && ["direct", "trojan", "shadowsocks", "vmess", "anytls"].contains(line.type)
    }
    private func leaves(_ root: Line, profileID: String) -> [Line] {
        let catalog = catalogs[profileID] ?? (self.profileID == profileID ? lines : [:])
        var visited: Set<String> = []
        func visit(_ line: Line) -> [Line] {
            guard visited.insert(line.id).inserted else { return [] }
            if !line.isGroup { return [line] }
            return line.groupMembers.compactMap { catalog[$0] }.flatMap { visit($0) }
        }
        return visit(root)
    }
    func canTest(_ line: Line, profileID: String) -> Bool {
        if line.isGroup { return leaves(line, profileID: profileID).contains { canTest($0, profileID: profileID) } }
        return isAvailable(line, profileID: profileID) || supportsStandalone(line)
    }
    func isTesting(_ line: Line, profileID: String) -> Bool {
        if line.isGroup {
            let key = ProbeKey(line, profileID: profileID)
            return jobs.values.contains { !($0.roots[key] ?? []).isDisjoint(with: $0.probes) }
        }
        if isAvailable(line, profileID: profileID), testing.contains(line.id) { return true }
        switch standalone[ProbeKey(line, profileID: profileID)] {
        case .queued?, .running?: return true
        default: return false
        }
    }
    func measurement(_ line: Line, profileID: String) -> ProviderLineLatency? {
        measurement(line, profileID: profileID, visited: [])
    }
    private func measurement(_ line: Line, profileID: String, visited: Set<String>) -> ProviderLineLatency? {
        guard !visited.contains(line.id), visited.count < 32 else { return nil }
        let active = isAvailable(line, profileID: profileID) ? facts[line.id] : nil
        if active == nil, line.type == "urltest" { return recommendations[profileID]?[line.id] }
        if case let .measured(value) = standalone[ProbeKey(line, profileID: profileID)],
           (value.observedAt ?? 0) >= (active?.observedAt ?? 0) { return value }
        if active == nil, line.type == "selector" {
            let memberID = line.groupDefault.isEmpty ? line.groupMembers.first : line.groupDefault
            let catalog = catalogs[profileID] ?? (self.profileID == profileID ? lines : [:])
            if let memberID, let member = catalog[memberID] {
                return measurement(member, profileID: profileID, visited: visited.union([line.id]))
            }
        }
        return active
    }
    func failure(_ line: Line, profileID: String) -> String? {
        failure(line, profileID: profileID, visited: [])
    }
    private func failure(_ line: Line, profileID: String, visited: Set<String>) -> String? {
        guard !visited.contains(line.id), visited.count < 32 else { return nil }
        if case let .failed(reason, at) = standalone[ProbeKey(line, profileID: profileID)],
           at >= (measurement(line, profileID: profileID)?.observedAt ?? 0) { return reason }
        if isAvailable(line, profileID: profileID), failures.contains(line.id) { return "当前连接测速失败" }
        if !isAvailable(line, profileID: profileID), line.type == "selector" {
            let id = line.groupDefault.isEmpty ? line.groupMembers.first : line.groupDefault
            if let id, let member = catalogs[profileID]?[id] {
                return failure(member, profileID: profileID, visited: visited.union([line.id]))
            }
        }
        return nil
    }
    func isQueued(_ line: Line, profileID: String) -> Bool {
        standalone[ProbeKey(line, profileID: profileID)] == .queued
    }
    func cancelTests() {
        for id in Array(jobs.keys) { cancel(id) }
        evaluationTokens = [:]
    }
    private func enqueueStandalone(_ line: Line, profileID: String, testURL: String) -> ProbeKey? {
        let key = ProbeKey(line, profileID: profileID)
        guard supportsStandalone(line) else { return nil }
        if standaloneQueue.contains(key) { return nil }
        if case .queued? = standalone[key] { return nil }
        if case .running? = standalone[key] { return nil }
        standaloneQueue.append(key)
        standaloneTargets[key] = testURL
        return key
    }
    private func drainStandaloneQueue() {
        guard let probe = standaloneRequest else { return }
        while standaloneTasks.count < 3,
              let index = standaloneQueue.firstIndex(where: { standaloneTasks[$0] == nil }) {
            let key = standaloneQueue.remove(at: index)
            let target = standaloneTargets.removeValue(forKey: key) ?? ""
            let token = UUID()
            standalone[key] = .running
            let task = Task { [weak self] in
                let result: Result<ProviderLineLatency, Error>
                do { try Task.checkCancellation(); result = .success(try await probe(key.line, target)) }
                catch { result = .failure(error) }
                guard let self, self.standaloneTasks[key]?.0 == token else { return }
                self.standaloneTasks.removeValue(forKey: key)
                if !Task.isCancelled, self.standalone[key] != nil {
                    switch result {
                    case let .success(value):
                        if value.lineID == key.line.id, let ms = value.milliseconds, (0...65_535).contains(ms), value.observedAt != nil {
                            self.standalone[key] = .measured(value)
                        } else {
                            self.standalone[key] = .failed("测速未返回有效结果", Int64(Date().timeIntervalSince1970 * 1000))
                        }
                    case let .failure(error):
                        self.standalone[key] = .failed(error.localizedDescription, Int64(Date().timeIntervalSince1970 * 1000))
                    }
                }
                if !Task.isCancelled { self.finish(.standalone(key)) }
                self.drainStandaloneQueue()
                if !Task.isCancelled { self.evaluateGroupsIfIdle(profileID: key.profileID) }
            }
            standaloneTasks[key] = (token, task)
        }
    }

    private func evaluateGroupsIfIdle(profileID: String) {
        guard let evaluate = groupSelectionRequest, let catalog = catalogs[profileID],
              !standaloneQueue.contains(where: { $0.profileID == profileID }),
              !standaloneTasks.keys.contains(where: { $0.profileID == profileID }),
              !catalog.values.contains(where: { isAvailable($0, profileID: profileID) && testing.contains($0.id) }) else { return }
        let measured = catalog.values.filter { !$0.isGroup && failure($0, profileID: profileID) == nil }
            .compactMap { measurement($0, profileID: profileID) }
        guard !measured.isEmpty, catalog.values.contains(where: { $0.type == "urltest" }) else { return }
        let token = UUID()
        evaluationTokens[profileID] = token
        Task { [weak self] in
            let result = try? await evaluate(Array(catalog.values), measured)
            guard let self, self.evaluationTokens[profileID] == token,
                  self.catalogs[profileID] == catalog else { return }
            self.evaluationTokens.removeValue(forKey: profileID)
            guard let result else { return }
            var choices: [String: ProviderLineLatency] = [:]
            for fact in result where catalog[fact.lineID]?.type == "urltest" {
                // sing-box may fall back to its first member if every test fails;
                // that fallback must never be presented as a measured best choice.
                if let id = fact.selectedLineID, catalog[id] != nil, fact.milliseconds != nil, fact.observedAt != nil {
                    choices[fact.lineID] = fact
                }
            }
            if self.recommendations[profileID] != choices { self.recommendations[profileID] = choices }
        }
    }

    func bind(transactionID: String?, profileID: String? = nil, lines: [Line] = []) {
        guard self.transactionID != transactionID || self.profileID != profileID else { return }
        worker?.cancel(); worker = nil; workerID = nil; queue = []; queueGroups = [:]; snapshotInFlight = false
        for probe in Set(jobs.values.flatMap { $0.probes }) {
            if case .runtime = probe { finish(probe) }
        }
        runtimeTokens = [:]
        self.transactionID = transactionID; self.profileID = profileID
        automaticAttempts = []
        self.lines = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        facts = [:]; testing = []; failures = []; failedAt = [:]
        refresh()
    }

    func isAvailable(_ line: Line, profileID: String) -> Bool {
        isAvailable(line, profileID: profileID, visited: [])
    }
    private func isAvailable(_ line: Line, profileID: String, visited: Set<String>) -> Bool {
        guard !visited.contains(line.id) else { return false }
        guard self.profileID == profileID, transactionID != nil, var active = lines[line.id] else { return false }
        var candidate = line
        // Renaming and verification do not change the connection being measured.
        active.name = ""; candidate.name = ""
        active.verified = false; candidate.verified = false
        guard active == candidate else { return false }
        if line.isGroup {
            let catalog = catalogs[profileID] ?? lines
            return line.groupMembers.allSatisfy { id in
                guard let child = catalog[id] else { return false }
                return isAvailable(child, profileID: profileID, visited: visited.union([line.id]))
            }
        }
        return true
    }

    func refresh() {
        guard let tx = transactionID, let request, !snapshotInFlight else { return }
        snapshotInFlight = true
        request(tx, nil, nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.transactionID == tx else { return }
                self.snapshotInFlight = false
                if case let .success(values) = result { self.accept(values) }
            }
        }
    }

    func accept(_ values: [ProviderLineLatency]) {
        var next = facts
        var remainingFailures = failures
        for value in values where lines[value.lineID] != nil {
            guard value.milliseconds.map({ (0...65_535).contains($0) }) ?? true else { continue }
            if lines[value.lineID]?.isGroup != true,
               let observed = value.observedAt, let previous = next[value.lineID]?.observedAt,
               observed < previous { continue }
            next[value.lineID] = value
            if let observed = value.observedAt, observed > (failedAt[value.lineID] ?? Int64.max) {
                remainingFailures.remove(value.lineID)
            }
        }
        // One publication per snapshot, not one redraw of every row per result.
        if next != facts { facts = next }
        if remainingFailures != failures { failures = remainingFailures }
    }
    private var failedAt: [String: Int64] = [:]

    /// A batch deduplicates concrete members. It reuses committed capabilities
    /// where available and explicitly probes ordinary proxies otherwise.
    /// Native urltest groups reconsider history; manually pinned groups and the
    /// Profile itself are never changed by a measurement.
    @discardableResult
    func test(_ requested: [Line], profileID: String, group: Line? = nil, scope: TestScope = .allMembers, onlyMissing: Bool = false, control: TestControl? = nil) -> UUID? {
        if let control, let running = activeJob(for: control, profileID: profileID) { return running.id }
        let jobID = UUID()
        var probes: Set<PendingProbe> = []
        var roots: [ProbeKey: Set<PendingProbe>] = [:]
        var root: ProbeKey?
        func own(_ probe: PendingProbe) {
            probes.insert(probe)
            if let root { roots[root, default: []].insert(probe) }
        }
        var visited: Set<String> = []
        var pending = testing
        var queuedStandalone = standalone
        var remainingFailures = failures
        func append(_ item: Line, context: Line?) {
            guard visited.insert(item.id).inserted else { return }
            if onlyMissing && !item.enabled { return }
            if item.isGroup {
                if scope == .currentExit {
                    if let exit = currentExit(item, profileID: profileID) { append(exit, context: item) }
                    return
                }
                if onlyMissing && item.type == "urltest" && isAvailable(item, profileID: profileID) { return }
                let catalog = catalogs[profileID] ?? (self.profileID == profileID ? lines : [:])
                // Automatic warming of a fixed group measures its chosen exit,
                // not the whole airport subscription behind the selector.
                let ids = onlyMissing && item.type == "selector"
                    ? [item.groupDefault.isEmpty ? item.groupMembers.first ?? "" : item.groupDefault]
                    : item.groupMembers
                for id in ids { if let child = catalog[id] { append(child, context: item) } }
                return
            }
            if onlyMissing {
                let measured = isAvailable(item, profileID: profileID)
                    ? facts[item.id]?.milliseconds != nil : measurement(item, profileID: profileID)?.milliseconds != nil
                let key = ProbeKey(item, profileID: profileID)
                guard !measured, failure(item, profileID: profileID) == nil,
                      canTest(item, profileID: profileID), !isTesting(item, profileID: profileID),
                      automaticAttempts.insert(key).inserted else { return }
            }
            if !isAvailable(item, profileID: profileID) ||
                        (context.map { $0.type == "urltest" && !isAvailable($0, profileID: profileID) } ?? false) {
                guard supportsStandalone(item) else { return }
                let key = ProbeKey(item, profileID: profileID)
                if let queued = enqueueStandalone(item, profileID: profileID, testURL: context?.type == "urltest" ? context?.groupURL ?? "" : "") { queuedStandalone[queued] = .queued }
                own(.standalone(key))
                automaticAttempts.insert(key)
            } else if let tx = transactionID {
                if !pending.contains(item.id) {
                    queue.append(item.id); pending.insert(item.id); remainingFailures.remove(item.id)
                    runtimeTokens[item.id] = UUID()
                    if let context, context.type == "urltest", isAvailable(context, profileID: profileID) { queueGroups[item.id] = context.id }
                }
                let key = ProbeKey(item, profileID: profileID)
                own(.runtime(tx, key))
                automaticAttempts.insert(key)
            }
        }
        for line in requested {
            visited = []
            root = ProbeKey(line, profileID: profileID)
            append(line, context: group)
        }
        guard !probes.isEmpty else { return nil }
        jobs[jobID] = Job(probes: probes, roots: roots,
                          owner: control.map { TestOwner(profileID: profileID, control: $0) }, count: probes.count)
        evaluationTokens.removeValue(forKey: profileID)
        if queuedStandalone != standalone { standalone = queuedStandalone }
        drainStandaloneQueue()
        if pending != testing { testing = pending }
        if remainingFailures != failures { failures = remainingFailures }
        guard worker == nil, !queue.isEmpty else { return jobID }
        let workerToken = UUID()
        workerID = workerToken
        worker = Task { [weak self] in
            guard let self, self.workerID == workerToken, let tx = transactionID else { return }
            while !Task.isCancelled, self.transactionID == tx, !queue.isEmpty {
                let id = queue.removeFirst()
                let groupID = queueGroups.removeValue(forKey: id)
                let probeToken = runtimeTokens[id]
                var result: Result<[ProviderLineLatency], Error>?
                // Address observations use the same Provider probe lease. Wait only for busy.
                for attempt in 0..<6 {
                    guard !Task.isCancelled, self.transactionID == tx else { return }
                    guard self.runtimeTokens[id] == probeToken, let request else { break }
                    result = await withCheckedContinuation { continuation in
                        request(tx, id, groupID) { continuation.resume(returning: $0) }
                    }
                    guard case let .failure(error) = result,
                          error.localizedDescription.contains("probe-busy"), attempt < 5 else { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                guard !Task.isCancelled, self.transactionID == tx else { return }
                guard runtimeTokens[id] == probeToken else { continue }
                runtimeTokens.removeValue(forKey: id)
                testing.remove(id)
                if let line = lines[id] { finish(.runtime(tx, ProbeKey(line, profileID: profileID))) }
                if case let .success(values) = result {
                    failures.remove(id); failedAt.removeValue(forKey: id); accept(values)
                } else {
                    failures.insert(id); failedAt[id] = Int64(Date().timeIntervalSince1970 * 1000)
                }
            }
            guard self.transactionID == tx, self.workerID == workerToken else { return }
            worker = nil; workerID = nil; refresh()
            evaluateGroupsIfIdle(profileID: profileID)
        }
        return jobID
    }
}
