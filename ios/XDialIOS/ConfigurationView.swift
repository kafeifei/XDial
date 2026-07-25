import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationView: View {
    @EnvironmentObject private var app: AppState
    @State private var section: ConfigSection = .lines
    @State private var showAddSubscription = false
    @State private var editingLineID: String?
    @State private var refreshingSubscriptionIDs: Set<String> = []
    @State private var subscriptionErrors: [String: String] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(ConfigSection.allCases) { item in
                        Text(item.title(app)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if app.hasPendingRuntimeChanges {
                    PendingRuntimeChangesBanner()
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                switch section {
                case .lines: lineList
                case .rules: ruleList
                case .subscriptions: subscriptionList
                }
            }
            .navigationTitle(app.tr("配置", "Configuration"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addControl
                        .disabled(app.hasActiveTunnel || app.isBusy)
                }
            }
            .sheet(isPresented: $showAddSubscription) {
                AddSubscriptionView()
                    .environmentObject(app)
            }
            .navigationDestination(item: $editingLineID) { lineID in
                LineEditorView(lineID: lineID)
            }
        }
    }

    @ViewBuilder
    private var addControl: some View {
        switch section {
        case .lines:
            Menu {
                addLineButton(type: "vpn", name: "AnyConnect")
                addLineButton(type: "trojan", name: "Trojan")
                addLineButton(type: "shadowsocks", name: "Shadowsocks")
                addLineButton(type: "vmess", name: "VMess")
                addLineButton(type: "tailscale", name: "Tailscale")
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(app.tr("添加线路", "Add line"))
        case .rules:
            Menu {
                addRuleButton(type: "url")
                addRuleButton(type: "manual")
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(app.tr("添加规则", "Add rule"))
        case .subscriptions:
            Button {
                showAddSubscription = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(app.tr("添加订阅", "Add subscription"))
        }
    }

    private var lineList: some View {
        List {
            ForEach(app.profile.lines) { line in
                let issues = line.enabled ? app.routeLineConfigurationIssues(line) : []
                NavigationLink {
                    LineEditorView(lineID: line.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: lineSymbol(line.type))
                            .foregroundStyle(line.type == "tailscale" ? Color.orange : Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.name)
                            Text(lineListSummary(line))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !issues.isEmpty {
                                Text(app.tr(
                                    "需配置：\(issues.joined(separator: "、"))",
                                    "Setup required: \(issues.joined(separator: ", "))"
                                ))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                            }
                        }
                        Spacer()
                        if !line.enabled {
                            Text(app.tr("停用", "Off"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("line-row-\(line.id)")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if line.type != "direct" {
                        Button(role: .destructive) {
                            deleteLine(line)
                        } label: {
                            Label(app.tr("删除", "Delete"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
            }
        }
        .overlay {
            if app.profile.lines.isEmpty {
                ContentUnavailableView(
                    app.tr("暂无线路", "No lines"),
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(app.tr("点击右上角添加线路。", "Add a line from the toolbar."))
                )
            }
        }
    }

    private func lineListSummary(_ line: Line) -> String {
        guard line.type == "tailscale" else {
            return mobileLineTypeLabel(line.type)
        }
        let exitNode = line.tailscaleExitNode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.tailscaleAuthenticated {
            return app.tr("Tailscale · 尚未登录", "Tailscale · Sign-in required")
        }
        if exitNode.isEmpty {
            return app.tr("Tailscale · 未选择出口节点", "Tailscale · No exit node")
        }
        return app.tr("Tailscale · 出口 \(exitNode)", "Tailscale · Exit \(exitNode)")
    }

    private var ruleList: some View {
        List {
            ForEach(app.profile.ruleSets) { ruleSet in
                NavigationLink {
                    RuleEditorView(ruleSetID: ruleSet.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ruleSet.isConnectivityTestRule
                              ? "lock.shield.fill"
                              : (ruleSet.enabled ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(ruleSet.isConnectivityTestRule
                                             ? Color.accentColor
                                             : (ruleSet.enabled ? .green : .secondary))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ruleSet.name)
                            Text(ruleSummary(ruleSet))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if !ruleSet.isConnectivityTestRule {
                        Button {
                            setRuleEnabled(ruleSet.id, enabled: !ruleSet.enabled)
                        } label: {
                            Label(
                                ruleSet.enabled ? app.tr("停用", "Disable") : app.tr("启用", "Enable"),
                                systemImage: ruleSet.enabled ? "pause.circle" : "checkmark.circle"
                            )
                        }
                        .tint(ruleSet.enabled ? .orange : .green)
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !ruleSet.isConnectivityTestRule {
                        Button(role: .destructive) {
                            deleteRule(ruleSet)
                        } label: {
                            Label(app.tr("删除", "Delete"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
            }
        }
        .overlay {
            if app.profile.ruleSets.isEmpty {
                ContentUnavailableView(
                    app.tr("暂无规则", "No rules"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(app.tr("添加 URL 或手工规则。", "Add a URL or manual rule."))
                )
            }
        }
    }

    private var subscriptionList: some View {
        List {
            if app.profile.subscriptions.isEmpty {
                ContentUnavailableView(
                    app.tr("暂无订阅", "No subscriptions"),
                    systemImage: "link",
                    description: Text(app.tr("点击右上角添加并解析订阅。", "Add and parse a subscription from the toolbar."))
                )
            } else {
                ForEach(app.profile.subscriptions) { subscription in
                    NavigationLink {
                        SubscriptionEditorView(subscriptionID: subscription.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(subscription.name)
                                Text(subscriptionSummary(subscription))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !subscription.url.isEmpty {
                                    Text(subscriptionLocation(subscription.url))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if let error = subscriptionErrors[subscription.id] {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if refreshingSubscriptionIDs.contains(subscription.id) {
                                ProgressView()
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            refreshSubscription(subscription)
                        } label: {
                            Label(app.tr("刷新", "Refresh"), systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                        .disabled(app.hasActiveTunnel || app.isBusy || subscription.url.isEmpty)

                        Button {
                            setSubscriptionEnabled(subscription.id, enabled: !subscription.enabled)
                        } label: {
                            Label(
                                subscription.enabled ? app.tr("停用", "Disable") : app.tr("启用", "Enable"),
                                systemImage: subscription.enabled ? "pause.circle" : "checkmark.circle"
                            )
                        }
                        .tint(subscription.enabled ? .orange : .green)
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            app.deleteSubscription(subscription.id)
                            refreshingSubscriptionIDs.remove(subscription.id)
                            subscriptionErrors.removeValue(forKey: subscription.id)
                        } label: {
                            Label(app.tr("删除", "Delete"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
            }
        }
    }

    private func addLineButton(type: String, name: String) -> some View {
        Button(name) {
            guard !app.hasActiveTunnel, !app.isBusy else { return }
            let id = "line-" + String(UUID().uuidString.prefix(8)).lowercased()
            app.profile.lines.append(Line(id: id, name: name, type: type, enabled: false))
            editingLineID = id
            _ = app.save()
        }
    }

    private func addRuleButton(type: String) -> some View {
        Button(type == "url" ? app.tr("URL 规则", "URL rule") : app.tr("手工规则", "Manual rule")) {
            guard !app.hasActiveTunnel, !app.isBusy else { return }
            let id = "rule-" + String(UUID().uuidString.prefix(8)).lowercased()
            let name = type == "url"
                ? app.tr("新 URL 规则", "New URL Rule")
                : app.tr("新手工规则", "New Manual Rule")
            app.profile.ruleSets.append(RuleSet(id: id, name: name, type: type))
            app.save()
        }
    }

    private func deleteLine(_ line: Line) {
        guard !app.hasActiveTunnel, !app.isBusy, line.type != "direct" else { return }
        app.profile.lines.removeAll { $0.id == line.id }
        // 保留模式里的悬空引用；连接前校验会阻止启动并要求用户明确选择替代目标。
        app.save()
    }

    private func deleteRule(_ ruleSet: RuleSet) {
        guard !app.hasActiveTunnel, !app.isBusy else { return }
        app.profile.ruleSets.removeAll { $0.id == ruleSet.id }
        for index in app.profile.modes.indices {
            app.profile.modes[index].bindings.removeAll { $0.ruleSetID == ruleSet.id }
        }
        app.save()
    }

    private func setRuleEnabled(_ id: String, enabled: Bool) {
        guard !app.hasActiveTunnel, !app.isBusy,
              let index = app.profile.ruleSets.firstIndex(where: { $0.id == id }) else { return }
        app.profile.ruleSets[index].enabled = enabled
        app.save()
    }

    private func ruleSummary(_ ruleSet: RuleSet) -> String {
        if ruleSet.type == "url" {
            return ruleSet.url.isEmpty
                ? app.tr("尚未填写 URL", "URL not set")
                : subscriptionLocation(ruleSet.url)
        }
        return app.tr(
            "\(ruleSet.domains.count) 个域名 · \(ruleSet.cidrs.count) 个 CIDR",
            "\(ruleSet.domains.count) domains · \(ruleSet.cidrs.count) CIDRs"
        )
    }

    private func subscriptionSummary(_ subscription: Subscription) -> String {
        app.tr(
            "\(subscription.lines.count) 个节点 · \(subscription.proxyGroups.count) 个策略组 · \(subscription.rules.count) 条规则",
            "\(subscription.lines.count) nodes · \(subscription.proxyGroups.count) groups · \(subscription.rules.count) rules"
        )
    }

    private func subscriptionLocation(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              let host = components.host, !host.isEmpty else {
            return app.tr("地址已配置", "Address configured")
        }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private func setSubscriptionEnabled(_ id: String, enabled: Bool) {
        guard !app.hasActiveTunnel, !app.isBusy,
              let index = app.profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        app.profile.subscriptions[index].enabled = enabled
        app.save()
    }

    private func refreshSubscription(_ subscription: Subscription) {
        guard !app.hasActiveTunnel, !app.isBusy,
              !refreshingSubscriptionIDs.contains(subscription.id) else { return }
        let engine = (app.engine as? GoEngine) ?? GoEngine.shared

        refreshingSubscriptionIDs.insert(subscription.id)
        subscriptionErrors.removeValue(forKey: subscription.id)
        engine.parseSubscription(url: subscription.url, format: subscription.format) { result in
            refreshingSubscriptionIDs.remove(subscription.id)
            switch result {
            case .success(let parsed):
                app.updateSubscription(subscription.id, with: parsed)
            case .failure(let error):
                subscriptionErrors[subscription.id] = safeError(error)
            }
        }
    }

    private func safeError(_ error: Error) -> String {
        MobileDiagnosticsService.redacted(error.localizedDescription, using: app.profile)
            ?? app.tr("订阅操作失败", "Subscription operation failed")
    }
}

private enum ConfigSection: String, CaseIterable, Identifiable {
    case lines, rules, subscriptions
    var id: String { rawValue }

    @MainActor
    func title(_ app: AppState) -> String {
        switch self {
        case .lines: return app.tr("线路", "Lines")
        case .rules: return app.tr("规则", "Rules")
        case .subscriptions: return app.tr("订阅", "Subs")
        }
    }
}

private struct LineEditorView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var hasPendingChanges = false
    @State private var saveFailureMessage: String?
    @State private var tailscaleRuntimeStatus: TailscaleRuntimeStatus?
    @State private var tailscaleStatusError: String?
    @State private var isRefreshingTailscaleStatus = false
    @State private var tailscaleExitSelectionNeedsReconnect = false
    @State private var pendingTailscaleSetupLogin = false
    @State private var showingTailscaleLogoutConfirmation = false
    @State private var isLoggingOutTailscale = false
    let lineID: String

    var body: some View {
        Form {
            if let index = lineIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("名称", "Name"), text: lineBinding(index, \.name))
                        .accessibilityIdentifier("line-name-\(lineID)")
                    LabeledContent(app.tr("类型", "Type"), value: mobileLineTypeLabel(app.profile.lines[index].type))
                    Toggle(app.tr("启用", "Enabled"), isOn: lineBinding(index, \.enabled))
                }
                .disabled(app.hasActiveTunnel)

                if app.profile.lines[index].type == "tailscale" {
                    fields(for: index)
                } else {
                    fields(for: index)
                        .disabled(app.hasActiveTunnel)
                }

                if app.profile.lines[index].type == "vpn" || app.profile.lines[index].type == "trojan" {
                    Section {
                        Toggle(app.tr("允许不安全证书", "Allow insecure certificate"),
                               isOn: lineBinding(index, \.allowInsecure))
                    } footer: {
                        Text(app.tr("仅在服务器使用自签证书时开启。", "Enable only for servers using a self-signed certificate."))
                    }
                    .disabled(app.hasActiveTunnel)
                }

                if app.profile.lines[index].type != "direct" {
                    Section {
                        Button(app.tr("删除线路", "Delete Line"), role: .destructive) {
                            deleteCurrentLine()
                        }
                        .disabled(app.hasActiveTunnel)
                    }
                }
            } else {
                ContentUnavailableView(app.tr("线路已删除", "Line deleted"), systemImage: "trash")
            }
        }
        .disabled(app.isBusy)
        .accessibilityIdentifier("line-editor-\(lineID)")
        .navigationTitle(app.tr("编辑线路", "Edit Line"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(app.tr(hasPendingChanges ? "保存" : "已保存",
                              hasPendingChanges ? "Save" : "Saved")) {
                    if persistPendingChanges() { dismiss() }
                }
                .disabled(!hasPendingChanges || app.hasActiveTunnel)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                _ = persistPendingChanges()
            } else {
                handlePendingTailscaleSetupState()
                refreshTailscaleStatusIfAvailable()
            }
        }
        .onAppear {
            refreshTailscaleStatusIfAvailable()
        }
        .onChange(of: app.engine.status) { _, _ in
            if app.canQueryTailscaleRuntime(lineID: lineID) {
                handlePendingTailscaleSetupState()
                refreshTailscaleStatusIfAvailable()
            } else {
                tailscaleRuntimeStatus = nil
                tailscaleStatusError = nil
                isRefreshingTailscaleStatus = false
                tailscaleExitSelectionNeedsReconnect = false
                if app.tailscaleSetupLineID == nil {
                    pendingTailscaleSetupLogin = false
                }
            }
        }
        .onDisappear {
            pendingSaveTask?.cancel()
            if hasPendingChanges { _ = persistPendingChanges() }
        }
        .alert(app.tr("保存失败", "Save Failed"), isPresented: saveFailurePresented) {
            Button(app.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(saveFailureMessage ?? app.tr("无法保存配置，请重试。", "Could not save the configuration. Please try again."))
        }
        .confirmationDialog(
            app.tr("退出这条 Tailscale 线路？", "Sign Out This Tailscale Line?"),
            isPresented: $showingTailscaleLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(app.tr("退出登录", "Sign Out"), role: .destructive) {
                logoutTailscale()
            }
            .accessibilityIdentifier("tailscale-logout-confirm")
            Button(app.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(app.tr(
                "只会退出 XDial 内的这条线路，不影响手机上的 Tailscale App 或其他线路。",
                "This signs out only this XDial line. It does not affect the Tailscale app or other lines."
            ))
        }
    }

    @ViewBuilder
    private func fields(for index: Int) -> some View {
        switch app.profile.lines[index].type {
        case "vpn":
            Section("AnyConnect") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.vpnServer))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(app.tr("用户名", "Username"), text: lineBinding(index, \.vpnUsername))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(app.tr("密码", "Password"), text: lineBinding(index, \.vpnPassword))
            }
        case "trojan":
            Section("Trojan") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.trojanServer))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.trojanPort), format: .number)
                    .keyboardType(.numberPad)
                SecureField(app.tr("密码", "Password"), text: lineBinding(index, \.trojanPassword))
                TextField("SNI", text: lineBinding(index, \.trojanSNI))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case "shadowsocks", "ss":
            Section("Shadowsocks") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.ssServer))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.ssPort), format: .number)
                    .keyboardType(.numberPad)
                TextField(app.tr("加密方法", "Method"), text: lineBinding(index, \.ssMethod))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(app.tr("密码", "Password"), text: lineBinding(index, \.ssPassword))
            }
        case "vmess":
            Section("VMess") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.vmessServer))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.vmessPort), format: .number)
                    .keyboardType(.numberPad)
                SecureField("UUID", text: lineBinding(index, \.vmessUUID))
                TextField("Alter ID", value: lineBinding(index, \.vmessAltID), format: .number)
                    .keyboardType(.numberPad)
            }
        case "tailscale":
            Section {
                TextField(
                    app.tr("设备名称（可选）", "Device name (optional)"),
                    text: tailscaleLineBinding(index, \.tailscaleHostname)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Toggle(
                    app.tr("接受子网路由", "Accept subnet routes"),
                    isOn: tailscaleLineBinding(index, \.tailscaleAcceptRoutes)
                )
            } header: {
                Text("Tailscale")
            } footer: {
                Text(app.tr(
                    "登录在 XDial 内独立完成，不会启动系统线路。正式连接后，MagicDNS/.ts.net 会按域名交给对应 Tailscale 线路。",
                    "Sign-in is completed inside XDial without starting a system line. During a normal connection, MagicDNS/.ts.net queries use the matching Tailscale line."
                ))
            }
            .disabled(app.hasActiveTunnel)

            Section {
                if !app.canQueryTailscaleRuntime(lineID: lineID) {
                    Label(
                        app.hasFormalTunnel
                            ? app.tr(
                                "当前连接没有运行这条线路。可启动独立设置来登录并选择出口节点，不影响当前连接。",
                                "The current connection is not running this line. Start isolated setup to sign in and select an exit node without affecting the connection."
                            )
                            : app.tr(
                                "尚未检查登录状态。启动独立设置后可登录并选择出口节点，不会启动系统线路。",
                                "Sign-in has not been checked. Isolated setup lets you sign in and select an exit node without starting the system line."
                            ),
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)

                    Button {
                        startTailscaleSetup()
                    } label: {
                        if pendingTailscaleSetupLogin || isRefreshingTailscaleStatus {
                            HStack {
                                ProgressView()
                                Text(app.tr("正在启动登录…", "Starting Sign-in…"))
                            }
                        } else {
                            Label(
                                app.profile.lines[index].tailscaleAuthenticated
                                    ? app.tr("检查登录状态与节点", "Check Sign-in and Nodes")
                                    : app.tr("设置并登录 Tailscale", "Set Up and Sign In to Tailscale"),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                    }
                    .accessibilityIdentifier("tailscale-start-setup")
                    .disabled(
                        pendingTailscaleSetupLogin
                            || isRefreshingTailscaleStatus
                            || !app.canStartTailscaleSetup(lineID: lineID)
                    )
                } else {
                    if let status = tailscaleRuntimeStatus {
                        LabeledContent(
                            app.tr("登录状态", "Sign-in status"),
                            value: tailscaleBackendLabel(status.backendState)
                        )
                        .accessibilityIdentifier("tailscale-login-status")

                        if let authURL = validTailscaleAuthURL(status.authURL) {
                            Button {
                                beginTailscaleLogin(fallbackURL: authURL)
                            } label: {
                                Label(app.tr("在浏览器中登录", "Sign In in Browser"), systemImage: "safari")
                            }
                            .accessibilityIdentifier("tailscale-open-login")
                        } else if ["needslogin", "needs_login",
                                   "needsmachineauth", "needs_machine_auth"].contains(
                                    status.backendState.lowercased()
                                   ) {
                            Button {
                                beginTailscaleLogin()
                            } label: {
                                Label(app.tr("登录 Tailscale", "Sign In to Tailscale"), systemImage: "safari")
                            }
                            .accessibilityIdentifier("tailscale-open-login")
                        }

                        if status.backendState.lowercased() == "running" {
                            Picker(
                                app.tr("出口节点", "Exit node"),
                                selection: tailscaleExitNodeBinding(index)
                            ) {
                                Text(app.tr("不使用", "None")).tag("")
                                let selected = app.profile.lines[index].tailscaleExitNode
                                if !selected.isEmpty && !status.exitNodes.contains(where: { $0.ip == selected }) {
                                    Text(app.tr("已保存但当前不可用：\(selected)", "Saved but unavailable: \(selected)"))
                                        .tag(selected)
                                }
                                ForEach(status.exitNodes) { node in
                                    Text(tailscaleExitNodeLabel(node))
                                        .tag(node.ip)
                                        .disabled(!node.online)
                                }
                            }
                            .accessibilityIdentifier("tailscale-exit-node-picker")
                            .disabled(app.isBusy || (app.hasFormalTunnel && !app.isConnected))

                            let selected = app.profile.lines[index].tailscaleExitNode
                            if !selected.isEmpty && !status.exitNodes.contains(where: { $0.ip == selected }) {
                                Label(
                                    app.tr(
                                        "已保存的出口节点当前不可用，请刷新或重新选择。",
                                        "The saved exit node is currently unavailable. Refresh or choose another node."
                                    ),
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                            }

                            Button(role: .destructive) {
                                showingTailscaleLogoutConfirmation = true
                            } label: {
                                if isLoggingOutTailscale {
                                    HStack {
                                        ProgressView()
                                        Text(app.tr("正在退出…", "Signing Out…"))
                                    }
                                } else {
                                    Label(app.tr("退出 Tailscale", "Sign Out of Tailscale"), systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            }
                            .accessibilityIdentifier("tailscale-logout")
                            .disabled(isLoggingOutTailscale || app.tailscaleSetupLineID != lineID)
                        }
                    }

                    if let tailscaleStatusError {
                        Label(tailscaleStatusError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Button {
                        refreshTailscaleStatus()
                    } label: {
                        if isRefreshingTailscaleStatus {
                            HStack {
                                ProgressView()
                                Text(app.tr("正在刷新…", "Refreshing…"))
                            }
                        } else {
                            Label(app.tr("刷新状态", "Refresh Status"), systemImage: "arrow.clockwise")
                        }
                    }
                    .accessibilityIdentifier("tailscale-refresh-nodes")
                    .disabled(isRefreshingTailscaleStatus)

                    if app.tailscaleSetupLineID == lineID {
                        Button {
                            app.finishTailscaleSetup()
                        } label: {
                            Label(app.tr("完成线路设置", "Finish Line Setup"), systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("tailscale-finish-setup")
                        .disabled(
                            app.isBusy
                                || !app.profile.lines[index].tailscaleAuthenticated
                                || tailscaleRuntimeStatus?.backendState.lowercased() != "running"
                        )
                    }
                }
            } header: {
                Text(app.tr("登录与出口节点", "Sign-in and Exit Node"))
            } footer: {
                if app.canQueryTailscaleRuntime(lineID: lineID)
                    && tailscaleRuntimeStatus == nil && tailscaleStatusError == nil {
                    Text(
                        app.tailscaleSetupLineID == lineID
                            ? app.tr(
                                "状态正在从独立设置会话读取。",
                                "Status is read from the isolated setup session."
                            )
                            : app.tr(
                                "状态正在从当前连接读取。",
                                "Status is read from the current connection."
                            )
                    )
                } else if !app.canQueryTailscaleRuntime(lineID: lineID) {
                    Text(app.tr(
                        "独立设置只在 XDial 内登录并读取节点，不改变系统连接状态。",
                        "Isolated setup signs in and discovers nodes inside XDial without changing the system connection state."
                    ))
                }
            }

            if tailscaleExitSelectionNeedsReconnect
                && app.isConnected
                && app.tailscaleSetupLineID != lineID {
                Section {
                    Text(app.tr(
                        "出口节点已保存；当前连接仍使用原设置。",
                        "The exit node is saved; the current connection still uses the previous setting."
                    ))
                    .foregroundStyle(.secondary)
                    Button {
                        guard app.hasPendingRuntimeChanges else { return }
                        tailscaleExitSelectionNeedsReconnect = false
                        app.reconnectToApplyChanges()
                    } label: {
                        Label(app.tr("重新连接并应用", "Reconnect and Apply"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        default:
            EmptyView()
        }
    }

    private func tailscaleLineBinding<T>(
        _ index: Int,
        _ keyPath: WritableKeyPath<Line, T>
    ) -> Binding<T> {
        Binding(
            get: { app.profile.lines[index][keyPath: keyPath] },
            set: { newValue in
                guard !app.hasActiveTunnel,
                      app.profile.lines.indices.contains(index) else { return }
                app.profile.lines[index][keyPath: keyPath] = newValue
                app.profile.lines[index].verified = false
                scheduleSave()
            }
        )
    }

    private func tailscaleExitNodeBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { app.profile.lines[index].tailscaleExitNode },
            set: { selected in
                guard app.profile.lines.indices.contains(index),
                      app.profile.lines[index].tailscaleExitNode != selected,
                      app.updateTailscaleExitSelection(
                          lineID: lineID,
                          selected: selected
                      ) else { return }
                tailscaleExitSelectionNeedsReconnect =
                    app.isConnected && app.tailscaleSetupLineID != lineID
            }
        )
    }

    private func refreshTailscaleStatusIfAvailable() {
        guard app.canQueryTailscaleRuntime(lineID: lineID),
              let index = lineIndex,
              app.profile.lines[index].type == "tailscale" else { return }
        refreshTailscaleStatus()
    }

    private func refreshTailscaleStatus() {
        guard app.canQueryTailscaleRuntime(lineID: lineID),
              !isRefreshingTailscaleStatus else { return }
        isRefreshingTailscaleStatus = true
        tailscaleStatusError = nil
        app.refreshTailscaleStatus(lineID: lineID) { result in
            isRefreshingTailscaleStatus = false
            switch result {
            case .success(let status):
                tailscaleRuntimeStatus = status
                _ = applyTailscaleAuthenticationStatus(status)
            case .failure(let error):
                tailscaleRuntimeStatus = nil
                tailscaleStatusError = tailscaleErrorMessage(error)
            }
        }
    }

    private func startTailscaleSetup() {
        guard !pendingTailscaleSetupLogin,
              !isRefreshingTailscaleStatus,
              persistPendingChanges() else { return }
        pendingTailscaleSetupLogin = true
        isRefreshingTailscaleStatus = true
        tailscaleStatusError = nil
        app.prepareTailscaleLogin(lineID: lineID) { result in
            Task { @MainActor in
                isRefreshingTailscaleStatus = false
                switch result {
                case .success:
                    continueTailscaleSetupAfterStart()
                case .failure(let error):
                    pendingTailscaleSetupLogin = false
                    tailscaleStatusError = tailscaleErrorMessage(error)
                }
            }
        }
    }

    private func continueTailscaleSetupAfterStart() {
        guard app.canQueryTailscaleRuntime(lineID: lineID) else {
            pendingTailscaleSetupLogin = false
            tailscaleStatusError = app.tr(
                "Tailscale 设置运行时未就绪，请重试。",
                "The Tailscale setup runtime is not ready. Please retry."
            )
            return
        }
        isRefreshingTailscaleStatus = true
        app.refreshTailscaleStatus(lineID: lineID) { result in
            isRefreshingTailscaleStatus = false
            switch result {
            case .failure(let error):
                pendingTailscaleSetupLogin = false
                tailscaleStatusError = tailscaleErrorMessage(error)
            case .success(let status):
                tailscaleRuntimeStatus = status
                guard applyTailscaleAuthenticationStatus(status) else {
                    pendingTailscaleSetupLogin = false
                    return
                }
                if status.backendState.lowercased() == "running" {
                    pendingTailscaleSetupLogin = false
                } else {
                    beginTailscaleLogin()
                }
            }
        }
    }

    private func handlePendingTailscaleSetupState() {
        guard pendingTailscaleSetupLogin, !isRefreshingTailscaleStatus else { return }
        if app.requiresUserAction {
            beginTailscaleLogin()
        } else if app.isConnected {
            pendingTailscaleSetupLogin = false
            refreshTailscaleStatusIfAvailable()
        }
    }

    private func beginTailscaleLogin(fallbackURL: URL? = nil) {
        guard !isRefreshingTailscaleStatus else { return }
        isRefreshingTailscaleStatus = true
        tailscaleStatusError = nil
        app.beginTailscaleLogin(lineID: lineID) { result in
            Task { @MainActor in
                isRefreshingTailscaleStatus = false
                switch result {
                case .success(let status):
                    tailscaleRuntimeStatus = status
                    guard applyTailscaleAuthenticationStatus(status) else {
                        pendingTailscaleSetupLogin = false
                        return
                    }
                    if let url = validTailscaleAuthURL(status.authURL) {
                        pendingTailscaleSetupLogin = false
                        openURL(url)
                    } else if status.backendState.lowercased() == "running" {
                        pendingTailscaleSetupLogin = false
                        refreshTailscaleStatusIfAvailable()
                    } else {
                        tailscaleStatusError = app.tr(
                            "没有取得有效的登录入口，请重试。",
                            "No valid sign-in link was returned. Please retry."
                        )
                    }
                case .failure(let error):
                    pendingTailscaleSetupLogin = false
                    // 旧链接仍可能在控制面有效；先保持用户可继续，再明确展示刷新失败。
                    if let fallbackURL {
                        openURL(fallbackURL)
                    }
                    tailscaleStatusError = tailscaleErrorMessage(error)
                }
            }
        }
    }

    private func tailscaleErrorMessage(_ error: Error) -> String {
        if let runtimeError = error as? TunnelRuntimeError {
            switch runtimeError {
            case .unavailable:
                return app.tr(
                    "请先启动这条 Tailscale 线路的设置。",
                    "Start setup for this Tailscale line first."
                )
            case .missingTarget:
                return app.tr(
                    "这条 Tailscale 线路当前没有可用的设置会话，请重新启动独立设置。",
                    "This Tailscale line has no available setup session. Restart isolated setup."
                )
            default:
                break
            }
        }
        return userFacingConnectionText(error.localizedDescription)
    }

    @discardableResult
    private func applyTailscaleAuthenticationStatus(_ status: TailscaleRuntimeStatus) -> Bool {
        guard app.applyTailscaleRuntimeStatus(lineID: lineID, status: status) else {
            tailscaleStatusError = app.tr(
                "登录状态无法保存，请不要结束设置并重试。",
                "The sign-in state could not be saved. Keep setup open and retry."
            )
            return false
        }
        return true
    }

    private func logoutTailscale() {
        guard !isLoggingOutTailscale, app.tailscaleSetupLineID == lineID else { return }
        isLoggingOutTailscale = true
        tailscaleStatusError = nil
        app.logoutTailscale(lineID: lineID) { result in
            isLoggingOutTailscale = false
            switch result {
            case .failure(let error):
                tailscaleStatusError = tailscaleErrorMessage(error)
            case .success:
                tailscaleRuntimeStatus = nil
                pendingTailscaleSetupLogin = false
                app.finishTailscaleSetup()
            }
        }
    }

    private func validTailscaleAuthURL(_ rawValue: String) -> URL? {
        AppState.validTailscaleAuthURL(rawValue)
    }

    private func tailscaleBackendLabel(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "running":
            return app.tr("已登录", "Signed In")
        case "needslogin", "needs_login":
            return app.tr("需要登录", "Sign-in Required")
        case "needsmachineauth", "needs_machine_auth":
            return app.tr("需要设备授权", "Device Approval Required")
        case "starting":
            return app.tr("正在启动", "Starting")
        case "stopped":
            return app.tr("已停止", "Stopped")
        default:
            return rawValue.isEmpty ? app.tr("未知", "Unknown") : rawValue
        }
    }

    private func tailscaleExitNodeLabel(_ node: TailscaleRuntimeExitNode) -> String {
        let state = node.online ? "" : app.tr(" · 离线", " · Offline")
        return "\(node.name) · \(node.ip)\(state)"
    }

    private var lineIndex: Int? {
        app.profile.lines.firstIndex { $0.id == lineID }
    }

    private func lineBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Line, T>) -> Binding<T> {
        Binding(
            get: { app.profile.lines[index][keyPath: keyPath] },
            set: {
                guard !app.hasActiveTunnel,
                      app.profile.lines.indices.contains(index) else { return }
                app.profile.lines[index][keyPath: keyPath] = $0
                scheduleSave()
            }
        )
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(
            get: { saveFailureMessage != nil },
            set: { if !$0 { saveFailureMessage = nil } }
        )
    }

    private func scheduleSave() {
        guard !app.hasActiveTunnel else { return }
        hasPendingChanges = true
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            pendingSaveTask = nil
            _ = persistPendingChanges()
        }
    }

    @discardableResult
    private func persistPendingChanges() -> Bool {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard hasPendingChanges, let index = lineIndex else { return true }
        guard !app.hasActiveTunnel else { return false }

        let attemptedLine = app.profile.lines[index]
        guard app.save() else {
            if let restoreIndex = lineIndex {
                app.profile.lines[restoreIndex] = attemptedLine
            }
            saveFailureMessage = app.statusText
            return false
        }
        hasPendingChanges = false
        saveFailureMessage = nil
        return true
    }

    private func deleteCurrentLine() {
        guard app.canMutateConfiguration,
              let index = lineIndex, app.profile.lines[index].type != "direct" else { return }
        app.profile.lines.remove(at: index)
        // 模式引用故意保留，避免静默改变路由语义。
        app.save()
        dismiss()
    }
}

private struct RuleEditorView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let ruleSetID: String
    @State private var domainsText = ""
    @State private var cidrsText = ""
    @State private var loadedManualValues = false
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var hasPendingChanges = false
    @State private var saveFailureMessage: String?

    var body: some View {
        Form {
            if let index = ruleIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("名称", "Name"), text: ruleBinding(index, \.name))
                    LabeledContent(
                        app.tr("类型", "Type"),
                        value: app.profile.ruleSets[index].type == "url" ? "URL" : app.tr("手工", "Manual")
                    )
                    Toggle(app.tr("启用", "Enabled"), isOn: ruleBinding(index, \.enabled))
                }

                if app.profile.ruleSets[index].type == "url" {
                    Section(app.tr("远程规则", "Remote Rule")) {
                        TextField("URL", text: ruleBinding(index, \.url), axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker(app.tr("格式", "Format"), selection: ruleBinding(index, \.format)) {
                            Text(app.tr("自动", "Auto")).tag("auto")
                            Text("sing-box .srs").tag("srs")
                            Text("sing-box .json").tag("json")
                            Text(app.tr("纯文本列表", "Plain text list")).tag("text")
                        }
                    }
                } else {
                    Section(app.tr("域名（每行一个）", "Domains (one per line)")) {
                        TextEditor(text: $domainsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section(app.tr("IP CIDR（每行一个）", "IP CIDRs (one per line)")) {
                        TextEditor(text: $cidrsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if isConnectivityTestRule {
                    Section {
                        Label(
                            app.tr("分别验证 Direct 与当前模式选中的非 Direct 出口绑定。", "Verifies the Direct route and the selected non-Direct route independently."),
                            systemImage: "checkmark.shield"
                        )
                    } footer: {
                        Text(app.tr("这是配置中可见的连接验收规则，不是生成器隐藏路由。", "This visible configuration rule is used for connection acceptance; it is not a hidden generated route."))
                    }
                } else {
                    Section {
                        Button(app.tr("删除规则", "Delete Rule"), role: .destructive) {
                            deleteCurrentRule()
                        }
                    }
                }
            } else {
                ContentUnavailableView(app.tr("规则已删除", "Rule deleted"), systemImage: "trash")
            }
        }
        .navigationTitle(app.tr("编辑规则", "Edit Rule"))
        .disabled(app.hasActiveTunnel || app.isBusy || isConnectivityTestRule)
        .onAppear { loadManualValues() }
        .onChange(of: domainsText) { _, _ in manualValuesDidChange() }
        .onChange(of: cidrsText) { _, _ in manualValuesDidChange() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { _ = persistRuleChanges() }
        }
        .onDisappear {
            _ = persistRuleChanges()
        }
        .alert(app.tr("保存失败", "Save Failed"), isPresented: saveFailurePresented) {
            Button(app.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(saveFailureMessage ?? app.tr(
                "无法保存规则，请重试。",
                "Could not save the rule. Please try again."
            ))
        }
    }

    private var ruleIndex: Int? {
        app.profile.ruleSets.firstIndex { $0.id == ruleSetID }
    }

    private var isConnectivityTestRule: Bool {
        ruleSetID == RuleSet.connectivityDirectID || ruleSetID == RuleSet.connectivityAnyConnectID
    }

    private func ruleBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<RuleSet, T>) -> Binding<T> {
        Binding(
            get: { app.profile.ruleSets[index][keyPath: keyPath] },
            set: {
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                app.profile.ruleSets[index][keyPath: keyPath] = $0
                scheduleRuleSave()
            }
        )
    }

    private func loadManualValues() {
        guard !loadedManualValues,
              let index = ruleIndex,
              app.profile.ruleSets[index].type == "manual" else { return }
        domainsText = app.profile.ruleSets[index].domains.joined(separator: "\n")
        cidrsText = app.profile.ruleSets[index].cidrs.joined(separator: "\n")
        loadedManualValues = true
    }

    @discardableResult
    private func saveManualValuesIfLoaded() -> Bool {
        guard app.canMutateConfiguration,
              loadedManualValues, let index = ruleIndex else { return false }
        let domains = values(from: domainsText)
        let cidrs = values(from: cidrsText)
        guard app.profile.ruleSets[index].domains != domains
                || app.profile.ruleSets[index].cidrs != cidrs else { return false }
        app.profile.ruleSets[index].domains = domains
        app.profile.ruleSets[index].cidrs = cidrs
        return true
    }

    private func manualValuesDidChange() {
        guard saveManualValuesIfLoaded() else { return }
        scheduleRuleSave()
    }

    private func scheduleRuleSave() {
        guard app.canMutateConfiguration else { return }
        hasPendingChanges = true
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            pendingSaveTask = nil
            _ = persistRuleChanges()
        }
    }

    @discardableResult
    private func persistRuleChanges() -> Bool {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        if saveManualValuesIfLoaded() {
            hasPendingChanges = true
        }
        guard hasPendingChanges else { return true }
        guard app.canMutateConfiguration else { return false }
        guard app.save() else {
            saveFailureMessage = app.statusText
            reloadManualValuesFromProfile()
            return false
        }
        hasPendingChanges = false
        saveFailureMessage = nil
        return true
    }

    private func reloadManualValuesFromProfile() {
        guard let index = ruleIndex,
              app.profile.ruleSets[index].type == "manual" else { return }
        loadedManualValues = false
        domainsText = app.profile.ruleSets[index].domains.joined(separator: "\n")
        cidrsText = app.profile.ruleSets[index].cidrs.joined(separator: "\n")
        loadedManualValues = true
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(
            get: { saveFailureMessage != nil },
            set: { if !$0 { saveFailureMessage = nil } }
        )
    }

    private func values(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func deleteCurrentRule() {
        guard app.canMutateConfiguration, let index = ruleIndex else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        let id = app.profile.ruleSets[index].id
        app.profile.ruleSets.remove(at: index)
        for modeIndex in app.profile.modes.indices {
            app.profile.modes[modeIndex].bindings.removeAll { $0.ruleSetID == id }
        }
        app.save()
        dismiss()
    }
}

private struct SubscriptionEditorView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let subscriptionID: String
    @State private var refreshing = false
    @State private var operationError: String?
    @State private var testingNodeIDs: Set<String> = []
    @State private var nodeDelays: [String: Int] = [:]
    @State private var probingAddressNodeIDs: Set<String> = []
    @State private var nodeAddresses: [String: String] = [:]

    var body: some View {
        Form {
            if let index = subscriptionIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("名称", "Name"), text: subscriptionBinding(index, \.name))
                    Toggle(app.tr("启用", "Enabled"), isOn: subscriptionBinding(index, \.enabled))
                    Picker(app.tr("格式", "Format"), selection: subscriptionBinding(index, \.format)) {
                        Text(app.tr("自动识别", "Auto detect")).tag("auto")
                        Text("Clash").tag("clash")
                        Text("Surge").tag("surge")
                        Text("Base64").tag("base64")
                    }
                    if app.profile.subscriptions[index].proxyGroups.isEmpty {
                        Picker(app.tr("策略", "Strategy"), selection: subscriptionBinding(index, \.strategy)) {
                            Text(app.tr("自动选优", "Auto Best")).tag("urltest")
                            Text(app.tr("手动选择", "Manual Select")).tag("selector")
                        }
                    } else {
                        LabeledContent(
                            app.tr("策略", "Strategy"),
                            value: app.tr("使用导入的策略组", "Using Imported Policy Groups")
                        )
                    }
                }
                .disabled(app.hasActiveTunnel || app.isBusy)

                Section {
                    if app.profile.subscriptions[index].url.isEmpty {
                        Label(
                            app.tr("此订阅来自本地文件；修改节点请重新导入。", "This subscription came from a local file; re-import it to update nodes."),
                            systemImage: "doc"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        TextField(
                            app.tr("订阅 URL", "Subscription URL"),
                            text: subscriptionBinding(index, \.url),
                            axis: .vertical
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            refresh(index: index)
                        } label: {
                            if refreshing {
                                HStack {
                                    ProgressView()
                                    Text(app.tr("正在刷新…", "Refreshing…"))
                                }
                            } else {
                                Label(app.tr("刷新并重新解析", "Refresh and Reparse"), systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(
                            app.hasActiveTunnel
                                || app.isBusy
                                || refreshing
                                || app.profile.subscriptions[index].url
                                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                } header: {
                    Text(app.tr("来源", "Source"))
                } footer: {
                    if app.profile.subscriptions[index].updatedAt > 0 {
                        Text(app.tr("最近更新：", "Last updated: ") + formattedDate(app.profile.subscriptions[index].updatedAt))
                    }
                }
                .disabled(app.hasActiveTunnel || app.isBusy)

                if let operationError {
                    Section {
                        Label(operationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if !app.profile.subscriptions[index].proxyGroups.isEmpty {
                    Section {
                        ForEach(Array(app.profile.subscriptions[index].proxyGroups.indices), id: \.self) { groupIndex in
                            let group = app.profile.subscriptions[index].proxyGroups[groupIndex]
                            if ["select", "selector"].contains(group.type.lowercased()) {
                                Picker(group.name, selection: groupSelectionBinding(index, groupIndex: groupIndex)) {
                                    ForEach(group.proxies, id: \.self) { member in
                                        Text(member).tag(member)
                                    }
                                }
                                .disabled(
                                    group.proxies.isEmpty
                                        || app.isBusy
                                        || (app.hasActiveTunnel && !app.isConnected)
                                )
                            } else {
                                LabeledContent(group.name, value: app.tr("自动选优", "Auto Best"))
                            }
                        }
                    } header: {
                        Text(app.tr("策略组", "Policy Groups"))
                    } footer: {
                        Text(app.tr(
                            "手动组在连接期间立即切换；自动组根据节点探测结果选优。",
                            "Manual groups switch immediately while connected; automatic groups choose from probe results."
                        ))
                    }
                } else if app.profile.subscriptions[index].strategy == "selector" {
                    Section {
                        Picker(
                            app.tr("当前节点", "Current Node"),
                            selection: defaultSelectionBinding(index)
                        ) {
                            ForEach(app.profile.subscriptions[index].lines, id: \.name) { line in
                                Text(line.name).tag(line.name)
                            }
                        }
                        .disabled(
                            app.profile.subscriptions[index].lines.isEmpty
                                || app.isBusy
                                || (app.hasActiveTunnel && !app.isConnected)
                        )
                    } header: {
                        Text(app.tr("手动选择", "Manual Selection"))
                    } footer: {
                        Text(app.tr(
                            "连接期间选择会立即应用，并保存为下次连接的默认节点。",
                            "Selections apply immediately while connected and become the default for the next connection."
                        ))
                    }
                }

                Section {
                    if app.profile.subscriptions[index].lines.isEmpty {
                        Text(app.tr("没有可用节点", "No available nodes"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.profile.subscriptions[index].lines) { line in
                            HStack(spacing: 10) {
                                Label(line.name, systemImage: lineSymbol(line.type))
                                Spacer()
                                if testingNodeIDs.contains(line.id) || probingAddressNodeIDs.contains(line.id) {
                                    ProgressView()
                                } else {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let delay = nodeDelays[line.id] {
                                            Text("\(delay) ms")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(delayColor(delay))
                                        } else {
                                            Text(mobileLineTypeLabel(line.type))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let address = nodeAddresses[line.id] {
                                            Text(address)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Button {
                                    testNode(line.id)
                                } label: {
                                    Image(systemName: "speedometer")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(app.tr("测试节点", "Test node"))
                                .disabled(!app.isConnected || testingNodeIDs.contains(line.id))
                                Button {
                                    probeNodeAddress(line.id)
                                } label: {
                                    Image(systemName: "globe.americas")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(app.tr("确认出口 IP", "Check exit IP"))
                                .disabled(!app.isConnected || probingAddressNodeIDs.contains(line.id))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(app.tr("节点", "Nodes"))
                        Spacer()
                        if !app.profile.subscriptions[index].lines.isEmpty {
                            Button(app.tr("全部测试", "Test All")) {
                                testAllNodes(index: index)
                            }
                            .disabled(!app.isConnected || !testingNodeIDs.isEmpty)
                        }
                    }
                } footer: {
                    if !app.isConnected {
                        Text(app.tr("连接后可测试每条节点的真实往返延迟。", "Connect to test the real round-trip latency of each node."))
                    }
                }

                Section(app.tr("规则", "Rules")) {
                    LabeledContent(app.tr("规则数量", "Rule count"), value: "\(app.profile.subscriptions[index].rules.count)")
                    LabeledContent(app.tr("节点数量", "Node count"), value: "\(app.profile.subscriptions[index].lines.count)")
                    LabeledContent(app.tr("策略组数量", "Group count"), value: "\(app.profile.subscriptions[index].proxyGroups.count)")
                }

                Section {
                    Button(app.tr("删除订阅", "Delete Subscription"), role: .destructive) {
                        app.deleteSubscription(subscriptionID)
                        dismiss()
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                }
            } else {
                ContentUnavailableView(app.tr("订阅已删除", "Subscription deleted"), systemImage: "trash")
            }
        }
        .navigationTitle(app.tr("编辑订阅", "Edit Subscription"))
    }

    private var subscriptionIndex: Int? {
        app.profile.subscriptions.firstIndex { $0.id == subscriptionID }
    }

    private func subscriptionBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Subscription, T>) -> Binding<T> {
        Binding(
            get: { app.profile.subscriptions[index][keyPath: keyPath] },
            set: {
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                app.profile.subscriptions[index][keyPath: keyPath] = $0
                app.save()
            }
        )
    }

    private func groupSelectionBinding(_ subscriptionIndex: Int, groupIndex: Int) -> Binding<String> {
        Binding(
            get: {
                let group = app.profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex]
                if group.proxies.contains(group.selected) { return group.selected }
                return group.proxies.first ?? ""
            },
            set: { selected in
                guard !app.isBusy, !app.hasActiveTunnel || app.isConnected else { return }
                let groupName = app.profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].name
                app.selectSubscriptionMember(
                    subscriptionID: subscriptionID,
                    groupName: groupName,
                    selected: selected
                ) { result in
                    if case .failure(let error) = result {
                        operationError = userFacingConnectionText(error.localizedDescription)
                    } else {
                        operationError = nil
                    }
                }
            }
        )
    }

    private func defaultSelectionBinding(_ subscriptionIndex: Int) -> Binding<String> {
        Binding(
            get: {
                let subscription = app.profile.subscriptions[subscriptionIndex]
                if subscription.lines.contains(where: { $0.name == subscription.selected }) {
                    return subscription.selected
                }
                return subscription.lines.first?.name ?? ""
            },
            set: { selected in
                guard !app.isBusy, !app.hasActiveTunnel || app.isConnected else { return }
                app.selectSubscriptionMember(
                    subscriptionID: subscriptionID,
                    groupName: "__default__",
                    selected: selected
                ) { result in
                    if case .failure(let error) = result {
                        operationError = userFacingConnectionText(error.localizedDescription)
                    } else {
                        operationError = nil
                    }
                }
            }
        )
    }

    private func testNode(_ nodeID: String) {
        guard !testingNodeIDs.contains(nodeID) else { return }
        testingNodeIDs.insert(nodeID)
        nodeDelays.removeValue(forKey: nodeID)
        app.testSubscriptionNode(subscriptionID: subscriptionID, nodeID: nodeID) { result in
            testingNodeIDs.remove(nodeID)
            switch result {
            case .success(let delay):
                nodeDelays[nodeID] = delay
            case .failure(let error):
                operationError = userFacingConnectionText(error.localizedDescription)
            }
        }
    }

    private func probeNodeAddress(_ nodeID: String) {
        guard !probingAddressNodeIDs.contains(nodeID) else { return }
        probingAddressNodeIDs.insert(nodeID)
        nodeAddresses.removeValue(forKey: nodeID)
        app.probeSubscriptionNodeAddress(subscriptionID: subscriptionID, nodeID: nodeID) { result in
            probingAddressNodeIDs.remove(nodeID)
            switch result {
            case .success(let address):
                nodeAddresses[nodeID] = address
            case .failure(let error):
                operationError = userFacingConnectionText(error.localizedDescription)
            }
        }
    }

    private func testAllNodes(index: Int) {
        operationError = nil
        nodeDelays = [:]
        for line in app.profile.subscriptions[index].lines {
            testNode(line.id)
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 180 { return .green }
        if delay < 450 { return .orange }
        return .red
    }

    private func refresh(index: Int) {
        guard app.canMutateConfiguration, !refreshing else { return }
        let subscription = app.profile.subscriptions[index]
        let engine = (app.engine as? GoEngine) ?? GoEngine.shared
        refreshing = true
        operationError = nil
        engine.parseSubscription(url: subscription.url, format: subscription.format) { result in
            refreshing = false
            switch result {
            case .success(let parsed):
                app.updateSubscription(subscriptionID, with: parsed)
            case .failure(let error):
                operationError = MobileDiagnosticsService.redacted(error.localizedDescription, using: app.profile)
                    ?? app.tr("订阅刷新失败", "Subscription refresh failed")
            }
        }
    }

    private func formattedDate(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AddSubscriptionView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var format = "auto"
    @State private var strategy = "urltest"
    @State private var parsing = false
    @State private var parsedResult: ParseResult?
    @State private var parseError: String?
    @State private var localFileContent = ""
    @State private var localFileName = ""
    @State private var isImportingFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section(app.tr("订阅信息", "Subscription")) {
                    TextField(app.tr("名称（可选）", "Name (optional)"), text: $name)
                    if localFileContent.isEmpty {
                        TextField(app.tr("订阅 URL", "Subscription URL"), text: $url, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(parsing)
                    } else {
                        Label(localFileName, systemImage: "doc")
                        Button(app.tr("改用 URL", "Use URL Instead")) {
                            localFileContent = ""
                            localFileName = ""
                            resetParsedResult()
                        }
                        .disabled(parsing)
                    }

                    Button {
                        isImportingFile = true
                    } label: {
                        Label(app.tr("选择本地文件", "Choose Local File"), systemImage: "folder")
                    }
                    .disabled(parsing)
                    Picker(app.tr("格式", "Format"), selection: $format) {
                        Text(app.tr("自动识别", "Auto detect")).tag("auto")
                        Text("Clash").tag("clash")
                        Text("Surge").tag("surge")
                        Text("Base64").tag("base64")
                    }
                    .disabled(parsing)
                    Picker(app.tr("策略", "Strategy"), selection: $strategy) {
                        Text(app.tr("自动选优", "Auto Best")).tag("urltest")
                        Text(app.tr("手动选择", "Manual Select")).tag("selector")
                    }
                }

                if parsing {
                    Section {
                        HStack {
                            ProgressView()
                            Text(app.tr("正在解析订阅…", "Parsing subscription…"))
                        }
                    }
                }

                if let error = parseError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if let result = parsedResult {
                    Section(app.tr("解析结果", "Parsed Result")) {
                        Text(app.tr(
                            "\(result.lines.count) 个节点 · \(result.proxyGroups?.count ?? 0) 个策略组 · \(result.rules?.count ?? 0) 条规则",
                            "\(result.lines.count) nodes · \(result.proxyGroups?.count ?? 0) groups · \(result.rules?.count ?? 0) rules"
                        ))
                        ForEach(Array(result.lines.prefix(8))) { line in
                            LabeledContent(line.name, value: mobileLineTypeLabel(line.type))
                        }
                        if result.lines.count > 8 {
                            Text(app.tr("另有 \(result.lines.count - 8) 个节点", "\(result.lines.count - 8) more nodes"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(app.tr("添加订阅", "Add Subscription"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(app.tr("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if parsedResult == nil {
                        Button(app.tr("解析", "Parse")) { parse() }
                            .disabled((url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && localFileContent.isEmpty) || parsing)
                    } else {
                        Button(app.tr("添加", "Add")) { addParsedSubscription() }
                    }
                }
            }
            .onChange(of: url) { _, _ in resetParsedResult() }
            .onChange(of: format) { _, _ in resetParsedResult() }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.plainText, .data],
                allowsMultipleSelection: false,
                onCompletion: handleImportedFile
            )
        }
        .presentationDetents([.medium, .large])
    }

    private func parse() {
        let engine = (app.engine as? GoEngine) ?? GoEngine.shared
        let requestedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedFormat = format
        let requestedContent = localFileContent

        parsing = true
        parseError = nil
        parsedResult = nil
        engine.parseSubscription(
            url: requestedURL,
            content: requestedContent,
            format: requestedFormat
        ) { result in
            parsing = false
            guard requestedURL == url.trimmingCharacters(in: .whitespacesAndNewlines),
                  requestedContent == localFileContent,
                  requestedFormat == format else { return }
            switch result {
            case .success(let parsed):
                parsedResult = parsed
            case .failure(let error):
                parseError = MobileDiagnosticsService.redacted(error.localizedDescription, using: app.profile)
                    ?? app.tr("订阅解析失败", "Subscription parsing failed")
            }
        }
    }

    private func addParsedSubscription() {
        guard let result = parsedResult else { return }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileFallback = (localFileName as NSString).deletingPathExtension
        let fallbackName = URL(string: trimmedURL)?.host
            ?? (fileFallback.isEmpty ? app.tr("订阅", "Subscription") : fileFallback)
        app.addSubscription(
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            url: trimmedURL,
            format: format,
            strategy: strategy,
            lines: result.lines,
            proxyGroups: result.proxyGroups ?? [],
            rules: result.rules ?? []
        )
        dismiss()
    }

    private func resetParsedResult() {
        guard !parsing else { return }
        parsedResult = nil
        parseError = nil
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            parseError = error.localizedDescription
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { fileURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      (values.fileSize ?? 0) <= 1_024 * 1_024 else {
                    throw SubscriptionImportError.fileTooLarge
                }
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard data.count <= 1_024 * 1_024,
                      let content = String(data: data, encoding: .utf8) else {
                    throw SubscriptionImportError.invalidText
                }
                localFileContent = content
                localFileName = fileURL.lastPathComponent
                url = ""
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = (fileURL.lastPathComponent as NSString).deletingPathExtension
                }
                resetParsedResult()
            } catch {
                parseError = error.localizedDescription
            }
        }
    }
}

private enum SubscriptionImportError: LocalizedError {
    case fileTooLarge
    case invalidText

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The selected subscription file exceeds the 1 MB limit."
        case .invalidText:
            return "The selected subscription is not a valid UTF-8 text file."
        }
    }
}

func mobileLineTypeLabel(_ type: String) -> String {
    switch type {
    case "direct": return "Direct"
    case "vpn": return "AnyConnect"
    case "trojan": return "Trojan"
    case "shadowsocks", "ss": return "Shadowsocks"
    case "vmess": return "VMess"
    case "tailscale": return "Tailscale"
    default: return type
    }
}
