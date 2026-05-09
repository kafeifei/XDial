import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("⚓️ \(state.tr("港口", "Ports"))").tag(0)
                    Text("📦 \(state.tr("货品", "Cargoes"))").tag(1)
                    Text("🚢 \(state.tr("邮轮", "Cruises"))").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Button {
                    tab = 3
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text(state.tr("通用", "General"))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(tab == 3 ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(8)

            Divider()

            ZStack {
                if tab == 0 { PortsTab() }
                else if tab == 1 { CargoesTab() }
                else if tab == 2 { CruisesTab() }
                else { GeneralTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 520)
    }
}

// MARK: - 通用 Tab

struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @State private var confirmingUninstall = false
    @State private var deleteDataOnUninstall = false
    @State private var uninstallError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                HStack {
                    Text(state.tr("语言", "Language"))
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $state.language) {
                        ForEach(Lang.allCases, id: \.self) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    Spacer()
                }

                Toggle(isOn: $state.launchAtLogin) {
                    Text(state.tr("开机自动启动", "Launch at login"))
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(state.tr("卸载", "Uninstall"))
                    .font(.headline)
                Text(state.tr(
                    "停止 helper、删除 LaunchDaemon 和相关文件。",
                    "Stop helper, remove LaunchDaemon and related files."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    confirmingUninstall = true
                } label: {
                    Text(state.tr("卸载…", "Uninstall…"))
                }
            }
            .padding(.horizontal, 16)

            Spacer()

            if let err = uninstallError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .confirmationDialog(
            state.tr("确认卸载 XDial？", "Uninstall XDial?"),
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button(state.tr("仅卸载 helper", "Uninstall helper only")) {
                deleteDataOnUninstall = false
                runUninstall()
            }
            Button(state.tr("卸载并删除所有数据", "Uninstall and delete all data"), role: .destructive) {
                deleteDataOnUninstall = true
                runUninstall()
            }
            Button(state.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(state.tr(
                "「卸载并删除所有数据」会清除你保存的所有出口、规则、策略组和 Keychain 中的密码。",
                "“Uninstall and delete all data” removes all your ports, cargoes, cruises, and Keychain passwords."
            ))
        }
    }

    private func runUninstall() {
        state.uninstall(deleteData: deleteDataOnUninstall) { ok, err in
            if ok {
                uninstallError = nil
                if deleteDataOnUninstall {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }
            } else {
                uninstallError = err
            }
        }
    }
}

// MARK: - 港口 Tab

struct PortsTab: View {
    @EnvironmentObject var state: AppState
    @State private var showAddSub = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.ports) { $port in
                        PortRow(port: $port, onDelete: { delete(port) })
                    }
                    ForEach($state.profile.subscriptions) { $sub in
                        SubscriptionRow(sub: $sub, onDelete: { deleteSub(sub) })
                    }
                }
                .padding(10)
            }
            .onAppear { state.probeNetwork() }
            Divider()
            HStack {
                Spacer()
                Menu {
                    Button("VPN") { add(type: "vpn") }
                    Button("Trojan") { add(type: "trojan") }
                    Button("Shadowsocks") { add(type: "shadowsocks") }
                    Button("VMess") { add(type: "vmess") }
                    Divider()
                    Button(state.tr("从订阅导入…", "Import from subscription…")) {
                        showAddSub = true
                    }
                } label: {
                    Label(state.tr("添加港口", "Add Port"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
        .sheet(isPresented: $showAddSub) {
            AddSubscriptionSheet(isPresented: $showAddSub)
        }
    }

    private func add(type: String) {
        let id = type + "-" + String(UUID().uuidString.prefix(6))
        let name: String
        switch type {
        case "vpn": name = "VPN"
        case "trojan": name = "Trojan 节点"
        case "shadowsocks": name = "SS 节点"
        case "vmess": name = "VMess 节点"
        default: name = "节点"
        }
        state.profile.ports.append(Port(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ port: Port) {
        if port.type == "direct" { return }
        state.profile.ports.removeAll { $0.id == port.id }
        state.save()
    }

    private func deleteSub(_ sub: Subscription) {
        state.deleteSubscription(sub.id)
    }
}

struct PortRow: View {
    @SwiftUI.Binding var port: Port
    var onDelete: () -> Void
    @State private var expanded = false
    @EnvironmentObject var state: AppState
    @ObservedObject private var net = NetworkInfo.shared

    private var isLocked: Bool { port.type == "direct" }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            locked: isLocked,
            onToggle: { expanded.toggle() },
            onDelete: isLocked ? nil : onDelete,
            enabled: Binding(get: { port.enabled }, set: { if !isLocked { port.enabled = $0; state.save() } }),
            header: {
                Image(systemName: port.verified ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(.secondary)

                Text(port.name).font(.system(size: 13, weight: .medium))

                if !briefInfo.isEmpty {
                    Text(briefInfo).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(typeLabel).font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("名称").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("名称", text: $port.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: port.name) { _, _ in state.save() }
                    }
                    detailFields
                }
            }
        )
        .opacity(isLocked ? 0.6 : (port.verified ? 1.0 : 0.7))
    }

    private var briefInfo: String {
        // 已探测：显示真实出口 IP/地区
        if let info = net.perPort[port.id], !info.summary.isEmpty {
            return info.summary
        }
        // 仅启用且当前在探测时显示"检测中"
        if net.probing && port.enabled {
            return "检测中…"
        }
        // 未启用或已探测但无结果：显示静态配置
        switch port.type {
        case "vpn":
            return port.vpnServer
        case "trojan":
            guard !port.trojanServer.isEmpty else { return "" }
            return "\(port.trojanServer):\(port.trojanPort)"
        case "shadowsocks":
            guard !port.ssServer.isEmpty else { return "" }
            return "\(port.ssServer):\(port.ssPort)"
        case "vmess":
            guard !port.vmessServer.isEmpty else { return "" }
            return "\(port.vmessServer):\(port.vmessPort)"
        default:
            return ""
        }
    }

    private var typeLabel: String {
        switch port.type {
        case "direct": return "直连"
        case "vpn": return "VPN"
        case "trojan": return "Trojan"
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        default: return port.type
        }
    }

    @ViewBuilder
    private var detailFields: some View {
        switch port.type {
        case "vpn":
            field("服务器", $port.vpnServer, placeholder: "vpn.example.com:8443")
            field("用户名", $port.vpnUsername)
            secureField("密码", $port.vpnPassword)
        case "trojan":
            field("服务器", $port.trojanServer)
            intField("端口", $port.trojanPort)
            field("SNI", $port.trojanSNI)
            secureField("密码", $port.trojanPassword)
        case "shadowsocks":
            field("服务器", $port.ssServer)
            intField("端口", $port.ssPort)
            field("加密方法", $port.ssMethod)
            secureField("密码", $port.ssPassword)
        case "vmess":
            field("服务器", $port.vmessServer)
            intField("端口", $port.vmessPort)
            secureField("UUID", $port.vmessUUID)
            intField("Alter ID", $port.vmessAltID)
        default:
            EmptyView()
        }
    }

    private func field(_ label: String, _ binding: SwiftUI.Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ASCIITextField(placeholder: placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    port.verified = false
                    state.save()
                }
        }
    }

    private func secureField(_ label: String, _ binding: SwiftUI.Binding<String>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ASCIISecureField(placeholder: "", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    port.verified = false
                    state.save()
                }
        }
    }

    private func intField(_ label: String, _ binding: SwiftUI.Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    port.verified = false
                    state.save()
                }
        }
    }
}

// MARK: - 货品 Tab

struct CargoesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.cargoes) { $rule in
                        CargoRow(rule: $rule, onDelete: { delete(rule) })
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Spacer()
                Menu {
                    Button("URL 货品") { add(type: "url") }
                    Button("手动域名/IP") { add(type: "manual") }
                } label: {
                    Label("添加货品", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
    }

    private func add(type: String) {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        let name = type == "url" ? "新 URL 货品" : "新手动货品"
        state.profile.cargoes.append(Cargo(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ rule: Cargo) {
        state.profile.cargoes.removeAll { $0.id == rule.id }
        for i in state.profile.cruises.indices {
            state.profile.cruises[i].bindings.removeAll { $0.cargoID == rule.id }
        }
        state.save()
    }
}

struct CargoRow: View {
    @SwiftUI.Binding var rule: Cargo
    var onDelete: () -> Void
    @State private var expanded = true
    @State private var domainsText = ""
    @State private var cidrsText = ""
    @State private var loaded = false
    @EnvironmentObject var state: AppState

    private func saveDomainsAndCIDRs() {
        rule.domains = domainsText.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        rule.cidrs = cidrsText.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        state.save()
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            onToggle: { expanded.toggle() },
            onDelete: onDelete,
            enabled: Binding(get: { rule.enabled }, set: { rule.enabled = $0; state.save() }),
            header: {
                Text(rule.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(rule.type == "url" ? "URL" : state.tr("手动", "Manual"))
                    .font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $rule.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: rule.name) { _, _ in state.save() }
                    }
                    if rule.type == "url" { urlFields }
                    else { manualFields }
                }
            }
        )
    }

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                ASCIITextField(placeholder: "https://...", text: $rule.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: rule.url) { _, _ in state.save() }
            }
            HStack {
                Text("格式").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Picker("", selection: $rule.format) {
                    Text("自动").tag("auto")
                    Text("sing-box .srs").tag("srs")
                    Text("sing-box .json").tag("json")
                    Text("纯文本列表").tag("text")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: rule.format) { _, _ in state.save() }
            }
        }
        .padding(.leading, 18)
    }

    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("域名（每行一个）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $domainsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 60)
                    .border(Color.gray.opacity(0.3))
                    .onChange(of: domainsText) { _, _ in
                        if loaded { saveDomainsAndCIDRs() }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("IP CIDR（每行一个）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $cidrsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 50)
                    .border(Color.gray.opacity(0.3))
                    .onChange(of: cidrsText) { _, _ in
                        if loaded { saveDomainsAndCIDRs() }
                    }
            }
        }
        .padding(.leading, 18)
        .onAppear {
            domainsText = rule.domains.joined(separator: "\n")
            cidrsText = rule.cidrs.joined(separator: "\n")
            loaded = true
        }
    }
}

// MARK: - 邮轮 Tab

struct CruisesTab: View {
    @EnvironmentObject var state: AppState
    @State private var showTemplate = false
    @State private var newName = ""
    @State private var expandedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.cruises) { $cruise in
                        CruiseRow(
                            cruise: $cruise,
                            isActive: cruise.id == state.profile.activeCruiseID,
                            isExpanded: expandedID == cruise.id,
                            onToggle: { expandedID = expandedID == cruise.id ? nil : cruise.id },
                            onActivate: {
                                state.profile.activeCruiseID = cruise.id
                                state.save()
                            },
                            onDelete: { state.deleteCruise(cruise) }
                        )
                    }
                }
                .padding(10)
            }
            Divider()
            AddBar {
                Menu {
                    ForEach(CruiseTemplate.allCases, id: \.self) { t in
                        Button(t.displayName) {
                            state.createCruise(from: t, named: t.displayName)
                        }
                    }
                } label: {
                    Label(state.tr("添加邮轮", "Add Cruise"), systemImage: "plus")
                }
            }
        }
    }

}

struct CruiseRow: View {
    @SwiftUI.Binding var cruise: Cruise
    let isActive: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState

    private var bindingSummary: String {
        let n = cruise.bindings.count
        return n == 0 ? state.tr("无规则", "No rules") : "\(n) \(state.tr("条规则", "rules"))"
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onDelete: onDelete,
            accentBar: isActive,
            header: {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .onTapGesture { onActivate() }
                }
                Text(cruise.name).font(.system(size: 13, weight: .medium))
                Text(bindingSummary).font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("", text: $cruise.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: cruise.name) { _, _ in state.save() }
                    }

                    Divider()

                    HStack {
                        Text(state.tr("货品", "Cargo")).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text(state.tr("港口", "Port")).font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(cruise.bindings) { binding in
                        bindingRow(binding)
                    }

                    Divider()

                    HStack {
                        Text(state.tr("其他流量", "Other"))
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        exitPicker(selectedID: SwiftUI.Binding(
                            get: { cruise.defaultTargetID },
                            set: { cruise.defaultTargetID = $0; state.save() }
                        ))
                    }

                    // 添加货品
                    HStack {
                        Spacer()
                        Menu {
                            let usedIDs = Set(cruise.bindings.map { $0.cargoID })
                            let available = state.profile.cargoes.filter { !usedIDs.contains($0.id) }
                            if available.isEmpty {
                                Button(state.tr("（无可用货品）", "(No cargo available)")) {}.disabled(true)
                            } else {
                                ForEach(available) { rule in
                                    Button(rule.name) {
                                        let firstExit = state.profile.ports.first?.id ?? ""
                                        cruise.bindings.append(CargoLink(cargoID: rule.id, portID: firstExit))
                                        state.save()
                                    }
                                }
                            }
                        } label: {
                            Label(state.tr("添加货品", "Add Cargo"), systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func bindingRow(_ binding: CargoLink) -> some View {
        if let idx = cruise.bindings.firstIndex(where: { $0.cargoID == binding.cargoID }) {
            let isEmpty = binding.portID.isEmpty && binding.subscriptionID.isEmpty
            HStack {
                HStack(spacing: 4) {
                    if isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(state.profile.cargoes.first(where: { $0.id == binding.cargoID })?.name ?? "（已删除）")
                }
                .frame(width: 200, alignment: .leading)
                exitPicker(selectedID: $cruise.bindings[idx].targetID)
                Button {
                    cruise.bindings.removeAll { $0.cargoID == binding.cargoID }
                    state.save()
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func exitPicker(selectedID: SwiftUI.Binding<String>) -> some View {
        Picker("", selection: selectedID) {
            ForEach(state.profile.ports.filter { $0.enabled }) { e in
                Text(e.name).tag("port:\(e.id)")
            }
            if !state.profile.subscriptions.filter({ $0.enabled }).isEmpty {
                Divider()
                ForEach(state.profile.subscriptions.filter { $0.enabled }) { sub in
                    Label("\(sub.name) (\(sub.ports.count))", systemImage: "antenna.radiowaves.left.and.right")
                        .tag("sub:\(sub.id)")
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: selectedID.wrappedValue) { _, _ in state.save() }
    }
}

// MARK: - 订阅行

struct SubscriptionRow: View {
    @SwiftUI.Binding var sub: Subscription
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var refreshing = false
    @State private var testing = false
    @State private var delays: [String: Int] = [:]
    @EnvironmentObject var state: AppState
    @ObservedObject private var net = NetworkInfo.shared

    private var groupCount: Int { sub.proxyGroups.count }
    private var ruleCount: Int { sub.rules.count }
    private var probeInfo: String {
        guard let info = net.perPort[sub.id] else { return "" }
        if !info.error.isEmpty { return info.error }
        if info.ip.isEmpty { return "" }
        var s = info.ip
        if !info.region.isEmpty { s += " (\(info.region))" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠头
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(sub.name)
                    .font(.system(size: 13, weight: .medium))

                if !probeInfo.isEmpty {
                    Text(probeInfo)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    if groupCount > 0 {
                        Text("\(groupCount)\(state.tr("组", "g"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(sub.ports.count)\(state.tr("节点", "n"))")
                        .font(.caption).foregroundStyle(.secondary)

                    if sub.updatedAt > 0 {
                        Text(formatDate(sub.updatedAt))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { refreshSub() } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(state.tr("刷新", "Refresh"))
                }

                Toggle("", isOn: $sub.enabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .onChange(of: sub.enabled) { _, _ in state.save() }

                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }

            // 展开内容
            if expanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $sub.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: sub.name) { _, _ in state.save() }
                    }
                    HStack {
                        Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $sub.url)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: sub.url) { _, _ in state.save() }
                    }

                    // === 策略组 ===
                    if !sub.proxyGroups.isEmpty {
                        Divider()
                        Text(state.tr("策略组", "Groups"))
                            .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                        ForEach(Array(sub.proxyGroups.enumerated()), id: \.element.name) { idx, group in
                            groupRow(group: group, idx: idx)
                        }
                    }

                    // === 测速 ===
                    Divider()
                    HStack {
                        Button {
                            testAllNodes()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill").font(.caption2)
                                Text(state.tr("测速", "Test")).font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(testing || !state.engine.isConnected)

                        if testing {
                            ProgressView().controlSize(.small)
                            Text(state.tr("测速中…", "Testing…"))
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if !delays.isEmpty {
                            let ok = delays.values.filter { $0 > 0 }.count
                            let fail = delays.values.filter { $0 < 0 }.count
                            Text("\(ok) ✓  \(fail) ✗")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06))
                HStack(spacing: 0) {
                    Color.accentColor.opacity(0.5)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        )
    }

    @ViewBuilder
    private func groupRow(group: SubProxyGroup, idx: Int) -> some View {
        let selected = group.proxies.first ?? ""

        HStack {
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            MenuButton(selected, delays: delays, items: group.proxies) { _ in
                // TODO: Clash API 切换
            }
            .frame(maxWidth: 180, alignment: .trailing)
        }
    }

    private func groupTypeLabel(_ type: String) -> String {
        switch type {
        case "select", "selector": return "select"
        case "url-test", "urltest": return "auto"
        case "fallback": return "fallback"
        case "load-balance": return "balance"
        default: return type
        }
    }

    private func delayLabel(_ name: String) -> String {
        guard let ms = delays[name] else { return name }
        if ms < 0 { return "\(name)  ⏱ timeout" }
        return "\(name)  ⏱ \(ms)ms"
    }

    private func testAllNodes() {
        guard state.engine.isConnected else { return }
        testing = true
        let base = "http://127.0.0.1:9090"
        let testURL = "https://www.gstatic.com/generate_204"
        let ports = sub.ports
        let subID = sub.id

        Task {
            // 并行测所有节点
            await withTaskGroup(of: (String, Int).self) { group in
                for port in ports {
                    let name = port.name
                    let tag = "proxy-\(subID)-\(port.id)"
                    group.addTask {
                        guard let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                              let url = URL(string: "\(base)/proxies/\(encoded)/delay?url=\(testURL)&timeout=3000") else {
                            return (name, -1)
                        }
                        do {
                            let (data, _) = try await URLSession.shared.data(from: url)
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let delay = json["delay"] as? Int {
                                return (name, delay)
                            }
                        } catch {}
                        return (name, -1)
                    }
                }
                for await (name, ms) in group {
                    await MainActor.run { delays[name] = ms }
                }
            }
            await MainActor.run { testing = false }
        }
    }

    private func refreshSub() {
        refreshing = true
        state.engine.parseSubscription(url: sub.url, format: sub.format) { result in
            refreshing = false
            switch result {
            case .success(let r):
                state.updateSubscription(sub.id, with: r)
            case .failure(let err):
                state.engine.lastError = err.localizedDescription
            }
        }
    }

    private func formatDate(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

struct AddSubscriptionSheet: View {
    @SwiftUI.Binding var isPresented: Bool
    @EnvironmentObject var state: AppState
    @State private var name = ""
    @State private var url = ""
    @State private var fileContent = ""
    @State private var format = "auto"
    @State private var strategy = "urltest"
    @State private var parsing = false
    @State private var parsedResult: GoEngine.ParseResult?
    @State private var parseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.tr("添加订阅", "Add Subscription")).font(.headline)
                Spacer()
                Button(state.tr("取消", "Cancel")) { isPresented = false }
            }

            TextField(state.tr("名称", "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(state.tr("订阅 URL 或本地文件", "URL or local file"), text: $url)
                    .textFieldStyle(.roundedBorder)
                Button(state.tr("选择文件", "File")) {
                    pickFile()
                }
                .controlSize(.small)
            }

            HStack {
                Text(state.tr("格式", "Format")).font(.caption)
                Picker("", selection: $format) {
                    Text(state.tr("自动", "Auto")).tag("auto")
                    Text("Clash").tag("clash")
                    Text("Surge").tag("surge")
                    Text("Base64").tag("base64")
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(state.tr("策略", "Strategy")).font(.caption)
                Picker("", selection: $strategy) {
                    Text(state.tr("自动选优", "Auto Best")).tag("urltest")
                    Text(state.tr("手动选择", "Manual")).tag("selector")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if parsing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(state.tr("正在解析…", "Parsing…")).font(.caption)
                }
            }

            if let error = parseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let r = parsedResult {
                let summary = state.tr(
                    "解析到 \(r.ports.count) 个节点、\(r.proxyGroups?.count ?? 0) 个策略组、\(r.rules?.count ?? 0) 条规则",
                    "Found \(r.ports.count) nodes, \(r.proxyGroups?.count ?? 0) groups, \(r.rules?.count ?? 0) rules"
                )
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.green)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(r.ports) { port in
                            HStack {
                                Text(port.name).font(.caption)
                                Spacer()
                                Text(port.type).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                Button(state.tr("确认添加", "Add")) {
                    let n = name.isEmpty ? (URL(string: url)?.host ?? "Subscription") : name
                    state.addSubscription(name: n, url: url, format: format, strategy: strategy,
                                          ports: r.ports, proxyGroups: r.proxyGroups ?? [], rules: r.rules ?? [])
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(state.tr("解析", "Parse")) {
                    doParse()
                }
                .disabled((url.isEmpty && fileContent.isEmpty) || parsing)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .yaml, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let fileURL = panel.url {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                fileContent = content
                url = fileURL.lastPathComponent
            }
        }
    }

    private func doParse() {
        parsing = true
        parseError = nil
        parsedResult = nil

        state.engine.parseSubscription(url: url, content: fileContent, format: format) { result in
            parsing = false
            switch result {
            case .success(let r):
                parsedResult = r
            case .failure(let err):
                parseError = err.localizedDescription
            }
        }
    }
}

