import Darwin
import Foundation

enum LineAddressQueryPhase: String, Codable, Equatable {
    case querying
    case waiting
    case available
    case failed
}

struct LineAddressObservation: Codable, Equatable {
    let observedAt: Date
    let address: String
    let errorCode: String
    let phase: LineAddressQueryPhase

    init(
        observedAt: Date,
        address: String,
        errorCode: String,
        phase: LineAddressQueryPhase = .available
    ) {
        self.observedAt = observedAt
        self.address = address
        self.errorCode = errorCode
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case address
        case errorCode
        case phase
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        address = try values.decode(String.self, forKey: .address)
        errorCode = try values.decode(String.self, forKey: .errorCode)
        phase = try values.decodeIfPresent(
            LineAddressQueryPhase.self,
            forKey: .phase
        ) ?? .available
    }
}

/// 易失、逐地址族的出口观察；不能跨事务复用或参与连接裁决。
struct LineNetInfo: Codable, Equatable {
    let transactionID: String
    let lineID: String
    var ipv4: LineAddressObservation?
    var ipv6: LineAddressObservation?

    func observation(for family: LineAddressFamily) -> LineAddressObservation? {
        family == .ipv4 ? ipv4 : ipv6
    }

    // Debug snapshot 的默认地址与界面一致，始终是 IPv4。
    var ip: String { ipv4?.address ?? "" }
    var region: String { "" }
    var errorCode: String { ipv4?.errorCode ?? "" }
    var summary: String { ip }
    var observedAt: Date {
        max(ipv4?.observedAt ?? .distantPast, ipv6?.observedAt ?? .distantPast)
    }
}

struct LineAddressRequest: Hashable {
    let lineID: String
    let family: LineAddressFamily
}

@MainActor
final class NetworkInfo: ObservableObject {
    static let shared = NetworkInfo()

    @Published private(set) var transactionID: String?
    @Published private(set) var perLine: [String: LineNetInfo] = [:]

    private var activeRequests = Set<LineAddressRequest>()
    private var inFlight = Set<LineAddressRequest>()
    private var failureCounts: [LineAddressRequest: Int] = [:]
    private var retryDates: [LineAddressRequest: Date] = [:]

    /// 只调度当前报告中的 Line；先查所有 IPv4，再查可用的 IPv6。
    /// 成功结果保留到事务结束；首次失败后按 2/5/10 秒自动重试，
    /// 第四次失败后等待用户显式重试。
    func begin(
        transactionID: String,
        lineIDs: [String],
        capabilities: [String: LineAddressFamilyCapability] = [:],
        now: Date = Date()
    ) -> [LineAddressRequest] {
        if self.transactionID != transactionID {
            clearStorage()
            self.transactionID = transactionID
        }
        let requests = LineAddressFamily.allCases.flatMap { family in
            lineIDs.compactMap { lineID -> LineAddressRequest? in
                let capability = capabilities[lineID]
                // 旧报告没有能力事实时保留 IPv4 查询，不推断 IPv6 可用。
                let available = family == .ipv4
                    ? capability?.ipv4Available ?? true
                    : capability?.ipv6Available ?? false
                return available ? LineAddressRequest(lineID: lineID, family: family) : nil
            }
        }
        activeRequests = Set(requests)
        perLine = perLine.filter { lineIDs.contains($0.key) }
        inFlight.formIntersection(activeRequests)
        failureCounts = failureCounts.filter { activeRequests.contains($0.key) }
        retryDates = retryDates.filter { activeRequests.contains($0.key) }
        var pending: [LineAddressRequest] = []
        for request in requests where !inFlight.contains(request) {
            let observation = perLine[request.lineID]?.observation(
                for: request.family
            )
            let maySchedule: Bool
            switch observation?.phase {
            case nil, .querying:
                maySchedule = (retryDates[request] ?? .distantPast) <= now
            case .waiting:
                maySchedule = retryDates[request].map { $0 <= now } ?? false
            case .available, .failed:
                maySchedule = false
            }
            guard maySchedule else { continue }
            pending.append(request)
            inFlight.insert(request)
            retryDates.removeValue(forKey: request)
            store(
                LineAddressObservation(
                    observedAt: now,
                    address: observation?.address ?? "",
                    errorCode: "",
                    phase: .querying
                ),
                request: request,
                transactionID: transactionID
            )
        }
        return pending
    }

    var nextRetryDate: Date? { retryDates.values.min() }

    func clear() {
        guard transactionID != nil else { return }
        clearStorage()
        transactionID = nil
    }

    func observation(for lineID: String, transactionID: String?) -> LineNetInfo? {
        guard let transactionID, self.transactionID == transactionID,
              let info = perLine[lineID], info.transactionID == transactionID else {
            return nil
        }
        return info
    }

    func recordAddress(
        _ address: String,
        lineID: String,
        transactionID: String,
        family: LineAddressFamily = .ipv4,
        observedAt: Date = Date()
    ) {
        guard Self.address(address, matches: family) else {
            recordFailure(code: "invalid-outbound-address", lineID: lineID,
                          transactionID: transactionID, family: family, observedAt: observedAt)
            return
        }
        let request = LineAddressRequest(lineID: lineID, family: family)
        guard accepts(request, transactionID: transactionID) else { return }
        inFlight.remove(request)
        failureCounts.removeValue(forKey: request)
        retryDates.removeValue(forKey: request)
        store(LineAddressObservation(
            observedAt: observedAt,
            address: address,
            errorCode: "",
            phase: .available
        ),
              request: request, transactionID: transactionID)
    }

    func recordFailure(
        code: String,
        lineID: String,
        transactionID: String,
        family: LineAddressFamily = .ipv4,
        observedAt: Date = Date()
    ) {
        let request = LineAddressRequest(lineID: lineID, family: family)
        guard accepts(request, transactionID: transactionID) else { return }
        inFlight.remove(request)
        let failureCount = (failureCounts[request] ?? 0) + 1
        failureCounts[request] = failureCount
        let phase: LineAddressQueryPhase
        if failureCount >= 4 {
            retryDates.removeValue(forKey: request)
            phase = .failed
        } else {
            let delays: [TimeInterval] = [2, 5, 10]
            retryDates[request] = observedAt.addingTimeInterval(
                delays[failureCount - 1]
            )
            phase = .waiting
        }
        let previousAddress = perLine[request.lineID]?
            .observation(for: request.family)?.address ?? ""
        store(LineAddressObservation(
            observedAt: observedAt,
            address: previousAddress,
            errorCode: code.isEmpty ? "line-outbound-probe-failed" : code,
            phase: phase
        ),
              request: request, transactionID: transactionID)
    }

    @discardableResult
    func retry(
        lineID: String,
        transactionID: String,
        family: LineAddressFamily,
        now: Date = Date()
    ) -> Bool {
        let request = LineAddressRequest(lineID: lineID, family: family)
        guard
            self.transactionID == transactionID,
            activeRequests.contains(request),
            !inFlight.contains(request),
            let observation = perLine[lineID]?.observation(for: family),
            observation.phase == .failed
        else {
            return false
        }
        failureCounts[request] = 0
        retryDates[request] = now
        store(
            LineAddressObservation(
                observedAt: now,
                address: observation.address,
                errorCode: "",
                phase: .querying
            ),
            request: request,
            transactionID: transactionID
        )
        return true
    }

    private func accepts(_ request: LineAddressRequest, transactionID: String) -> Bool {
        self.transactionID == transactionID
            && activeRequests.contains(request) && inFlight.contains(request)
    }

    private func store(
        _ observation: LineAddressObservation,
        request: LineAddressRequest,
        transactionID: String
    ) {
        var info = perLine[request.lineID] ?? LineNetInfo(
            transactionID: transactionID, lineID: request.lineID
        )
        if request.family == .ipv4 { info.ipv4 = observation }
        else { info.ipv6 = observation }
        perLine[request.lineID] = info
    }

    private func clearStorage() {
        activeRequests.removeAll()
        inFlight.removeAll()
        failureCounts.removeAll()
        retryDates.removeAll()
        perLine.removeAll()
    }

    nonisolated private static func address(_ value: String, matches family: LineAddressFamily) -> Bool {
        if family == .ipv4 {
            var address = in_addr()
            return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}
