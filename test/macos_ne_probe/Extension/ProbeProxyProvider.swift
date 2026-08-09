import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog
import Security

final class ProbeProxyProvider: NETransparentProxyProvider {
    private let logger = Logger(
        subsystem: "com.kafeifei.xdial.ne-probe.extension",
        category: "flows"
    )
    private var trialID = "-"
    private var scope = ""
    private var socksPort: UInt16 = 0
    private var domain = ""
    private var address = ""
    private var embeddedSingBox: EmbeddedSingBox?

    override func startProxy(
        options: [String: Any]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol
        scope = providerProtocol?.providerConfiguration?["scope"] as? String ?? ""
        if let configuredPort = providerProtocol?
            .providerConfiguration?["socksPort"] as? Int,
           let parsedPort = UInt16(exactly: configuredPort)
        {
            socksPort = parsedPort
        } else {
            socksPort = 0
        }
        domain = providerProtocol?.providerConfiguration?["domain"] as? String ?? ""
        address = providerProtocol?.providerConfiguration?["address"] as? String ?? ""
        trialID = providerProtocol?.providerConfiguration?["trialID"] as? String ?? "-"

        if ["relay-tcp", "relay-domain", "relay-all", "embedded-all"].contains(scope),
           socksPort == 0
        {
            completionHandler(ProbeProviderError.invalidSOCKSPort)
            return
        }

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if scope == "all" || scope == "relay-all" || scope == "embedded-all" {
            settings.includedNetworkRules = [
                NENetworkRule(
                    remoteNetworkEndpoint: nil,
                    remotePrefix: 0,
                    localNetworkEndpoint: nil,
                    localPrefix: 0,
                    protocol: .any,
                    direction: .outbound
                ),
            ]
        } else if scope == "dns" || scope == "relay-domain" {
            guard !domain.isEmpty else {
                completionHandler(ProbeProviderError.missingDomain)
                return
            }
            settings.includedNetworkRules = [
                NENetworkRule(
                    destinationHostEndpoint: NWEndpoint.hostPort(
                        host: NWEndpoint.Host(domain),
                        port: .any
                    ),
                    protocol: .any
                ),
            ]
        } else if scope == "scoped" || scope == "relay-tcp" {
            guard !domain.isEmpty else {
                completionHandler(ProbeProviderError.missingDomain)
                return
            }
            guard IPv4Address(address) != nil else {
                completionHandler(ProbeProviderError.invalidIPv4Address)
                return
            }
            settings.includedNetworkRules = [
                NENetworkRule(
                    destinationNetworkEndpoint: NWEndpoint.hostPort(
                        host: NWEndpoint.Host(address),
                        port: .any
                    ),
                    prefix: 32,
                    protocol: .any
                ),
            ]
        } else {
            completionHandler(ProbeProviderError.invalidScope)
            return
        }

        if scope == "embedded-all" {
            let embedded = EmbeddedSingBox(logger: logger)
            do {
                try embedded.start(port: socksPort)
                embeddedSingBox = embedded
            } catch {
                completionHandler(error)
                return
            }
        }

        setTunnelNetworkSettings(settings) { error in
            if let error {
                self.embeddedSingBox?.stop()
                self.embeddedSingBox = nil
                self.logger.error(
                    "start trial=\(self.trialID, privacy: .public) scope=\(self.scope, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            } else {
                self.logger.notice(
                    "started trial=\(self.trialID, privacy: .public) scope=\(self.scope, privacy: .public)"
                )
            }
            completionHandler(error)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.notice("stopped reason=\(reason.rawValue)")
        embeddedSingBox?.stop()
        embeddedSingBox = nil
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let metadataIdentifier = flow.metaData.sourceAppSigningIdentifier
        let auditIdentifier = signingIdentifier(
            auditToken: flow.metaData.sourceAppAuditToken
        ) ?? "-"
        let remoteHostname = flow.remoteHostname ?? "-"
        logger.notice(
            "flow trial=\(self.trialID, privacy: .public) auditApp=\(auditIdentifier, privacy: .public) metadataApp=\(metadataIdentifier, privacy: .public) host=\(remoteHostname, privacy: .public) type=\(String(describing: type(of: flow)), privacy: .public)"
        )
        if scope == "relay-tcp"
            || scope == "relay-domain"
            || scope == "relay-all"
            || scope == "embedded-all"
        {
            // The standalone prototype runs sing-box as an ad-hoc signed
            // `a.out` process. Let its outbound sockets continue into the
            // pre-existing Underlay instead of feeding them back into this
            // ingress. The production design will colocate sing-box with the
            // provider so its own sockets are excluded by construction.
            if scope != "embedded-all", metadataIdentifier == "a.out" {
                logger.notice(
                    "bypass trial=\(self.trialID, privacy: .public) app=\(metadataIdentifier, privacy: .public)"
                )
                return false
            }
            guard socksPort != 0 else {
                return false
            }
            if let tcpFlow = flow as? NEAppProxyTCPFlow {
                TCPFlowSOCKSRelay.start(
                    flow: tcpFlow,
                    socksPort: socksPort,
                    trialID: trialID,
                    logger: logger
                )
                return true
            }
            if (scope == "relay-domain"
                || scope == "relay-all"
                || scope == "embedded-all"),
               let udpFlow = flow as? NEAppProxyUDPFlow
            {
                UDPFlowSOCKSRelay.start(
                    flow: udpFlow,
                    socksPort: socksPort,
                    trialID: trialID,
                    logger: logger
                )
                return true
            }
            return false
        }
        // Apple specifies that false from NETransparentProxyProvider hands the
        // flow back to the networking stack without proxying it.
        return false
    }

    private func signingIdentifier(auditToken: Data?) -> String? {
        guard let auditToken, !auditToken.isEmpty else {
            return nil
        }
        let attributes = [
            kSecGuestAttributeAudit as String: auditToken,
        ] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &code
        )
        guard guestStatus == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(
            code,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard staticStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: 0),
            &information
        )
        guard
            informationStatus == errSecSuccess,
            let dictionary = information as? [String: Any]
        else {
            return nil
        }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }
}

private enum ProbeProviderError: Error {
    case invalidSOCKSPort
    case missingDomain
    case invalidIPv4Address
    case invalidScope
}
