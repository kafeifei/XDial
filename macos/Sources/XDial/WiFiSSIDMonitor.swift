import CoreLocation
import CoreWLAN
import Foundation

enum WiFiSSIDAccessState: Equatable {
    case ready
    case permissionRequired
    case denied
    case unavailable
}

/// SSID 只是宿主控制面的场景触发事实。它不进入 ConnectionPlan，
/// 不参与 DNS、路由或 Underlay 接口选择。
final class WiFiSSIDMonitor: NSObject, CLLocationManagerDelegate,
    CWEventDelegate
{
    typealias UpdateHandler = (String?, WiFiSSIDAccessState) -> Void
    typealias SettlingHandler = () -> Void

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let onSettling: SettlingHandler
    private let onUpdate: UpdateHandler
    private var monitoring = false
    private var refreshWorkItem: DispatchWorkItem?
    private var lastSSID: String?
    private var lastAccessState: WiFiSSIDAccessState?

    init(
        onSettling: @escaping SettlingHandler,
        onUpdate: @escaping UpdateHandler
    ) {
        self.onSettling = onSettling
        self.onUpdate = onUpdate
        super.init()
        locationManager.delegate = self
    }

    func start(requestAuthorization: Bool) {
        if !monitoring {
            client.delegate = self
            do {
                try client.startMonitoringEvent(with: .ssidDidChange)
                try client.startMonitoringEvent(with: .powerDidChange)
                monitoring = true
            } catch {
                emit(ssid: nil, accessState: .unavailable)
                return
            }
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            scheduleRefresh(delay: 0)
        case .notDetermined:
            emit(ssid: nil, accessState: .permissionRequired)
            if requestAuthorization {
                locationManager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            emit(ssid: nil, accessState: .denied)
        @unknown default:
            emit(ssid: nil, accessState: .unavailable)
        }
    }

    func stop() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        guard monitoring else { return }
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        try? client.stopMonitoringEvent(with: .powerDidChange)
        client.delegate = nil
        monitoring = false
    }

    func requestAuthorizationAndRefresh() {
        start(requestAuthorization: true)
    }

    /// Synchronously sample the SSID at a network-epoch settle point. Updating
    /// the dedupe baseline here ensures a delayed CoreWLAN notification for
    /// the same value cannot create a second epoch after settlement.
    func sampleCurrentForNetworkEpoch() -> (
        ssid: String?,
        accessState: WiFiSSIDAccessState
    )? {
        guard locationManager.authorizationStatus == .authorizedAlways else {
            return nil
        }
        let normalizedSSID = readCurrentSSID().flatMap {
            $0.isEmpty ? nil : $0
        }
        lastSSID = normalizedSSID
        lastAccessState = .ready
        return (normalizedSSID, .ready)
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        start(requestAuthorization: false)
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
        guard locationManager.authorizationStatus == .authorizedAlways
        else {
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
        guard normalizedSSID != lastSSID || accessState != lastAccessState else {
            return
        }
        lastSSID = normalizedSSID
        lastAccessState = accessState
        DispatchQueue.main.async { [onUpdate] in
            onUpdate(normalizedSSID, accessState)
        }
    }
}
