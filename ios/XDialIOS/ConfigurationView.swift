import SwiftUI

struct ConfigurationView: View {
    @EnvironmentObject private var app: AppState
    @State private var section: ConfigSection = .lines

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

                switch section {
                case .lines: lineList
                case .rules: ruleList
                case .subscriptions: subscriptionList
                }
            }
            .navigationTitle(app.tr("配置", "Configuration"))
            .toolbar {
                if section == .lines {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            addLineButton(type: "vpn", name: "AnyConnect")
                            addLineButton(type: "trojan", name: "Trojan")
                            addLineButton(type: "shadowsocks", name: "Shadowsocks")
                            addLineButton(type: "vmess", name: "VMess")
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
    }

    private var lineList: some View {
        List(app.profile.lines) { line in
            NavigationLink {
                LineEditorView(lineID: line.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: lineSymbol(line.type))
                        .foregroundStyle(line.type == "tailscale" ? Color.orange : Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.name)
                        Text(mobileLineTypeLabel(line.type))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !line.enabled {
                        Text(app.tr("停用", "Off"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var ruleList: some View {
        List {
            ForEach(app.profile.ruleSets) { ruleSet in
                Button {
                    guard let index = app.profile.ruleSets.firstIndex(where: { $0.id == ruleSet.id }) else { return }
                    app.profile.ruleSets[index].enabled.toggle()
                    app.save()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ruleSet.name).foregroundStyle(.primary)
                            Text(ruleSet.type == "url" ? ruleSet.url : app.tr("手工规则", "Manual rules"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: ruleSet.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(ruleSet.enabled ? .green : .secondary)
                    }
                }
            }
        }
    }

    private var subscriptionList: some View {
        List {
            if app.profile.subscriptions.isEmpty {
                ContentUnavailableView(
                    app.tr("暂无订阅", "No subscriptions"),
                    systemImage: "link",
                    description: Text(app.tr("订阅解析将在下一阶段接入移动扩展。",
                                             "Subscription parsing will be added to the mobile extension next."))
                )
            } else {
                ForEach(app.profile.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscription.name)
                        Text(app.tr("\(subscription.lines.count) 条线路", "\(subscription.lines.count) lines"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func addLineButton(type: String, name: String) -> some View {
        Button(name) {
            let id = "line-" + String(UUID().uuidString.prefix(8)).lowercased()
            app.profile.lines.append(Line(id: id, name: name, type: type))
            app.save()
        }
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
    let lineID: String

    var body: some View {
        Form {
            if let index = lineIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("名称", "Name"), text: lineBinding(index, \.name))
                    LabeledContent(app.tr("类型", "Type"), value: mobileLineTypeLabel(app.profile.lines[index].type))
                    Toggle(app.tr("启用", "Enabled"), isOn: lineBinding(index, \.enabled))
                }

                fields(for: index)

                if app.profile.lines[index].type != "direct" && app.profile.lines[index].type != "tailscale" {
                    Section {
                        Toggle(app.tr("允许不安全证书", "Allow insecure certificate"),
                               isOn: lineBinding(index, \.allowInsecure))
                    }
                }

                Section {
                    Button(app.tr("保存", "Save")) { app.save() }
                }
            }
        }
        .navigationTitle(app.tr("线路", "Line"))
        .onDisappear { app.save() }
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
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.trojanPort), format: .number)
                    .keyboardType(.numberPad)
                SecureField(app.tr("密码", "Password"), text: lineBinding(index, \.trojanPassword))
                TextField("SNI", text: lineBinding(index, \.trojanSNI))
            }
        case "shadowsocks", "ss":
            Section("Shadowsocks") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.ssServer))
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.ssPort), format: .number)
                    .keyboardType(.numberPad)
                TextField(app.tr("加密方法", "Method"), text: lineBinding(index, \.ssMethod))
                SecureField(app.tr("密码", "Password"), text: lineBinding(index, \.ssPassword))
            }
        case "vmess":
            Section("VMess") {
                TextField(app.tr("服务器", "Server"), text: lineBinding(index, \.vmessServer))
                TextField(app.tr("端口", "Port"), value: lineBinding(index, \.vmessPort), format: .number)
                    .keyboardType(.numberPad)
                SecureField("UUID", text: lineBinding(index, \.vmessUUID))
            }
        case "tailscale":
            Section {
                Label(app.tr("移动端 Tailscale 数据面尚未启用。现有配置会被保留，但不会用于连接。",
                             "The mobile Tailscale data plane is not enabled yet. Existing settings are preserved but not used."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        default:
            EmptyView()
        }
    }

    private var lineIndex: Int? {
        app.profile.lines.firstIndex { $0.id == lineID }
    }

    private func lineBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Line, T>) -> Binding<T> {
        Binding(
            get: { app.profile.lines[index][keyPath: keyPath] },
            set: { app.profile.lines[index][keyPath: keyPath] = $0 }
        )
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
