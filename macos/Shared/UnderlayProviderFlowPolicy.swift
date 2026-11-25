import Foundation

/// A flow opened by another Network Extension provider process is that
/// provider's own transport or control traffic — a VPN's tunnel packets,
/// relay and NAT probes, or its DNS forwarder. It is part of the Underlay
/// XDial stacks on, not user traffic: claiming it would place the other
/// provider on top of XDial and loop its tunnel back through itself. Such a
/// flow is released to the system unchanged.
///
/// The decision uses only what the kernel attests for the flow's process —
/// its executable path (from the audit token) and its Network Extension
/// entitlement — never a product name, bundle identifier or interface name.
enum UnderlayProviderFlowPolicy {
    static let networkExtensionEntitlement =
        "com.apple.developer.networking.networkextension"

    /// Provider processes are launched by the system from an activated
    /// system extension (`/Library/SystemExtensions/<id>/<name>.systemextension`)
    /// or from an app extension (`<name>.appex`). A containing app that only
    /// configures a provider runs from neither layout.
    static func isProviderExecutableLayout(_ executablePath: String) -> Bool {
        let components = (executablePath as NSString).pathComponents
        guard components.count >= 4,
              components[components.count - 2] == "MacOS",
              components[components.count - 3] == "Contents"
        else {
            return false
        }
        let bundle = components[components.count - 4]
        if bundle.hasSuffix(".systemextension") {
            return components.count == 8
                && components[0] == "/"
                && components[1] == "Library"
                && components[2] == "SystemExtensions"
        }
        return bundle.hasSuffix(".appex")
    }

    static func grantsNetworkExtension(_ entitlementValue: Any?) -> Bool {
        if let values = entitlementValue as? [String] {
            return values.contains { !$0.isEmpty }
        }
        if let value = entitlementValue as? String {
            return !value.isEmpty
        }
        return false
    }

    /// `entitlementValue` is only read for a provider-shaped executable, so
    /// ordinary application flows never pay for the code-signing lookup.
    static func isUnderlayProvider(
        executablePath: String?,
        entitlementValue: () -> Any?
    ) -> Bool {
        guard let executablePath,
              isProviderExecutableLayout(executablePath)
        else {
            return false
        }
        return grantsNetworkExtension(entitlementValue())
    }
}
