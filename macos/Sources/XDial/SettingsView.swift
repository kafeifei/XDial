import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("公司域名").tag(0)
                Text("机场").tag(1)
                Text("自定义规则").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider().padding(.top, 8)

            Group {
                switch tab {
                case 0: companyDomainsTab
                case 1: airportTab
                case 2: customRulesTab
                default: EmptyView()
                }
            }
            .padding(12)
        }
        .frame(width: 300, height: 320)
    }

    // MARK: - 公司域名

    private var companyDomainsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("域名后缀（一行一个）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $state.companyDomains)
                .font(.system(.caption, design: .monospaced))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            Text("例：example.net, internal.example.net")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 机场

    private var airportTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("协议", selection: $state.airportType) {
                Text("Trojan").tag("trojan")
                Text("Shadowsocks").tag("shadowsocks")
                Text("VMess").tag("vmess")
            }
            .pickerStyle(.segmented)

            switch state.airportType {
            case "trojan": trojanFields
            case "shadowsocks": shadowsocksFields
            case "vmess": vmessFields
            default: EmptyView()
            }

            Spacer()

            Toggle("启用机场线路", isOn: $state.airportEnabled)
                .font(.caption)
        }
    }

    private var trojanFields: some View {
        VStack(spacing: 6) {
            TextField("服务器", text: $state.trojanServer)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("端口", text: $state.trojanPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                TextField("SNI", text: $state.trojanSNI)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("密码", text: $state.trojanPassword)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var shadowsocksFields: some View {
        VStack(spacing: 6) {
            TextField("服务器", text: $state.ssServer)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("端口", text: $state.ssPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Picker("加密", selection: $state.ssMethod) {
                    Text("aes-256-gcm").tag("aes-256-gcm")
                    Text("chacha20-ietf-poly1305").tag("chacha20-ietf-poly1305")
                    Text("2022-blake3-aes-256-gcm").tag("2022-blake3-aes-256-gcm")
                }
                .pickerStyle(.menu)
            }
            SecureField("密码", text: $state.ssPassword)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var vmessFields: some View {
        VStack(spacing: 6) {
            TextField("服务器", text: $state.vmessServer)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("端口", text: $state.vmessPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                TextField("Alter ID", text: $state.vmessAltID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            SecureField("UUID", text: $state.vmessUUID)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 自定义规则

    private var customRulesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自定义域名（一行一个）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $state.customDomains)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            Text("自定义 CIDR（一行一个）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $state.customCIDRs)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            Picker("走", selection: $state.customLineID) {
                Text("VPN").tag("company_vpn")
                Text("机场").tag("airport")
                Text("直连").tag("direct")
            }
            .pickerStyle(.segmented)
            .font(.caption)
        }
    }
}
