import SwiftUI

struct ModesView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.profile.modes) { mode in
                    NavigationLink {
                        ModeDetailView(modeID: mode.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.id == app.profile.activeModeID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(mode.id == app.profile.activeModeID ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.name)
                                Text(modeSummary(mode))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            guard app.canMutateConfiguration else { return }
                            app.profile.activeModeID = mode.id
                            app.save()
                        } label: {
                            Label(app.tr("使用", "Use"), systemImage: "checkmark")
                        }
                        .tint(.green)
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            app.deleteMode(mode)
                        } label: {
                            Label(app.tr("删除", "Delete"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
            }
            .overlay {
                if app.profile.modes.isEmpty {
                    ContentUnavailableView(
                        app.tr("暂无模式", "No modes"),
                        systemImage: "shuffle",
                        description: Text(app.tr("点击右上角从模板新建模式。", "Create a mode from a template."))
                    )
                }
            }
            .navigationTitle(app.tr("模式", "Modes"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(ModeTemplate.allCases, id: \.self) { template in
                            Button(templateName(template)) {
                                app.createMode(from: template, named: templateName(template))
                            }
                            .disabled(!app.canCreateMode(from: template)
                                || app.hasActiveTunnel || app.isBusy)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(app.tr("添加模式", "Add mode"))
                    .disabled(!app.canMutateConfiguration || app.hasActiveTunnel || app.isBusy)
                }
            }
        }
    }

    private func modeSummary(_ mode: Mode) -> String {
        let defaultName: String
        if !mode.defaultSubscriptionID.isEmpty {
            defaultName = app.profile.subscriptions.first { $0.id == mode.defaultSubscriptionID }?.name
                ?? app.tr("订阅已删除", "Missing subscription")
        } else if !mode.defaultLineID.isEmpty {
            defaultName = app.profile.lines.first { $0.id == mode.defaultLineID }?.name
                ?? app.tr("线路已删除", "Missing line")
        } else {
            defaultName = app.tr("未设置出口", "No default route")
        }
        return app.tr(
            "默认：\(defaultName) · \(mode.bindings.count) 条规则",
            "Default: \(defaultName) · \(mode.bindings.count) rules"
        )
    }

    private func templateName(_ template: ModeTemplate) -> String {
        switch template {
        case .overseas: return app.tr("海外", "Overseas")
        case .domestic: return app.tr("国内", "Domestic")
        case .domesticSS: return app.tr("国内 + SS", "Domestic + SS")
        case .blank: return app.tr("空白模式", "Blank Mode")
        }
    }
}

private struct ModeDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let modeID: String

    var body: some View {
        Form {
            if let index = modeIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("模式名称", "Mode name"), text: modeBinding(index, \.name))

                    Picker(app.tr("默认出口", "Default route"), selection: defaultTarget(index)) {
                        targetOptions(
                            selectedTargetID: targetID(
                                lineID: app.profile.modes[index].defaultLineID,
                                subscriptionID: app.profile.modes[index].defaultSubscriptionID
                            ),
                            includeDefault: false
                        )
                    }
                }
                .disabled(app.hasActiveTunnel || app.isBusy)

                Section {
                    if app.profile.ruleSets.isEmpty {
                        Text(app.tr("暂无规则集", "No rule sets"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.profile.ruleSets) { ruleSet in
                            Picker(selection: bindingTarget(index, ruleSetID: ruleSet.id)) {
                                targetOptions(
                                    selectedTargetID: currentBindingTarget(index, ruleSetID: ruleSet.id),
                                    includeDefault: true,
                                    ruleSetID: ruleSet.id
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    if ruleSet.isConnectivityTestRule {
                                        Image(systemName: "lock.shield.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text(ruleSet.name)
                                    if !ruleSet.enabled {
                                        Text(app.tr("停用", "Off"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(ruleSet.isConnectivityTestRule)
                        }
                    }
                } header: {
                    Text(app.tr("分流绑定", "Rule bindings"))
                } footer: {
                    Text(app.tr(
                        "带锁规则会明确显示 1.0.0.1 的 Direct 绑定，以及 1.1.1.1 选中的非 Direct 验收出口；单出口模式不执行双出口分流验收。",
                        "Locked rules explicitly show the Direct binding for 1.0.0.1 and the selected non-Direct acceptance route for 1.1.1.1. Dual-route verification is not run in single-route modes."
                    ))
                }
                .disabled(app.hasActiveTunnel || app.isBusy)

                Section {
                    Button {
                        guard app.canMutateConfiguration else { return }
                        app.profile.activeModeID = modeID
                        app.save()
                    } label: {
                        Label(app.tr("设为当前模式", "Use this mode"), systemImage: "checkmark.circle")
                    }
                    .disabled(app.profile.activeModeID == modeID
                        || app.hasActiveTunnel || app.isBusy)
                }

                Section {
                    Button(app.tr("删除模式", "Delete Mode"), role: .destructive) {
                        guard let currentIndex = modeIndex else { return }
                        let mode = app.profile.modes[currentIndex]
                        app.deleteMode(mode)
                        dismiss()
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                }
            } else {
                ContentUnavailableView(app.tr("模式已删除", "Mode deleted"), systemImage: "trash")
            }
        }
        .navigationTitle(app.tr("编辑模式", "Edit Mode"))
        .onDisappear { app.save() }
    }

    @ViewBuilder
    private func targetOptions(
        selectedTargetID: String,
        includeDefault: Bool,
        ruleSetID: String = ""
    ) -> some View {
        if includeDefault {
            if ruleSetID == RuleSet.connectivityOutboundID && selectedTargetID.isEmpty {
                Text(app.tr("不适用（单出口）", "Not applicable (single route)")).tag("")
            } else {
                Text(app.tr("跟随默认", "Use default")).tag("")
            }
        } else {
            Text(app.tr("未设置", "Not set")).tag("")
        }

        ForEach(app.profile.lines.filter(app.isUsableRouteLine)) { line in
            Label(line.name, systemImage: lineSymbol(line.type))
                .tag("port:\(line.id)")
        }

        if !app.profile.subscriptions.filter(app.isUsableSubscription).isEmpty {
            Divider()
            ForEach(app.profile.subscriptions.filter(app.isUsableSubscription)) { subscription in
                Label(
                    "\(subscription.name) (\(subscription.lines.count))",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .tag("sub:\(subscription.id)")
            }
        }

        if !selectedTargetID.isEmpty && !availableTargetIDs.contains(selectedTargetID) {
            Divider()
            Text(app.tr("当前出口不可用", "Current route unavailable"))
                .tag(selectedTargetID)
        }
    }

    private var modeIndex: Int? {
        app.profile.modes.firstIndex { $0.id == modeID }
    }

    private var availableTargetIDs: Set<String> {
        let lines = app.profile.lines.filter(app.isUsableRouteLine).map { "port:\($0.id)" }
        let subscriptions = app.profile.subscriptions.filter(app.isUsableSubscription).map { "sub:\($0.id)" }
        return Set(lines + subscriptions)
    }

    private func modeBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Mode, T>) -> Binding<T> {
        Binding(
            get: { app.profile.modes[index][keyPath: keyPath] },
            set: {
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                app.profile.modes[index][keyPath: keyPath] = $0
                app.save()
            }
        )
    }

    private func defaultTarget(_ modeIndex: Int) -> Binding<String> {
        Binding(
            get: {
                targetID(
                    lineID: app.profile.modes[modeIndex].defaultLineID,
                    subscriptionID: app.profile.modes[modeIndex].defaultSubscriptionID
                )
            },
            set: { selectedTargetID in
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                if selectedTargetID.isEmpty {
                    app.profile.modes[modeIndex].defaultLineID = ""
                    app.profile.modes[modeIndex].defaultSubscriptionID = ""
                } else {
                    app.profile.modes[modeIndex].defaultTargetID = selectedTargetID
                }
                app.save()
            }
        )
    }

    private func bindingTarget(_ modeIndex: Int, ruleSetID: String) -> Binding<String> {
        Binding(
            get: { currentBindingTarget(modeIndex, ruleSetID: ruleSetID) },
            set: { selectedTargetID in
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                if let index = app.profile.modes[modeIndex].bindings.firstIndex(where: { $0.ruleSetID == ruleSetID }) {
                    if selectedTargetID.isEmpty {
                        app.profile.modes[modeIndex].bindings.remove(at: index)
                    } else {
                        app.profile.modes[modeIndex].bindings[index].targetID = selectedTargetID
                    }
                } else if !selectedTargetID.isEmpty {
                    var binding = RuleBinding(ruleSetID: ruleSetID)
                    binding.targetID = selectedTargetID
                    app.profile.modes[modeIndex].bindings.append(binding)
                }
                app.save()
            }
        )
    }

    private func currentBindingTarget(_ modeIndex: Int, ruleSetID: String) -> String {
        guard let binding = app.profile.modes[modeIndex].bindings.first(where: { $0.ruleSetID == ruleSetID }) else {
            return ""
        }
        return targetID(lineID: binding.lineID, subscriptionID: binding.subscriptionID)
    }

    private func targetID(lineID: String, subscriptionID: String) -> String {
        if !subscriptionID.isEmpty { return "sub:\(subscriptionID)" }
        if !lineID.isEmpty { return "port:\(lineID)" }
        return ""
    }
}
