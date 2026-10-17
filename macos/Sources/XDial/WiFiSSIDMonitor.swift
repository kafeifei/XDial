import CoreLocation
import CoreWLAN
import Foundation
import SystemConfiguration

/// SSID 只是宿主控制面的场景触发事实。它不进入 ConnectionPlan，
/// 不参与 DNS、路由或 Underlay 接口选择。Wi-Fi 链路状态与 SSID 同次采样，
/// 只用于区分“确认离开 Wi-Fi”与“暂时读不到 SSID”。
final class WiFiSSIDMonitor: NSObject, CLLocationManagerDelegate,
    CWEventDelegate
{
    typealias UpdateHandler = (
        String?, WiFiSSIDAccessState, WiFiLinkState, UInt64
    ) -> Void
    typealias SettlingHandler = () -> Void

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let onSettling: SettlingHandler
    private let onUpdate: UpdateHandler
    private var monitoring = false
    private var refreshWorkItem: DispatchWorkItem?
    private var lastSSID: String?
    private var lastAccessState: WiFiSSIDAccessState?
    private var lastLink: WiFiLinkState = .unknown
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
        lastLink = .unknown
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
        accessState: WiFiSSIDAccessState,
        link: WiFiLinkState
    )? {
        guard accessLifecycle.accessState(
            for: locationManager.authorizationStatus
        ) == .ready else {
            return nil
        }
        let normalizedSSID = readCurrentSSID().flatMap {
            $0.isEmpty ? nil : $0
        }
        let link = readCurrentLinkState()
        logLinkChange(link)
        lastSSID = normalizedSSID
        lastAccessState = .ready
        lastLink = link
        accessLifecycle.invalidatePendingUpdates()
        return (normalizedSSID, .ready, link)
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
            accessState: .ready,
            link: readCurrentLinkState()
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

    /// Link facts are read only alongside a ready SSID sample; every other
    /// access state reports `.unknown` and therefore never confirms a
    /// disconnect.
    private func readCurrentLinkState() -> WiFiLinkState {
        WiFiLinkStatePolicy.state(
            for: (CWWiFiClient.interfaceNames() ?? []).sorted().map {
                Self.linkFacts(interfaceName: $0)
            }
        )
    }

    private static func linkFacts(
        interfaceName: String
    ) -> WiFiInterfaceLinkFacts {
        let link = SCDynamicStoreCopyValue(
            nil,
            SCDynamicStoreKeyCreateNetworkInterfaceEntity(
                nil,
                kSCDynamicStoreDomainState,
                interfaceName as CFString,
                kSCEntNetLink
            )
        ) as? [String: Any]
        // The Wi-Fi daemon publishes its power state under the AirPort
        // entity; SystemConfiguration has no public constant for it.
        let airPort = SCDynamicStoreCopyValue(
            nil,
            SCDynamicStoreKeyCreateNetworkInterfaceEntity(
                nil,
                kSCDynamicStoreDomainState,
                interfaceName as CFString,
                kSCEntNetAirPort
            )
        ) as? [String: Any]
        return WiFiInterfaceLinkFacts(
            powerOn: airPort?["Power Status"] as? Bool,
            linkActive: link?[kSCPropNetLinkActive as String] as? Bool
        )
    }

    private func logLinkChange(_ link: WiFiLinkState) {
        guard link != lastLink else { return }
        appLog("Wi-Fi link state=\(link.logValue)")
    }

    private func emit(
        ssid: String?,
        accessState: WiFiSSIDAccessState,
        link: WiFiLinkState = .unknown
    ) {
        let normalizedSSID = ssid.flatMap { $0.isEmpty ? nil : $0 }
        let accessStateChanged = accessState != lastAccessState
        guard normalizedSSID != lastSSID
                || accessState != lastAccessState
                || link != lastLink else {
            return
        }
        logLinkChange(link)
        lastSSID = normalizedSSID
        lastAccessState = accessState
        lastLink = link
        if accessStateChanged {
            appLog("Wi-Fi SSID access state=\(accessState.logValue)")
        }
        let revision = accessLifecycle.invalidatePendingUpdates()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentUpdate(revision) else { return }
            self.onUpdate(normalizedSSID, accessState, link, revision)
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
