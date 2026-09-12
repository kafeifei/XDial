import CoreLocation
import CoreWLAN
import Foundation

/// SSID 只是宿主控制面的场景触发事实。它不进入 ConnectionPlan，
/// 不参与 DNS、路由或 Underlay 接口选择。
final class WiFiSSIDMonitor: NSObject, CLLocationManagerDelegate,
    CWEventDelegate
{
    typealias UpdateHandler = (String?, WiFiSSIDAccessState, UInt64) -> Void
    typealias SettlingHandler = () -> Void

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let onSettling: SettlingHandler
    private let onUpdate: UpdateHandler
    private var monitoring = false
    private var refreshWorkItem: DispatchWorkItem?
    private var lastSSID: String?
    private var lastAccessState: WiFiSSIDAccessState?
    private var accessLifecycle = WiFiSSIDAccessLifecycle()

    init(
        onSettling: @escaping SettlingHandler,
        onUpdate: @escaping UpdateHandler
    ) {
        self.onSettling = onSettling
        self.onUpdate = onUpdate
        super.init()
        locationManager.delegate = self
    }

    /// Publish checking until Core Location delivers its initial authorization
    /// callback. Prompting belongs only to a visible, foreground user action.
    func start() {
        switch accessLifecycle.accessState(
            for: locationManager.authorizationStatus
        ) {
        case .checking:
            emit(ssid: nil, accessState: .checking)
        case .ready:
            guard startMonitoringIfNeeded() else {
                emit(ssid: nil, accessState: .unavailable)
                return
            }
            scheduleRefresh(delay: 0)
        case .permissionRequired:
            emit(ssid: nil, accessState: .permissionRequired)
        case .denied:
            emit(ssid: nil, accessState: .denied)
        case .unavailable:
            emit(ssid: nil, accessState: .unavailable)
        }
    }

    func stop() {
        accessLifecycle.invalidatePendingUpdates()
        lastAccessState = nil
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        guard monitoring else { return }
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        try? client.stopMonitoringEvent(with: .powerDidChange)
        client.delegate = nil
        monitoring = false
    }

    @discardableResult
    func requestAuthorizationAndRefresh()
        -> WiFiSSIDAccessRequestDisposition
    {
        guard accessLifecycle.hasReceivedAuthorization else { return .checking }
        let disposition = WiFiSSIDAccessPolicy.requestDisposition(
            for: locationManager.authorizationStatus
        )
        switch disposition {
        case .checking:
            return .checking
        case .refreshed:
            guard startMonitoringIfNeeded() else {
                emit(ssid: nil, accessState: .unavailable)
                return .unavailable
            }
            scheduleRefresh(delay: 0)
        case .authorizationRequested:
            emit(ssid: nil, accessState: .permissionRequired)
            locationManager.requestWhenInUseAuthorization()
        case .openSystemSettings:
            emit(ssid: nil, accessState: .denied)
        case .unavailable:
            emit(ssid: nil, accessState: .unavailable)
        }
        return disposition
    }

    /// Synchronously sample the SSID at a network-epoch settle point. Updating
    /// the dedupe baseline here ensures a delayed CoreWLAN notification for
    /// the same value cannot create a second epoch after settlement.
    func sampleCurrentForNetworkEpoch() -> (
        ssid: String?,
        accessState: WiFiSSIDAccessState
    )? {
        guard accessLifecycle.accessState(
            for: locationManager.authorizationStatus
        ) == .ready else {
            return nil
        }
        let normalizedSSID = readCurrentSSID().flatMap {
            $0.isEmpty ? nil : $0
        }
        lastSSID = normalizedSSID
        lastAccessState = .ready
        accessLifecycle.invalidatePendingUpdates()
        return (normalizedSSID, .ready)
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        accessLifecycle.authorizationDidChange()
        // A repeat callback must replace any observation it invalidated.
        lastAccessState = nil
        start()
    }

    func isCurrentUpdate(_ revision: UInt64) -> Bool {
        accessLifecycle.isCurrentUpdate(revision)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        announceSettlingAndScheduleRefresh()
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        announceSettlingAndScheduleRefresh()
    }

    func clientConnectionInterrupted() {
        announceSettlingAndScheduleRefresh()
    }

    private func announceSettlingAndScheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSettling()
            self.scheduleRefresh(delay: 1)
        }
    }

    private func scheduleRefresh(delay: TimeInterval) {
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWorkItem = nil
            self.refresh()
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func refresh() {
        guard accessLifecycle.accessState(
            for: locationManager.authorizationStatus
        ) == .ready else {
            return
        }
        emit(
            ssid: readCurrentSSID(),
            accessState: .ready
        )
    }

    private func readCurrentSSID() -> String? {
        client.interfaces()?.compactMap {
            interface -> String? in
            guard interface.powerOn() else { return nil }
            return interface.ssid()
        }.first?.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
    }

    private func emit(
        ssid: String?,
        accessState: WiFiSSIDAccessState
    ) {
        let normalizedSSID = ssid.flatMap { $0.isEmpty ? nil : $0 }
        let accessStateChanged = accessState != lastAccessState
        guard normalizedSSID != lastSSID || accessState != lastAccessState else {
            return
        }
        lastSSID = normalizedSSID
        lastAccessState = accessState
        if accessStateChanged {
            appLog("Wi-Fi SSID access state=\(accessState.logValue)")
        }
        let revision = accessLifecycle.invalidatePendingUpdates()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentUpdate(revision) else { return }
            self.onUpdate(normalizedSSID, accessState, revision)
        }
    }

    private func startMonitoringIfNeeded() -> Bool {
        guard !monitoring else { return true }
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
        } catch {
            client.delegate = nil
            return false
        }
        do {
            try client.startMonitoringEvent(with: .powerDidChange)
        } catch {
            try? client.stopMonitoringEvent(with: .ssidDidChange)
            client.delegate = nil
            return false
        }
        monitoring = true
        return true
    }
}
