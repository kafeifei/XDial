import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("出口").tag(0)
                Text("规则").tag(1)
                Text("策略组").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            ZStack {
                if tab == 0 { ExitsTab() }
                else if tab == 1 { RulesTab() }
                else { StrategiesTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 480)
    }
}

// MARK: - 出口 Tab

struct ExitsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.exits) { $exit in
                        ExitRow(exit: $exit, onDelete: { delete(exit) })
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
                } label: {
                    Label("添加出口", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
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
        state.profile.exits.append(Exit(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ exit: Exit) {
        if exit.type == "direct" { return }
        state.profile.exits.removeAll { $0.id == exit.id }
        state.save()
    }
}

struct ExitRow: View {
    @SwiftUI.Binding var exit: Exit
    var onDelete: () -> Void
    @State private var expanded = false
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .onTapGesture { expanded.toggle() }
                TextField("名称", text: $exit.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onChange(of: exit.name) { _, _ in state.save() }
                Spacer()
                Text(typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if exit.type != "direct" {
                    Toggle("", isOn: $exit.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: exit.enabled) { _, _ in state.save() }
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded && exit.type != "direct" {
                detailFields
                    .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private var typeLabel: String {
        switch exit.type {
        case "direct": return "直连"
        case "vpn": return "VPN"
        case "trojan": return "Trojan"
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        default: return exit.type
        }
    }

    @ViewBuilder
    private var detailFields: some View {
        switch exit.type {
        case "vpn":
            field("服务器", $exit.vpnServer, placeholder: "vpn.example.com:8443")
            field("用户名", $exit.vpnUsername)
            secureField("密码", $exit.vpnPassword)
        case "trojan":
            field("服务器", $exit.trojanServer)
            intField("端口", $exit.trojanPort)
            field("SNI", $exit.trojanSNI)
            secureField("密码", $exit.trojanPassword)
        case "shadowsocks":
            field("服务器", $exit.ssServer)
            intField("端口", $exit.ssPort)
            field("加密方法", $exit.ssMethod)
            secureField("密码", $exit.ssPassword)
        case "vmess":
            field("服务器", $exit.vmessServer)
            intField("端口", $exit.vmessPort)
            secureField("UUID", $exit.vmessUUID)
            intField("Alter ID", $exit.vmessAltID)
        default:
            EmptyView()
        }
    }

    private func field(_ label: String, _ binding: SwiftUI.Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in state.save() }
        }
    }

    private func secureField(_ label: String, _ binding: SwiftUI.Binding<String>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            SecureField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in state.save() }
        }
    }

    private func intField(_ label: String, _ binding: SwiftUI.Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in state.save() }
        }
    }
}

// MARK: - 规则 Tab

struct RulesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.rules) { $rule in
                        RuleRow(rule: $rule, onDelete: { delete(rule) })
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Spacer()
                Menu {
                    Button("URL 规则") { add(type: "url") }
                    Button("手动域名/IP") { add(type: "manual") }
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
    }

    private func add(type: String) {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        let name = type == "url" ? "新 URL 规则" : "新手动规则"
        state.profile.rules.append(Rule(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ rule: Rule) {
        state.profile.rules.removeAll { $0.id == rule.id }
        for i in state.profile.strategies.indices {
            state.profile.strategies[i].bindings.removeAll { $0.ruleID == rule.id }
        }
        state.save()
    }
}

struct RuleRow: View {
    @SwiftUI.Binding var rule: Rule
    var onDelete: () -> Void
    @State private var expanded = true
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .onTapGesture { expanded.toggle() }
                TextField("名称", text: $rule.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onChange(of: rule.name) { _, _ in state.save() }
                Spacer()
                Text(rule.type == "url" ? "URL" : "手动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: rule.enabled) { _, _ in state.save() }
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                if rule.type == "url" {
                    urlFields
                } else {
                    manualFields
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                TextField("https://...", text: $rule.url)
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
                TextEditor(text: SwiftUI.Binding(
                    get: { rule.domains.joined(separator: "\n") },
                    set: {
                        rule.domains = $0.split(whereSeparator: \.isNewline)
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        state.save()
                    }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .border(Color.gray.opacity(0.3))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("IP CIDR（每行一个）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: SwiftUI.Binding(
                    get: { rule.cidrs.joined(separator: "\n") },
                    set: {
                        rule.cidrs = $0.split(whereSeparator: \.isNewline)
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        state.save()
                    }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 50)
                .border(Color.gray.opacity(0.3))
            }
        }
        .padding(.leading, 18)
    }
}

// MARK: - 策略组 Tab

struct StrategiesTab: View {
    @EnvironmentObject var state: AppState
    @State private var showTemplate = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if state.profile.strategies.isEmpty {
                    Text("还没有策略组")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("当前编辑", selection: SwiftUI.Binding(
                        get: { state.profile.activeStrategyID },
                        set: { state.profile.activeStrategyID = $0; state.save() }
                    )) {
                        ForEach(state.profile.strategies) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
                Spacer()
                Button {
                    showTemplate = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .popover(isPresented: $showTemplate) {
                    templatePicker
                }
            }
            .padding(10)

            Divider()

            if let idx = state.profile.strategies.firstIndex(where: { $0.id == state.profile.activeStrategyID }) {
                StrategyEditor(strategy: $state.profile.strategies[idx])
            } else {
                Spacer()
                Text("点击「新建」创建策略组")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("从模板创建").font(.headline)
            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)
            ForEach(StrategyTemplate.allCases, id: \.self) { t in
                Button {
                    let name = newName.isEmpty ? t.displayName : newName
                    state.createStrategy(from: t, named: name)
                    newName = ""
                    showTemplate = false
                } label: {
                    HStack {
                        Text(t.displayName)
                        Spacer()
                        Text(templateDescription(t))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func templateDescription(_ t: StrategyTemplate) -> String {
        switch t {
        case .overseas: return "规则→VPN，其他→直连"
        case .domestic: return "规则+GFW→VPN，其他→直连"
        case .domesticSS: return "规则→VPN，GFW→SS，其他→直连"
        case .blank: return "空白"
        }
    }
}

struct StrategyEditor: View {
    @SwiftUI.Binding var strategy: Strategy
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $strategy.name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: strategy.name) { _, _ in state.save() }
                Spacer()
                Button {
                    state.deleteStrategy(strategy)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("规则").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text("出口").font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(strategy.bindings) { binding in
                        bindingRow(binding)
                    }

                    Divider()

                    HStack {
                        Text("其他流量")
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        exitPicker(selectedID: SwiftUI.Binding(
                            get: { strategy.defaultExitID },
                            set: { strategy.defaultExitID = $0; state.save() }
                        ))
                    }
                }
                .padding(10)
            }

            Divider()

            HStack {
                Spacer()
                Menu {
                    let usedIDs = Set(strategy.bindings.map { $0.ruleID })
                    let available = state.profile.rules.filter { !usedIDs.contains($0.id) }
                    if available.isEmpty {
                        Button("（无可用规则）") {}.disabled(true)
                    } else {
                        ForEach(available) { rule in
                            Button(rule.name) {
                                let firstExit = state.profile.exits.first?.id ?? ""
                                strategy.bindings.append(RouteBinding(ruleID: rule.id, exitID: firstExit))
                                state.save()
                            }
                        }
                    }
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func bindingRow(_ binding: RouteBinding) -> some View {
        if let idx = strategy.bindings.firstIndex(where: { $0.ruleID == binding.ruleID }) {
            HStack {
                Text(state.profile.rules.first(where: { $0.id == binding.ruleID })?.name ?? "（已删除）")
                    .frame(width: 200, alignment: .leading)
                exitPicker(selectedID: $strategy.bindings[idx].exitID)
                Button {
                    strategy.bindings.removeAll { $0.ruleID == binding.ruleID }
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
            ForEach(state.profile.exits.filter { $0.enabled }) { e in
                Text(e.name).tag(e.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: selectedID.wrappedValue) { _, _ in state.save() }
    }
}
