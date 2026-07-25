import Foundation
import Network
@preconcurrency import Libbox

private final class TailscaleSetupSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class TailscaleSetupInterfaceState: @unchecked Sendable {
    enum WaitResult {
        case available
        case timedOut
        case cancelled
    }

    private let condition = NSCondition()
    private var available = false
    private var cancelled = false

    func update(available: Bool, apply: () -> Void) {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        apply()
        self.available = available
        if available {
            condition.broadcast()
        }
        condition.unlock()
    }

    func waitUntilAvailable(deadline: Date) -> WaitResult {
        condition.lock()
        defer { condition.unlock() }
        while !available, !cancelled {
            guard condition.wait(until: deadline) else {
                return .timedOut
            }
        }
        return cancelled ? .cancelled : .available
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
final class LocalTailscaleSetupRuntime: TailscaleSetupRuntime {
    private static let appGroupID = "group.com.kafeifei.xdial.ios"
    private static let workQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tailscale-setup",
        qos: .userInitiated
    )
    private static let pathQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tailscale-setup.path",
        qos: .userInitiated
    )
    private static let watchdogQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tailscale-setup.watchdog",
        qos: .utility
    )
    private static let interfaceWaitTimeout: TimeInterval = 5
    private static let operationWatchdogTimeout: TimeInterval = 15

    private final class EngineCallback: NSObject, LibboxCallbackProtocol {
        func onStatusChanged(_ statusJSON: String?) {}

        func onError(_ code: Int, message: String?) {
            appLog("Tailscale setup error \(code): \(message ?? "")")
        }
    }

    private final class Session: @unchecked Sendable {
        let generation: UInt64
        let lineID: String
        let engine: LibboxLibbox
        let callback: EngineCallback
        let interfaceState: TailscaleSetupInterfaceState
        let pathMonitor: NWPathMonitor
        var startCompletion: ((Result<TailscaleRuntimeStatus, Error>) -> Void)?
        var startError: Error?
        var stopCompletions: [() -> Void] = []
        var startWatchdog: DispatchSourceTimer?
        var stopWatchdog: DispatchSourceTimer?
        var stopInFlight = false
        var engineStopped = false
        var nextOperationID: UInt64 = 0
        var operationCancellations: [UInt64: () -> Void] = [:]

        init(
            generation: UInt64,
            lineID: String,
            engine: LibboxLibbox,
            callback: EngineCallback,
            interfaceState: TailscaleSetupInterfaceState,
            pathMonitor: NWPathMonitor,
            startCompletion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
        ) {
            self.generation = generation
            self.lineID = lineID
            self.engine = engine
            self.callback = callback
            self.interfaceState = interfaceState
            self.pathMonitor = pathMonitor
            self.startCompletion = startCompletion
        }
    }

    private enum Phase {
        case idle
        case starting(Session)
        case running(Session)
        case stopping(Session)
    }

    private var phase = Phase.idle
    private var generation: UInt64 = 0

    var isActive: Bool {
        if case .idle = phase {
            return false
        }
        return true
    }

    func start(
        profileJSON: String,
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard case .idle = phase,
              let basePath = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: Self.appGroupID
              )?.path else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }

        var generationError: NSError?
        let configJSON = LibboxGenerateTailscaleSetupConfig(
            profileJSON,
            lineID,
            basePath,
            &generationError
        )
        if let generationError {
            completion(.failure(generationError))
            return
        }

        let callback = EngineCallback()
        guard let engine = LibboxNew(callback) else {
            completion(.failure(runtimeError(
                code: -50,
                message: "Tailscale setup runtime could not be created."
            )))
            return
        }

        generation &+= 1
        let monitor = NWPathMonitor()
        let interfaceState = TailscaleSetupInterfaceState()
        let session = Session(
            generation: generation,
            lineID: lineID,
            engine: engine,
            callback: callback,
            interfaceState: interfaceState,
            pathMonitor: monitor,
            startCompletion: completion
        )
        phase = .starting(session)
        session.startWatchdog = makeWatchdog(
            message: "Tailscale setup start is still blocked for line \(lineID); runtime remains active."
        )

        let engineBox = TailscaleSetupSendableBox(engine)
        monitor.pathUpdateHandler = { path in
            let interface = Self.selectPhysicalInterface(from: path)
            if path.status == .satisfied, let interface {
                interfaceState.update(available: true) {
                    engineBox.value.setDefaultInterface(interface.name, index: interface.index)
                }
            } else {
                interfaceState.update(available: false) {
                    engineBox.value.setDefaultInterface("", index: -1)
                }
            }
        }
        monitor.start(queue: Self.pathQueue)

        let configBox = TailscaleSetupSendableBox(configJSON)
        let endpointTag = AppState.tailscaleEndpointTag(lineID: lineID)
        let interfaceDeadline = Date().addingTimeInterval(Self.interfaceWaitTimeout)
        Self.workQueue.async { [weak self] in
            switch interfaceState.waitUntilAvailable(deadline: interfaceDeadline) {
            case .cancelled:
                return
            case .timedOut:
                Task { @MainActor in
                    self?.handleStartFailure(
                        session: session,
                        error: self?.runtimeError(
                            code: -51,
                            message: "No physical network interface is available."
                        ) ?? TunnelRuntimeError.unavailable
                    )
                }
                return
            case .available:
                break
            }

            do {
                try engineBox.value.startStandalone(configBox.value)
                let status = try Self.readStatus(
                    engine: engineBox.value,
                    endpointTag: endpointTag
                )
                Task { @MainActor in
                    self?.handleStartSuccess(session: session, status: status)
                }
            } catch {
                let errorBox = TailscaleSetupSendableBox(error)
                Task { @MainActor in
                    self?.handleStartFailure(
                        session: session,
                        error: errorBox.value
                    )
                }
            }
        }
    }

    func status(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        let endpointTag = AppState.tailscaleEndpointTag(lineID: lineID)
        perform(lineID: lineID, completion: completion) { engine in
            try Self.readStatus(engine: engine, endpointTag: endpointTag)
        }
    }

    func beginLogin(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        let endpointTag = AppState.tailscaleEndpointTag(lineID: lineID)
        perform(lineID: lineID, completion: completion) { engine in
            var error: NSError?
            let raw = engine.beginTailscaleLogin(
                endpointTag,
                error: &error
            )
            if let error {
                throw error
            }
            return try Self.decodeStatus(raw)
        }
    }

    func logout(
        lineID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard case .running(let session) = phase,
              session.lineID == lineID else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        let engineBox = TailscaleSetupSendableBox(session.engine)
        let completionBox = TailscaleSetupSendableBox(completion)
        let endpointTag = AppState.tailscaleEndpointTag(lineID: lineID)
        let operationGeneration = session.generation
        let operationWatchdog = makeWatchdog(
            message: "Tailscale setup logout is still blocked for line \(lineID)."
        )
        let operationID = registerOperation(session) {
            Self.cancelWatchdog(operationWatchdog)
            completionBox.value(.failure(TunnelRuntimeError.unavailable))
        }
        Self.workQueue.async { [weak self] in
            let result: Result<Void, Error>
            do {
                try engineBox.value.tailscaleLogout(endpointTag)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            let resultBox = TailscaleSetupSendableBox(result)
            Task { @MainActor in
                guard let self,
                      self.isCurrentRunning(
                          session: session,
                          generation: operationGeneration
                      ),
                      self.finishOperation(session, operationID: operationID) else {
                    return
                }
                Self.cancelWatchdog(operationWatchdog)
                completionBox.value(resultBox.value)
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        switch phase {
        case .idle:
            completion()
        case .stopping(let session):
            session.stopCompletions.append(completion)
            if !session.stopInFlight, !session.engineStopped {
                scheduleEngineStop(session)
            }
        case .starting(let session):
            session.stopCompletions.append(completion)
            beginStopping(
                session: session,
                startError: runtimeError(
                    code: -52,
                    message: "Tailscale setup start was interrupted."
                )
            )
        case .running(let session):
            session.stopCompletions.append(completion)
            beginStopping(session: session, startError: nil)
        }
    }

    private func perform(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void,
        operation: @escaping @Sendable (LibboxLibbox) throws -> TailscaleRuntimeStatus
    ) {
        guard case .running(let session) = phase,
              session.lineID == lineID else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        let engineBox = TailscaleSetupSendableBox(session.engine)
        let completionBox = TailscaleSetupSendableBox(completion)
        let operationGeneration = session.generation
        let operationWatchdog = makeWatchdog(
            message: "Tailscale setup operation is still blocked for line \(lineID)."
        )
        let operationID = registerOperation(session) {
            Self.cancelWatchdog(operationWatchdog)
            completionBox.value(.failure(TunnelRuntimeError.unavailable))
        }
        Self.workQueue.async { [weak self] in
            let result: Result<TailscaleRuntimeStatus, Error>
            do {
                result = .success(try operation(engineBox.value))
            } catch {
                result = .failure(error)
            }
            let resultBox = TailscaleSetupSendableBox(result)
            Task { @MainActor in
                guard let self,
                      self.isCurrentRunning(
                          session: session,
                          generation: operationGeneration
                      ),
                      self.finishOperation(session, operationID: operationID) else {
                    return
                }
                Self.cancelWatchdog(operationWatchdog)
                completionBox.value(resultBox.value)
            }
        }
    }

    private func handleStartSuccess(
        session: Session,
        status: TailscaleRuntimeStatus
    ) {
        guard generation == session.generation,
              case .starting(let currentSession) = phase,
              currentSession === session else {
            return
        }
        cancelWatchdog(&session.startWatchdog)
        phase = .running(session)
        completeStart(session, result: .success(status))
    }

    private func handleStartFailure(session: Session, error: Error) {
        guard generation == session.generation,
              case .starting(let currentSession) = phase,
              currentSession === session else {
            return
        }
        beginStopping(session: session, startError: error)
    }

    private func beginStopping(session: Session, startError: Error?) {
        switch phase {
        case .starting(let currentSession) where currentSession === session,
             .running(let currentSession) where currentSession === session:
            break
        default:
            return
        }

        if session.startCompletion != nil, session.startError == nil {
            session.startError = startError ?? runtimeError(
                code: -52,
                message: "Tailscale setup start was interrupted."
            )
        }
        phase = .stopping(session)
        session.interfaceState.cancel()
        session.pathMonitor.cancel()
        cancelWatchdog(&session.startWatchdog)
        session.stopWatchdog = makeWatchdog(
            message: "Tailscale setup stop is still blocked for line \(session.lineID); resources remain held."
        )
        scheduleEngineStop(session)
        let operationCancellations = Array(session.operationCancellations.values)
        session.operationCancellations.removeAll()
        for cancelOperation in operationCancellations {
            cancelOperation()
        }
    }

    private func scheduleEngineStop(_ session: Session) {
        guard case .stopping(let currentSession) = phase,
              currentSession === session,
              !session.engineStopped,
              !session.stopInFlight else {
            return
        }
        session.stopInFlight = true
        let engineBox = TailscaleSetupSendableBox(session.engine)
        Self.workQueue.async { [weak self] in
            do {
                try engineBox.value.stop()
                Task { @MainActor in
                    self?.finishStop(session)
                }
            } catch {
                let errorBox = TailscaleSetupSendableBox(error)
                Task { @MainActor in
                    self?.handleStopFailure(session, error: errorBox.value)
                }
            }
        }
    }

    private func finishStop(_ session: Session) {
        guard generation == session.generation,
              case .stopping(let currentSession) = phase,
              currentSession === session else {
            return
        }
        session.stopInFlight = false
        session.engineStopped = true
        cancelWatchdog(&session.stopWatchdog)

        if let startError = session.startError {
            completeStart(session, result: .failure(startError))
        }
        while !session.stopCompletions.isEmpty {
            let completion = session.stopCompletions.removeFirst()
            completion()
        }
        phase = .idle
    }

    private func handleStopFailure(_ session: Session, error: Error) {
        guard generation == session.generation,
              case .stopping(let currentSession) = phase,
              currentSession === session else {
            return
        }
        session.stopInFlight = false
        appLog(
            "Tailscale setup stop failed for line \(session.lineID): \(error.localizedDescription)"
        )
    }

    private func completeStart(
        _ session: Session,
        result: Result<TailscaleRuntimeStatus, Error>
    ) {
        guard let completion = session.startCompletion else { return }
        session.startCompletion = nil
        completion(result)
    }

    private func isCurrentRunning(session: Session, generation: UInt64) -> Bool {
        guard self.generation == generation,
              session.generation == generation,
              case .running(let currentSession) = phase else {
            return false
        }
        return currentSession === session
    }

    private func registerOperation(
        _ session: Session,
        cancellation: @escaping () -> Void
    ) -> UInt64 {
        session.nextOperationID &+= 1
        let operationID = session.nextOperationID
        session.operationCancellations[operationID] = cancellation
        return operationID
    }

    private func finishOperation(_ session: Session, operationID: UInt64) -> Bool {
        session.operationCancellations.removeValue(forKey: operationID) != nil
    }

    private func makeWatchdog(message: String) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: Self.watchdogQueue)
        timer.schedule(deadline: .now() + Self.operationWatchdogTimeout)
        timer.setEventHandler {
            appLog(message)
        }
        timer.resume()
        return timer
    }

    private func cancelWatchdog(_ timer: inout DispatchSourceTimer?) {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    nonisolated private static func cancelWatchdog(_ timer: DispatchSourceTimer) {
        timer.setEventHandler {}
        timer.cancel()
    }

    nonisolated private static func readStatus(
        engine: LibboxLibbox,
        endpointTag: String
    ) throws -> TailscaleRuntimeStatus {
        var error: NSError?
        let raw = engine.tailscaleStatus(
            endpointTag,
            error: &error
        )
        if let error {
            throw error
        }
        return try decodeStatus(raw)
    }

    nonisolated private static func decodeStatus(_ raw: String) throws -> TailscaleRuntimeStatus {
        guard let data = raw.data(using: .utf8) else {
            throw TunnelRuntimeError.invalidTailscaleStatus
        }
        do {
            return try JSONDecoder().decode(TailscaleRuntimeStatus.self, from: data)
        } catch {
            throw TunnelRuntimeError.invalidTailscaleStatus
        }
    }

    nonisolated private static func selectPhysicalInterface(from path: NWPath) -> NWInterface? {
        let preferredTypes: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        for type in preferredTypes where path.usesInterfaceType(type) {
            if let interface = path.availableInterfaces.first(where: {
                $0.type == type && !isTunnelInterface($0.name)
            }) {
                return interface
            }
        }
        return path.availableInterfaces.first(where: { !isTunnelInterface($0.name) })
    }

    nonisolated private static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    private func runtimeError(code: Int, message: String) -> NSError {
        NSError(
            domain: "XDial.TailscaleSetup",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
