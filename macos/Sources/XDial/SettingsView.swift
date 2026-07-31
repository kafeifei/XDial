import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("📡 \(state.tr("线路", "Lines"))").tag(0)
                    Text("📋 \(state.tr("规则", "Rules"))").tag(1)
                    Text("🔀 \(state.tr("模式", "Modes"))").tag(2)
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

            if state.configDirty {
                dirtyBanner
            }
            if !state.installation.isReady {
                installationBanner
            }

            Divider()

            ZStack {
                if tab == 0 { LinesTab() }
                else if tab == 1 { RulesTab() }
                else if tab == 2 { ModesTab() }
                else { GeneralTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 520)
    }

    /// 设置窗口里任何一处编辑都可能造成"引擎还在跑旧配置"，所以横幅放在
    /// tab 之上、四个 tab 共用一份，而不是每个 tab 各自提醒一遍。
    private var dirtyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(state.tr("配置已修改，重连后生效", "Config changed — reconnect to apply"))
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button(state.tr("立即重连", "Reconnect now")) { state.reconnect() }
                .controlSize(.small)
                .disabled(state.isBusy || !state.canConnect)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var installationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(
                state.installation.report.error?.message
                    ?? state.tr(
                        "XDial 正在完成首次安装",
                        "XDial is completing first-run setup"
                    )
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Spacer()
            Button(state.tr("查看进度", "View Progress")) {
                state.installation.present()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
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

                VStack(alignment: .leading, spacing: 3) {
                    Toggle(isOn: $state.autoConnect) {
                        Text(state.tr(
                            "启动时自动连接",
                            "Connect automatically on launch"
                        ))
                    }
                    .toggleStyle(.switch)
                    Text(state.tr(
                        "此选项控制 XDial 启动后连接当前模式。合盖前已有连接时，唤醒后仍会等待网络恢复并重新连接。",
                        "This controls connecting the active Mode when XDial launches. A connection active before sleep is still restored after the network wakes."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(state.tr("卸载", "Uninstall"))
                    .font(.headline)
                Text(state.tr(
                    "断开 XDial，移除网络配置、网络扩展和后台服务，然后把应用移到废纸篓。",
                    "Disconnect XDial, remove its network configuration, extension, and background service, then move the app to Trash."
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
            Button(state.tr("卸载 XDial（保留设置）", "Uninstall XDial (keep settings)")) {
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
                "「卸载并删除所有数据」会清除线路、规则、模式，以及钥匙串里的密码。",
                "“Uninstall and delete all data” removes lines, rules, modes, and Keychain-stored passwords."
            ))
        }
    }

    private func runUninstall() {
        state.uninstall(deleteData: deleteDataOnUninstall) { ok, err in
            if ok {
                uninstallError = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            } else {
                uninstallError = err
            }
        }
    }
}

// MARK: - 线路 Tab

struct LinesTab: View {
    @EnvironmentObject var state: AppState
    @State private var showAddSub = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.lines) { $line in
                        LineRow(line: $line, onDelete: { delete(line) })
                    }
                    ForEach($state.profile.subscriptions) { $sub in
                        SubscriptionRow(sub: $sub, onDelete: { deleteSub(sub) })
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Spacer()
                Menu {
                    Button("VPN") { add(type: "vpn") }
                    Button("Trojan") { add(type: "trojan") }
                    Button("Shadowsocks") { add(type: "shadowsocks") }
                    Button("VMess") { add(type: "vmess") }
                    Button("AnyTLS") { add(type: "anytls") }
                    Button("Tailscale") { add(type: "tailscale") }
                    Divider()
                    Button(state.tr("从订阅导入…", "Import from subscription…")) {
                        showAddSub = true
                    }
                } label: {
                    Label(state.tr("添加线路", "Add Line"), systemImage: "plus")
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
        case "anytls": name = "AnyTLS 节点"
        case "tailscale": name = "Tailscale"
        default: name = "节点"
        }
        state.profile.lines.append(Line(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ line: Line) {
        if line.type == "direct" { return }
        if line.type == "tailscale" {
            state.engine.stopTailscaleSetup(lineID: line.id)
        }
        state.profile.lines.removeAll { $0.id == line.id }
        state.save()
    }

    private func deleteSub(_ sub: Subscription) {
        state.deleteSubscription(sub.id)
    }
}

private struct RuntimeResourceBadge: View {
    let kind: String
    let resourceID: String
    let enabled: Bool
    @EnvironmentObject private var state: AppState

    private var report: ConnectionReport? {
        state.engine.presentedConnectionReport
    }

    private var runtimeState: ConnectionResourceRuntimeState {
        .resolve(
            enabled: enabled,
            report: report,
            kind: kind,
            resourceID: resourceID
        )
    }

    private var task: ConnectionTaskReport? {
        report?.task(kind: kind, resourceID: resourceID)
    }

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var label: String {
        switch runtimeState {
        case .disabled:
            return state.tr("已停用", "Disabled")
        case .notObserved:
            return state.tr("尚未运行", "Not run")
        case .notPlanned:
            return state.tr("本次未使用", "Not in use")
        case let .task(taskState):
            switch taskState {
            case .pending:
                return state.tr("等待", "Waiting")
            case .running:
                return state.tr("检查中", "Checking")
            case .ready:
                return report?.state == .committed
                    ? state.tr("运行中", "Running")
                    : state.tr("已就绪", "Ready")
            case .committing:
                return state.tr("提交中", "Committing")
            case .committed:
                return state.tr("已接管", "Committed")
            case .rollingBack:
                return state.tr("正在回滚", "Rolling back")
            case .rolledBack:
                return report?.state == .cancelled
                    ? state.tr("已断开", "Disconnected")
                    : state.tr("已回滚", "Rolled back")
            case .failed:
                return state.tr("失败", "Failed")
            case .skipped:
                return state.tr("已跳过", "Skipped")
            }
        }
    }

    private var icon: String {
        switch runtimeState {
        case .disabled, .notObserved, .notPlanned:
            return "circle"
        case let .task(taskState):
            switch taskState {
            case .pending:
                return "circle"
            case .running, .committing, .rollingBack:
                return "clock.fill"
            case .ready, .committed:
                return "checkmark.circle.fill"
            case .rolledBack:
                return "arrow.uturn.backward.circle.fill"
            case .failed:
                return "xmark.octagon.fill"
            case .skipped:
                return "minus.circle"
            }
        }
    }

    private var color: Color {
        switch runtimeState {
        case .disabled, .notObserved, .notPlanned:
            return .secondary
        case let .task(taskState):
            switch taskState {
            case .pending, .rolledBack, .skipped:
                return .secondary
            case .running, .committing, .rollingBack:
                return .orange
            case .ready, .committed:
                return .green
            case .failed:
                return .red
            }
        }
    }

    private var helpText: String {
        if let message = task?.error?.message, !message.isEmpty {
            return message
        }
        switch runtimeState {
        case .disabled:
            return state.tr(
                "这条线路在配置中已停用。",
                "This line is disabled in the profile."
            )
        case .notObserved:
            return state.tr(
                "还没有连接事务可以证明这条线路的运行状态。",
                "No connection transaction has observed this resource yet."
            )
        case .notPlanned:
            return state.tr(
                "这条线路没有被本次运行中的 Mode 引用。",
                "This resource is not referenced by the runtime Mode."
            )
        case .task:
            return label
        }
    }
}

struct LineRow: View {
    @SwiftUI.Binding var line: Line
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var showAuthKey = false
    @State private var authKey = ""
    @State private var anyTLSALPNInput: String
    @EnvironmentObject var state: AppState
    @ObservedObject private var net = NetworkInfo.shared

    init(
        line: SwiftUI.Binding<Line>,
        onDelete: @escaping () -> Void
    ) {
        self._line = line
        self.onDelete = onDelete
        self._anyTLSALPNInput = State(
            initialValue: line.wrappedValue.anytlsALPN.joined(
                separator: "\n"
            )
        )
    }

    private var isLocked: Bool { line.type == "direct" }
    private var tailscaleStatus: TailscaleRuntimeStatus? {
        state.tailscaleConfigurationStatus(for: line.id)
    }
    private var tailscaleError: String? {
        state.tailscaleConfigurationError(for: line.id)
    }
    private var tailscaleBusy: Bool {
        state.isTailscaleConfigurationBusy(for: line.id)
    }
    private var tailscaleRuntimeConnected: Bool {
        ConnectionReportRuntimeFacts.committedLines(
            status: state.engine.status,
            report: state.engine.connectionReport
        )?.lineIDs.contains(line.id) == true
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            locked: isLocked,
            onToggle: { expanded.toggle() },
            onDelete: isLocked ? nil : onDelete,
            enabled: Binding(get: { line.enabled }, set: { if !isLocked { line.enabled = $0; state.save() } }),
            header: {
                RuntimeResourceBadge(
                    kind: "line",
                    resourceID: line.id,
                    enabled: line.enabled
                )

                Text(line.name)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if !isLocked { expanded.toggle() }
                    }

                if !briefInfo.isEmpty {
                    Text(briefInfo).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(typeLabel).font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    runtimeFailure
                    HStack {
                        Text("名称").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("名称", text: $line.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: line.name) { _, _ in state.save() }
                    }
                    detailFields
                }
            }
        )
        .opacity(line.enabled ? 1.0 : 0.65)
    }

    @ViewBuilder
    private var runtimeFailure: some View {
        if let task = state.engine.presentedConnectionReport?.task(
            kind: "line",
            resourceID: line.id
        ),
           task.state == .failed,
           let error = task.error {
            Label(
                error.message,
                systemImage: "exclamationmark.octagon.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
        }
    }

    private var briefInfo: String {
        // 出口地址只是当前连接事务的 Provider 观察；运行状态只看上方 badge。
        if let info = net.observation(
            for: line.id,
            transactionID: state.engine.connectionReport?.transactionID
        ), !info.summary.isEmpty {
            return info.summary
        }
        // 没有本次事务的有效观察时，只显示静态配置。
        switch line.type {
        case "tailscale":
            if tailscaleRuntimeConnected {
                if let status = tailscaleStatus,
                   let node = status.exitNodes.first(where: {
                       $0.ip == line.tailscaleExitNode
                   }) {
                    return state.tr(
                        "已连接 · \(node.name)",
                        "Connected · \(node.name)"
                    )
                }
                return state.tr("已连接", "Connected")
            }
            if let status = tailscaleStatus {
                if status.isRunning {
                    if line.tailscaleExitNode.isEmpty {
                        return state.tr("已登录 · 未选择出口", "Signed in · No exit node")
                    }
                    if let node = status.exitNodes.first(where: { $0.ip == line.tailscaleExitNode }) {
                        return node.online
                            ? state.tr("已登录 · \(node.name)", "Signed in · \(node.name)")
                            : state.tr("出口节点离线", "Exit node offline")
                    }
                    return state.tr("出口节点不可用", "Exit node unavailable")
                }
                return state.tr("需要登录", "Sign-in required")
            }
            return state.tr("登录状态未检查", "Sign-in status not checked")
        case "vpn":
            return line.vpnServer
        case "trojan":
            guard !line.trojanServer.isEmpty else { return "" }
            return "\(line.trojanServer):\(line.trojanPort)"
        case "shadowsocks":
            guard !line.ssServer.isEmpty else { return "" }
            return "\(line.ssServer):\(line.ssPort)"
        case "vmess":
            guard !line.vmessServer.isEmpty else { return "" }
            return "\(line.vmessServer):\(line.vmessPort)"
        case "anytls":
            guard !line.anytlsServer.isEmpty else { return "" }
            return "\(line.anytlsServer):\(line.anytlsPort)"
        default:
            return ""
        }
    }

    private var typeLabel: String {
        switch line.type {
        case "direct": return "直连"
        case "vpn": return "VPN"
        case "trojan": return "Trojan"
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        case "anytls": return "AnyTLS"
        case "tailscale": return "Tailscale"
        default: return line.type
        }
    }

    private var tailscaleStatusColor: Color {
        if tailscaleRuntimeConnected {
            return .green
        }
        if tailscaleStatus?.isRunning == true {
            if !line.tailscaleExitNode.isEmpty,
               tailscaleStatus?.exitNodes.first(where: { $0.ip == line.tailscaleExitNode })?.online != true {
                return .orange
            }
            return .green
        }
        if tailscaleStatus != nil || tailscaleError != nil {
            return .orange
        }
        return .gray
    }

    private var tailscaleStatusLabel: String {
        if tailscaleRuntimeConnected {
            return state.tr("已连接", "Connected")
        }
        if tailscaleStatus?.isRunning == true {
            return state.tr("已登录", "Signed in")
        }
        if tailscaleStatus != nil {
            return state.tr("需要登录", "Sign-in required")
        }
        return state.tr("尚未检查", "Not checked")
    }

    @ViewBuilder
    private var detailFields: some View {
        switch line.type {
        case "vpn":
            field("服务器", $line.vpnServer, placeholder: "vpn.example.com:8443")
            field("用户名", $line.vpnUsername)
            secureField("密码", $line.vpnPassword)
            insecureToggle
        case "trojan":
            field("服务器", $line.trojanServer)
            intField("端口", $line.trojanPort)
            field("SNI", $line.trojanSNI)
            secureField("密码", $line.trojanPassword)
            insecureToggle
        case "shadowsocks":
            field("服务器", $line.ssServer)
            intField("端口", $line.ssPort)
            field("加密方法", $line.ssMethod)
            secureField("密码", $line.ssPassword)
        case "vmess":
            field("服务器", $line.vmessServer)
            intField("端口", $line.vmessPort)
            secureField("UUID", $line.vmessUUID)
            intField("Alter ID", $line.vmessAltID)
        case "anytls":
            field("服务器", $line.anytlsServer)
            boundedIntField("端口", $line.anytlsPort, range: 1...65535)
            field("SNI", $line.anytlsSNI)
            secureField("密码", $line.anytlsPassword)
            anyTLSFingerprintField
            anyTLSALPNField
            boundedIntField(
                "检查间隔",
                $line.anytlsIdleSessionCheckInterval,
                range: 0...3600,
                help: state.tr(
                    "6–3600 秒；0 表示使用协议默认值",
                    "6–3600 seconds; 0 uses the protocol default"
                )
            )
            boundedIntField(
                "空闲超时",
                $line.anytlsIdleSessionTimeout,
                range: 0...3600,
                help: state.tr(
                    "6–3600 秒；0 表示使用协议默认值",
                    "6–3600 seconds; 0 uses the protocol default"
                )
            )
            boundedIntField(
                "最少空闲",
                $line.anytlsMinIdleSession,
                range: Line.anyTLSMinIdleSessionRange,
                help: state.tr(
                    "至少保留的空闲会话数（0–64）",
                    "Minimum idle sessions to retain (0–64)"
                )
            )
            anyTLSUDPField
            anyTLSTFOField
            insecureToggle
            if let issue = anyTLSVisibleValidationIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "tailscale":
            tailscaleDetail
        default:
            EmptyView()
        }
    }

    private var tailscaleDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(tailscaleStatusColor)
                    .frame(width: 8, height: 8)
                Text(tailscaleStatusLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if tailscaleBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        refreshTailscaleStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(state.tr("刷新状态", "Refresh status"))
                    .disabled(state.engine.status != "disconnected")
                }
            }

            if let error = tailscaleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                state.tr("启用 MagicDNS", "Enable MagicDNS"),
                isOn: Binding(
                    get: { line.tailscaleMagicDNS },
                    set: {
                        line.tailscaleMagicDNS = $0
                        state.save()
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption)
            .disabled(state.engine.status != "disconnected")
            .accessibilityIdentifier("tailscale-magic-dns-toggle")

            Text(state.tr(
                "解析并访问 Tailnet 节点；仅在当前 Mode 使用这条线路时生效，Mode 中已有的显式域名规则优先。",
                "Resolve and reach Tailnet peers only when the current Mode uses this line. Explicit domain rules in the Mode take priority."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if tailscaleRuntimeConnected {
                tailscaleConnectedFields
            } else if let status = tailscaleStatus, status.isRunning {
                tailscaleSignedInFields(status)
            } else {
                tailscaleSignInFields
            }
        }
        .padding(.top, 2)
    }

    private var tailscaleConnectedFields: some View {
        Text(state.tr(
            "本次连接事务已确认 Tailscale 线路就绪。断开 XDial 后可以刷新登录与出口节点配置。",
            "The current connection transaction confirmed this Tailscale line is ready. Disconnect XDial to refresh sign-in or exit-node configuration."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tailscaleSignInFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.tr(
                "登录只用于在本机建立一份持久的 Tailscale 身份，不会启动系统 VPN。",
                "Sign-in creates one persistent local Tailscale identity and does not start a system VPN."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                beginTailscaleLogin()
            } label: {
                Label(
                    state.tr("在浏览器中登录", "Sign In in Browser"),
                    systemImage: "safari"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tailscaleBusy || state.engine.status != "disconnected")
            .accessibilityIdentifier("tailscale-browser-login")

            DisclosureGroup(
                state.tr("使用 Auth Key", "Use Auth Key"),
                isExpanded: $showAuthKey
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("tskey-auth-…", text: $authKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .accessibilityIdentifier("tailscale-auth-key")
                    Text(state.tr(
                        "只用于这一次注册；提交后立即清空，不写入配置、钥匙串或日志。",
                        "Used once for registration, then cleared. It is not saved to the profile, Keychain, or logs."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Button(state.tr("使用 Auth Key 注册", "Register with Auth Key")) {
                        registerTailscaleAuthKey()
                    }
                    .disabled(
                        authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || tailscaleBusy
                            || state.engine.status != "disconnected"
                    )
                }
                .padding(.top, 5)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func tailscaleSignedInFields(_ status: TailscaleRuntimeStatus) -> some View {
        HStack {
            Text(state.tr("设备", "Device"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(state.profile.tailscale.hostname)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }

        HStack {
            Text(state.tr("出口节点", "Exit Node"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Picker("", selection: Binding(
                get: { line.tailscaleExitNode },
                set: {
                    line.tailscaleExitNode = $0
                    state.save()
                }
            )) {
                Text(state.tr("不使用", "None")).tag("")
                if !line.tailscaleExitNode.isEmpty,
                   !status.exitNodes.contains(where: { $0.ip == line.tailscaleExitNode }) {
                    Text(state.tr(
                        "已保存但当前不可用",
                        "Saved but unavailable"
                    )).tag(line.tailscaleExitNode)
                }
                ForEach(status.exitNodes) { node in
                    Text(exitNodeLabel(node))
                        .tag(node.ip)
                        .disabled(!node.online)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("tailscale-exit-node-picker")
        }

        if !line.tailscaleExitNode.isEmpty,
           status.exitNodes.first(where: { $0.ip == line.tailscaleExitNode })?.online != true {
            Label(
                state.tr(
                    "所选出口节点当前不可用；连接会明确失败，不会回落到其他出口。",
                    "The selected exit node is unavailable. Connection will fail instead of falling back."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        HStack {
            Spacer()
            Button(state.tr("退出登录", "Sign Out"), role: .destructive) {
                logoutTailscale()
            }
            .disabled(tailscaleBusy)
        }
    }

    private func exitNodeLabel(_ node: TailscaleRuntimeExitNode) -> String {
        var label = node.name.isEmpty ? node.ip : node.name
        if !node.online {
            label += state.tr("（离线）", " (Offline)")
        }
        return label
    }

    private func prepareTailscale(authKey: String = "") {
        guard line.type == "tailscale", !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        guard state.engine.status == "disconnected" else {
            state.setTailscaleConfigurationError(state.tr(
                "请先断开 XDial，再配置 Tailscale 登录状态。",
                "Disconnect XDial before configuring Tailscale sign-in."
            ), for: line.id)
            return
        }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        state.engine.prepareTailscale(
            profileJSON: state.buildProfileJSON(),
            lineID: line.id,
            authKey: authKey
        ) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            applyTailscaleResult(result)
        }
    }

    private func refreshTailscaleStatus() {
        // setup session 会在连接数据面或 helper 重启时被关闭。刷新必须具备
        // 自愈能力：重建隔离会话并读取同一份持久身份，而不是查询旧会话。
        prepareTailscale()
    }

    private func beginTailscaleLogin() {
        guard !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        // 设置窗口或 helper 重启后，旧卡片可能还在但 setup session 已经结束。
        // 登录按钮先重建会话，不能假设 onAppear 曾成功执行。
        state.engine.prepareTailscale(
            profileJSON: state.buildProfileJSON(),
            lineID: line.id
        ) { result in
            switch result {
            case let .failure(error):
                state.setTailscaleConfigurationBusy(false, for: line.id)
                state.setTailscaleConfigurationError(
                    error.localizedDescription,
                    for: line.id
                )
            case let .success(status):
                state.setTailscaleConfigurationStatus(
                    status,
                    for: line.id
                )
                if status.isRunning {
                    state.setTailscaleConfigurationBusy(
                        false,
                        for: line.id
                    )
                    return
                }
                if let url = validatedAuthURL(status.authURL) {
                    state.setTailscaleConfigurationBusy(
                        false,
                        for: line.id
                    )
                    NSWorkspace.shared.open(url)
                    startTailscalePolling()
                    return
                }
                requestTailscaleLoginURL()
            }
        }
    }

    private func requestTailscaleLoginURL() {
        state.engine.beginTailscaleLogin(lineID: line.id) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            switch result {
            case let .failure(error):
                state.setTailscaleConfigurationError(
                    error.localizedDescription,
                    for: line.id
                )
            case let .success(status):
                state.setTailscaleConfigurationStatus(
                    status,
                    for: line.id
                )
                if let url = validatedAuthURL(status.authURL) {
                    NSWorkspace.shared.open(url)
                    startTailscalePolling()
                } else if !status.isRunning {
                    state.setTailscaleConfigurationError(state.tr(
                        "没有取得有效的登录入口，请重试。",
                        "No valid sign-in URL was returned. Please try again."
                    ), for: line.id)
                }
            }
        }
    }

    private func registerTailscaleAuthKey() {
        let transientKey = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transientKey.isEmpty else { return }
        authKey = ""
        prepareTailscale(authKey: transientKey)
    }

    private func logoutTailscale() {
        guard !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        state.engine.logoutTailscale(lineID: line.id) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            applyTailscaleResult(result)
        }
    }

    private func applyTailscaleResult(_ result: Result<TailscaleRuntimeStatus, Error>) {
        switch result {
        case .success(let status):
            state.setTailscaleConfigurationStatus(
                status,
                for: line.id
            )
        case .failure(let error):
            state.setTailscaleConfigurationError(
                error.localizedDescription,
                for: line.id
            )
        }
    }

    private func requireInstallation() -> Bool {
        guard state.requireInstallationReady() else {
            state.setTailscaleConfigurationError(state.tr(
                "XDial 的首次安装尚未完成；安装窗口会自动继续。",
                "XDial first-run setup is not complete. The installation window will continue automatically."
            ), for: line.id)
            return false
        }
        return true
    }

    private func validatedAuthURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func startTailscalePolling() {
        state.startTailscaleConfigurationPolling(lineID: line.id)
    }

    private var insecureToggle: some View {
        HStack(alignment: .top) {
            Text("跳过证书验证").font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("", isOn: $line.allowInsecure)
                    .labelsHidden()
                    .onChange(of: line.allowInsecure) { _, _ in
                        markLineChanged()
                    }
                Text("仅自签证书的服务器才需要开启；开启后无法防中间人窃取凭据")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var anyTLSFingerprintField: some View {
        HStack {
            Text(state.tr("TLS 指纹", "TLS Fingerprint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Picker("", selection: SwiftUI.Binding(
                get: { line.anytlsClientFingerprint },
                set: { value in
                    guard line.anytlsClientFingerprint != value else {
                        return
                    }
                    line.anytlsClientFingerprint = value
                    markLineChanged()
                }
            )) {
                ForEach(
                    Line.anyTLSSupportedClientFingerprints,
                    id: \.self
                ) { fingerprint in
                    Text(anyTLSFingerprintLabel(fingerprint))
                        .tag(fingerprint)
                }
                if !Line.anyTLSSupportedClientFingerprints.contains(
                    line.anytlsClientFingerprint
                ) {
                    Text(state.tr(
                        "不支持：\(line.anytlsClientFingerprint)",
                        "Unsupported: \(line.anytlsClientFingerprint)"
                    ))
                    .tag(line.anytlsClientFingerprint)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    private var anyTLSALPNField: some View {
        HStack(alignment: .top) {
            Text("ALPN")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TextEditor(text: $anyTLSALPNInput)
                    .font(.caption.monospaced())
                    .frame(minHeight: 42, maxHeight: 58)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.35))
                    )
                    .onChange(of: anyTLSALPNInput) { _, input in
                        let protocols = input.isEmpty
                            ? []
                            : input.components(separatedBy: .newlines)
                        guard line.anytlsALPN != protocols else {
                            return
                        }
                        line.anytlsALPN = protocols
                        markLineChanged()
                    }
                    .onChange(of: line.anytlsALPN) { _, protocols in
                        let input = protocols.joined(separator: "\n")
                        if anyTLSALPNInput != input {
                            anyTLSALPNInput = input
                        }
                    }
                Text(state.tr(
                    "每行一个协议，留空表示不指定，最多 8 项",
                    "One protocol per line; blank leaves ALPN unspecified; max 8"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var anyTLSTFOField: some View {
        HStack(alignment: .top) {
            Text("TFO")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("", isOn: SwiftUI.Binding(
                    get: { line.tfo },
                    set: { value in
                        // AnyTLS 握手会读取已经建立连接的远端地址，与
                        // TCP Fast Open 不兼容。导入的 true 仍要保留并
                        // 可见地阻止连接，但 UI 只允许用户把它关掉。
                        guard !value, line.tfo else { return }
                        line.tfo = false
                        markLineChanged()
                    }
                ))
                .labelsHidden()
                .disabled(!line.tfo)
                Text(state.tr(
                    line.tfo
                        ? "订阅导入了 TFO；AnyTLS 不支持，请关闭后再连接"
                        : "AnyTLS 不支持 TCP Fast Open",
                    line.tfo
                        ? "The subscription enabled TFO. Turn it off before connecting."
                        : "AnyTLS does not support TCP Fast Open"
                ))
                .font(.caption2)
                .foregroundStyle(
                    line.tfo ? Color.red : Color.secondary
                )
            }
            Spacer()
        }
    }

    private var anyTLSUDPField: some View {
        HStack(alignment: .top) {
            Text("UDP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    state.tr("原生 UoT", "Native UoT"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
                Text(state.tr(
                    line.udp
                        ? "AnyTLS 数据面原生承载 UDP"
                        : "订阅声明了 udp=false；该值仅保留为导入事实，AnyTLS 数据面仍原生支持 UDP",
                    line.udp
                        ? "The AnyTLS data plane carries UDP natively"
                        : "The subscription declared udp=false. It is preserved as imported metadata; the AnyTLS data plane still supports UDP natively."
                ))
                .font(.caption2)
                .foregroundStyle(
                    line.udp ? Color.secondary : Color.orange
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var anyTLSVisibleValidationIssue: String? {
        return line.anyTLSOptionsValidationIssue
    }

    private func anyTLSFingerprintLabel(_ value: String) -> String {
        switch value {
        case "":
            return state.tr("系统 TLS（不伪装）", "System TLS (no mimic)")
        case "chrome":
            return "Chrome"
        case "firefox":
            return "Firefox"
        case "edge":
            return "Edge"
        case "safari":
            return "Safari"
        case "ios":
            return "iOS"
        case "android":
            return "Android"
        case "random":
            return state.tr("随机浏览器", "Random browser")
        case "randomized":
            return state.tr("随机生成", "Randomized")
        case "chrome_psk", "chrome_psk_shuffle",
             "chrome_padding_psk_shuffle", "chrome_pq",
             "chrome_pq_psk":
            return "\(value) \(state.tr("（兼容）", "(legacy)"))"
        default:
            return value.uppercased()
        }
    }

    private func markLineChanged() {
        line.verified = false
        state.save()
    }

    private func field(_ label: String, _ binding: SwiftUI.Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ASCIITextField(placeholder: placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
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
                    markLineChanged()
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
                    markLineChanged()
                }
        }
    }

    private func boundedIntField(
        _ label: String,
        _ binding: SwiftUI.Binding<Int>,
        range: ClosedRange<Int>,
        help: String = ""
    ) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", value: binding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: binding.wrappedValue) { _, _ in
                        // 保留用户输入的事实，让模型校验与连接计划 fail-closed。
                        // 边输边静默夹到边界会把 30 之类的正常输入改成 60，
                        // 也会掩盖订阅里真正的非法值。
                        markLineChanged()
                    }
                let effectiveHelp = help.isEmpty
                    ? "\(range.lowerBound)–\(range.upperBound)"
                    : help
                if !effectiveHelp.isEmpty {
                    Text(effectiveHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggleField(_ label: String, _ binding: SwiftUI.Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Toggle("", isOn: binding)
                .labelsHidden()
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
                }
            Spacer()
        }
    }
}

// MARK: - 规则 Tab

struct RulesTab: View {
    @EnvironmentObject var state: AppState
    private let presetCatalog = RuleSetPresetCatalog.load()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.ruleSets) { $rule in
                        RuleSetRow(rule: $rule, onDelete: { delete(rule) })
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Spacer()
                Menu {
                    Menu(state.tr("URL 规则", "URL Rule")) {
                        ForEach(presetCatalog.presets) { preset in
                            Button(
                                state.language == .zh
                                    ? preset.nameZH
                                    : preset.nameEN
                            ) {
                                add(preset: preset)
                            }
                        }
                    }
                    Button(state.tr("手动域名/IP", "Manual Domain/IP")) {
                        addManual()
                    }
                } label: {
                    Label(
                        state.tr("添加规则", "Add Rule"),
                        systemImage: "plus"
                    )
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
    }

    private func add(preset: RuleSetPreset) {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        state.profile.ruleSets.append(RuleSet(
            id: id,
            name: state.language == .zh
                ? preset.nameZH
                : preset.nameEN,
            type: "url",
            url: preset.url,
            format: preset.format,
            invert: preset.invert
        ))
        state.save()
    }

    private func addManual() {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        state.profile.ruleSets.append(RuleSet(
            id: id,
            name: state.tr("新手动规则", "New Manual Rule"),
            type: "manual"
        ))
        state.save()
    }

    private func delete(_ rule: RuleSet) {
        state.profile.ruleSets.removeAll { $0.id == rule.id }
        for i in state.profile.modes.indices {
            state.profile.modes[i].bindings.removeAll { $0.ruleSetID == rule.id }
        }
        state.save()
    }
}

struct RuleSetRow: View {
    @SwiftUI.Binding var rule: RuleSet
    var onDelete: () -> Void
    @State private var expanded = true
    @State private var domainsText = ""
    @State private var cidrsText = ""
    @State private var loaded = false
    @EnvironmentObject var state: AppState

    private func saveDomainsAndCIDRs() {
        rule.domains = domainsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
            .filter { !$0.isEmpty }
        rule.cidrs = cidrsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
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
                Text(ruleTypeLabel)
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
                    if rule.type == "url" {
                        urlFields
                    } else {
                        manualFields
                    }
                }
            }
        )
    }

    private var ruleTypeLabel: String {
        switch rule.type {
        case "url":
            return "URL"
        default:
            return state.tr("手动", "Manual")
        }
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
            Toggle(
                state.tr(
                    "反向匹配（匹配列表之外）",
                    "Invert (match outside the list)"
                ),
                isOn: $rule.invert
            )
            .font(.caption)
            .onChange(of: rule.invert) { _, _ in state.save() }
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

// MARK: - 模式 Tab

struct ModesTab: View {
    @EnvironmentObject var state: AppState
    @State private var showTemplate = false
    @State private var newName = ""
    @State private var expandedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.modes) { $mode in
                        ModeRow(
                            mode: $mode,
                            isActive: mode.id == state.profile.activeModeID,
                            isExpanded: expandedID == mode.id,
                            onToggle: { expandedID = expandedID == mode.id ? nil : mode.id },
                            // 和主 popover 的 Picker、DebugServer 的 select-mode
                            // 走同一个 intent，门禁与 dirty 置位只有一处实现
                            onActivate: { state.activateMode(mode.id) },
                            onDelete: { state.deleteMode(mode) }
                        )
                    }
                }
                .padding(10)
            }
            Divider()
            AddBar {
                Menu {
                    ForEach(ModeTemplate.allCases, id: \.self) { t in
                        Button(t.displayName) {
                            state.createMode(from: t, named: t.displayName)
                        }
                    }
                } label: {
                    Label(state.tr("添加模式", "Add Mode"), systemImage: "plus")
                }
            }
        }
    }

}

struct ModeRow: View {
    @SwiftUI.Binding var mode: Mode
    let isActive: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState

    private var bindingSummary: String {
        let n = mode.bindings.count
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
                Text(mode.name).font(.system(size: 13, weight: .medium))
                Text(bindingSummary).font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("", text: $mode.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: mode.name) { _, _ in state.save() }
                    }

                    Divider()

                    HStack {
                        Text(state.tr("规则", "Rule")).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text(state.tr("线路", "Line")).font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(mode.bindings) { binding in
                        bindingRow(binding)
                    }

                    Divider()

                    HStack {
                        Text(state.tr("其他流量", "Other"))
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        exitPicker(selectedID: SwiftUI.Binding(
                            get: { mode.defaultTargetID },
                            set: { mode.defaultTargetID = $0; state.save() }
                        ))
                    }

                    // 添加规则
                    HStack {
                        Spacer()
                        Menu {
                            let usedIDs = Set(mode.bindings.map { $0.ruleSetID })
                            let available = state.profile.ruleSets.filter { !usedIDs.contains($0.id) }
                            if available.isEmpty {
                                Button(state.tr("（无可用规则）", "(No rule available)")) {}.disabled(true)
                            } else {
                                ForEach(available) { rule in
                                    Button(rule.name) {
                                        let firstExit = state.profile.lines.first?.id ?? ""
                                        mode.bindings.append(RuleBinding(ruleSetID: rule.id, lineID: firstExit))
                                        state.save()
                                    }
                                }
                            }
                        } label: {
                            Label(state.tr("添加规则", "Add Rule"), systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func bindingRow(_ binding: RuleBinding) -> some View {
        if let idx = mode.bindings.firstIndex(where: { $0.ruleSetID == binding.ruleSetID }) {
            let isEmpty = binding.lineID.isEmpty && binding.subscriptionID.isEmpty
            HStack {
                HStack(spacing: 4) {
                    if isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(state.profile.ruleSets.first(where: { $0.id == binding.ruleSetID })?.name ?? "（已删除）")
                }
                .frame(width: 200, alignment: .leading)
                exitPicker(selectedID: $mode.bindings[idx].targetID)
                Button {
                    mode.bindings.removeAll { $0.ruleSetID == binding.ruleSetID }
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
            ForEach(state.profile.lines.filter { $0.enabled }) { e in
                Text(e.name).tag("port:\(e.id)")
            }
            if !state.profile.subscriptions.filter({ $0.enabled }).isEmpty {
                Divider()
                ForEach(state.profile.subscriptions.filter { $0.enabled }) { sub in
                    Label("\(sub.name) (\(sub.lines.count))", systemImage: "antenna.radiowaves.left.and.right")
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
    @EnvironmentObject var state: AppState

    private var groupCount: Int { sub.proxyGroups.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠头
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                RuntimeResourceBadge(
                    kind: "subscription",
                    resourceID: sub.id,
                    enabled: sub.enabled
                )

                Text(sub.name)
                    .font(.system(size: 13, weight: .medium))

                if groupCount > 0 {
                    Text("\(groupCount)\(state.tr("组", "g"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(sub.lines.count)\(state.tr("节点", "n"))")
                    .font(.caption).foregroundStyle(.secondary)

                if sub.updatedAt > 0 {
                    Text(formatDate(sub.updatedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
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
                        // id 用 offset 而不是 name，订阅原始 YAML 里允许重名策略组，
                        // 用 name 当 id 会导致 SwiftUI ForEach 重复 key 渲染错乱
                        ForEach(Array(sub.proxyGroups.enumerated()), id: \.offset) { _, group in
                            groupRow(group: group)
                        }
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
    private func groupRow(group: SubProxyGroup) -> some View {
        HStack {
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(groupTypeLabel(group.type))
                    .font(.caption)
                Text("\(group.proxies.count)\(state.tr("节点", " nodes"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                    "解析到 \(r.lines.count) 个节点、\(r.proxyGroups?.count ?? 0) 个策略组、\(r.rules?.count ?? 0) 条规则",
                    "Found \(r.lines.count) nodes, \(r.proxyGroups?.count ?? 0) groups, \(r.rules?.count ?? 0) rules"
                )
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.green)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(r.lines) { line in
                            HStack {
                                Text(line.name).font(.caption)
                                Spacer()
                                Text(line.type).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                Button(state.tr("确认添加", "Add")) {
                    let n = name.isEmpty ? (URL(string: url)?.host ?? "Subscription") : name
                    state.addSubscription(name: n, url: url, format: format, strategy: strategy,
                                          lines: r.lines, proxyGroups: r.proxyGroups ?? [], rules: r.rules ?? [])
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
