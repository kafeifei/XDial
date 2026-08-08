import Darwin
import Foundation

/// 一次 Provider 出口探测的易失观察。
///
/// 它只装饰 `ConnectionReport` 已经给出的运行状态，不参与连接裁决，也不能跨事务复用。
struct LineNetInfo: Codable, Equatable {
    let transactionID: String
    let lineID: String
    let observedAt: Date
    var ip: String
    var region: String
    var errorCode: String

    var summary: String {
        guard !ip.isEmpty else { return "" }
        let suffix = region.isEmpty ? "" : " (\(region))"
        return "\(ip)\(suffix)"
    }

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case lineID = "line_id"
        case observedAt = "observed_at"
        case ip
        case region
        case errorCode = "error_code"
    }
}

@MainActor
final class NetworkInfo: ObservableObject {
    static let shared = NetworkInfo()

    @Published private(set) var transactionID: String?
    @Published private(set) var perLine: [String: LineNetInfo] = [:]

    private var activeLineIDs = Set<String>()
    private var requestedLineIDs = Set<String>()

    /// 对齐当前已提交事务，并返回本次尚未向 Provider 请求过的 Line。
    ///
    /// 调用方只能传入 `ConnectionReport` 中的 Line task，不能从当前编辑中的 Profile
    /// 猜测运行对象。
    func begin(
        transactionID: String,
        lineIDs: [String]
    ) -> [String] {
        let active = Set(lineIDs)
        if self.transactionID != transactionID {
            clearStorage()
            self.transactionID = transactionID
        }
        activeLineIDs = active
        perLine = perLine.filter { active.contains($0.key) }
        requestedLineIDs.formIntersection(active)

        let pending = lineIDs.filter {
            !requestedLineIDs.contains($0) && perLine[$0] == nil
        }
        requestedLineIDs.formUnion(pending)
        return pending
    }

    func clear() {
        guard transactionID != nil || !perLine.isEmpty
                || !requestedLineIDs.isEmpty else {
            return
        }
        clearStorage()
        transactionID = nil
    }

    func observation(
        for lineID: String,
        transactionID: String?
    ) -> LineNetInfo? {
        guard
            let transactionID,
            self.transactionID == transactionID,
            let info = perLine[lineID],
            info.transactionID == transactionID
        else {
            return nil
        }
        return info
    }

    func recordAddress(
        _ address: String,
        lineID: String,
        transactionID: String,
        observedAt: Date = Date()
    ) {
        guard accepts(lineID: lineID, transactionID: transactionID) else {
            return
        }
        guard Self.numericAddress(address) != nil else {
            recordFailure(
                code: "invalid-outbound-address",
                lineID: lineID,
                transactionID: transactionID,
                observedAt: observedAt
            )
            return
        }
        perLine[lineID] = LineNetInfo(
            transactionID: transactionID,
            lineID: lineID,
            observedAt: observedAt,
            ip: address,
            region: "",
            errorCode: ""
        )
    }

    func recordFailure(
        code: String,
        lineID: String,
        transactionID: String,
        observedAt: Date = Date()
    ) {
        guard accepts(lineID: lineID, transactionID: transactionID) else {
            return
        }
        perLine[lineID] = LineNetInfo(
            transactionID: transactionID,
            lineID: lineID,
            observedAt: observedAt,
            ip: "",
            region: "",
            errorCode: code.isEmpty
                ? "line-outbound-probe-failed"
                : code
        )
    }

    private func accepts(
        lineID: String,
        transactionID: String
    ) -> Bool {
        self.transactionID == transactionID
            && activeLineIDs.contains(lineID)
            && requestedLineIDs.contains(lineID)
    }

    private func clearStorage() {
        activeLineIDs.removeAll()
        requestedLineIDs.removeAll()
        perLine.removeAll()
    }

    nonisolated private static func numericAddress(
        _ value: String
    ) -> (family: Int32, bytes: Data)? {
        var ipv4 = in_addr()
        if value.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return (
                AF_INET,
                withUnsafeBytes(of: ipv4) { Data($0) }
            )
        }
        var ipv6 = in6_addr()
        if value.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1 {
            return (
                AF_INET6,
                withUnsafeBytes(of: ipv6) { Data($0) }
            )
        }
        return nil
    }
}
