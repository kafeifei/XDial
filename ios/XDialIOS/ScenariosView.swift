import SwiftUI

struct ScenariosView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.profile.scenarios) { scenario in
                    let issues = app.configurationIssues(for: scenario)
                    NavigationLink {
                        ScenarioDetailView(scenarioID: scenario.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: scenario.id == app.profile.activeScenarioID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(scenario.id == app.profile.activeScenarioID ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scenario.name)
                                Text(scenarioSummary(scenario))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !issues.isEmpty {
                                    Text(app.tr(
                                        "需补齐 \(issues.count) 项配置",
                                        "\(issues.count) setup item(s) required"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            guard app.canMutateConfiguration else { return }
                            app.profile.activeScenarioID = scenario.id
                            app.save()
                        } label: {
                            Label(app.tr("使用", "Use"), systemImage: "checkmark")
                        }
                        .tint(.green)
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            app.deleteScenario(scenario)
                        } label: {
                            Label(app.tr("删除", "Delete"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                }
            }
            .overlay {
                if app.profile.scenarios.isEmpty {
                    ContentUnavailableView(
                        app.tr("暂无场景", "No scenarios"),
                        systemImage: "square.grid.2x2",
                        description: Text(app.tr("点击右上角从模板新建场景。", "Create a scenario from a template."))
                    )
                }
            }
            .navigationTitle(app.tr("场景", "Scenarios"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(ScenarioTemplate.allCases, id: \.self) { template in
                            Button(templateName(template)) {
                                app.createScenario(from: template, named: templateName(template))
                            }
                            .disabled(!app.canCreateScenario(from: template)
                                || app.hasActiveTunnel || app.isBusy)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(app.tr("添加场景", "Add scenario"))
                    .disabled(!app.canMutateConfiguration || app.hasActiveTunnel || app.isBusy)
                }
            }
        }
    }

    private func scenarioSummary(_ scenario: Scenario) -> String {
        let defaultName: String
        if !scenario.defaultSubscriptionID.isEmpty {
            defaultName = app.profile.subscriptions.first { $0.id == scenario.defaultSubscriptionID }?.name
                ?? app.tr("订阅已删除", "Missing subscription")
        } else if !scenario.defaultLineID.isEmpty {
            defaultName = app.profile.lines.first { $0.id == scenario.defaultLineID }?.name
                ?? app.tr("线路已删除", "Missing line")
        } else {
            defaultName = app.tr("未设置出口", "No default route")
        }
        return app.tr(
            "默认：\(defaultName) · \(scenario.bindings.count) 条规则",
            "Default: \(defaultName) · \(scenario.bindings.count) rules"
        )
    }

    private func templateName(_ template: ScenarioTemplate) -> String {
        switch template {
        case .overseas: return app.tr("海外", "Overseas")
        case .domestic: return app.tr("国内", "Domestic")
        case .domesticSS: return app.tr("国内 + SS", "Domestic + SS")
        case .blank: return app.tr("空白场景", "Blank Scenario")
        }
    }
}

private struct ScenarioDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let scenarioID: String

    var body: some View {
        Form {
            if let index = scenarioIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("场景名称", "Scenario name"), text: scenarioBinding(index, \.name))

                    Picker(app.tr("默认出口", "Default route"), selection: defaultTarget(index)) {
                        targetOptions(
                            selectedTargetID: targetID(
                                lineID: app.profile.scenarios[index].defaultLineID,
                                subscriptionID: app.profile.scenarios[index].defaultSubscriptionID
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
                        "带锁规则会明确显示 1.0.0.1 的 Direct 绑定，以及 1.1.1.1 选中的非 Direct 验收出口；单出口场景不执行双出口分流验收。",
                        "Locked rules explicitly show the Direct binding for 1.0.0.1 and the selected non-Direct acceptance route for 1.1.1.1. Dual-route verification is not run in single-route scenarios."
                    ))
                }
                .disabled(app.hasActiveTunnel || app.isBusy)

                Section {
                    Button {
                        guard app.canMutateConfiguration else { return }
                        app.profile.activeScenarioID = scenarioID
                        app.save()
                    } label: {
                        Label(app.tr("设为当前场景", "Use this scenario"), systemImage: "checkmark.circle")
                    }
                    .disabled(app.profile.activeScenarioID == scenarioID
                        || app.hasActiveTunnel || app.isBusy)
                }

                Section {
                    Button(app.tr("删除场景", "Delete Scenario"), role: .destructive) {
                        guard let currentIndex = scenarioIndex else { return }
                        let scenario = app.profile.scenarios[currentIndex]
                        app.deleteScenario(scenario)
                        dismiss()
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                }
            } else {
                ContentUnavailableView(app.tr("场景已删除", "Scenario deleted"), systemImage: "trash")
            }
        }
        .navigationTitle(app.tr("编辑场景", "Edit Scenario"))
        .onDisappear { app.save() }
    }

    @ViewBuilder
    private func targetOptions(
        selectedTargetID: String,
        includeDefault: Bool,
        ruleSetID: String = ""
    ) -> some View {
        let availableLines = app.profile.lines.filter {
            let usable = includeDefault
                ? app.isUsableRouteLine($0)
                : app.isUsableDefaultRouteLine($0)
            return usable
        }
        let availableSubscriptions = app.profile.subscriptions.filter(app.isUsableSubscription)
        let availableIDs = Set(
            availableLines.map { "port:\($0.id)" }
                + availableSubscriptions.map { "sub:\($0.id)" }
        )
        if includeDefault {
            if ruleSetID == RuleSet.connectivityOutboundID && selectedTargetID.isEmpty {
                Text(app.tr("不适用（单出口）", "Not applicable (single route)")).tag("")
            } else {
                Text(app.tr("跟随默认", "Use default")).tag("")
            }
        } else {
            Text(app.tr("未设置", "Not set")).tag("")
        }

        ForEach(availableLines) { line in
            Label(line.name, systemImage: lineSymbol(line.type))
                .tag("port:\(line.id)")
        }

        if !availableSubscriptions.isEmpty {
            Divider()
            ForEach(availableSubscriptions) { subscription in
                Label(
                    "\(subscription.name) (\(subscription.lines.count))",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .tag("sub:\(subscription.id)")
            }
        }

        if !selectedTargetID.isEmpty && !availableIDs.contains(selectedTargetID) {
            Divider()
            Text(app.tr("当前出口不可用", "Current route unavailable"))
                .tag(selectedTargetID)
        }
    }

    private var scenarioIndex: Int? {
        app.profile.scenarios.firstIndex { $0.id == scenarioID }
    }

    private func scenarioBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Scenario, T>) -> Binding<T> {
        Binding(
            get: { app.profile.scenarios[index][keyPath: keyPath] },
            set: {
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                app.profile.scenarios[index][keyPath: keyPath] = $0
                app.save()
            }
        )
    }

    private func defaultTarget(_ scenarioIndex: Int) -> Binding<String> {
        Binding(
            get: {
                targetID(
                    lineID: app.profile.scenarios[scenarioIndex].defaultLineID,
                    subscriptionID: app.profile.scenarios[scenarioIndex].defaultSubscriptionID
                )
            },
            set: { selectedTargetID in
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                if selectedTargetID.isEmpty {
                    app.profile.scenarios[scenarioIndex].defaultLineID = ""
                    app.profile.scenarios[scenarioIndex].defaultSubscriptionID = ""
                } else {
                    app.profile.scenarios[scenarioIndex].defaultTargetID = selectedTargetID
                }
                app.save()
            }
        )
    }

    private func bindingTarget(_ scenarioIndex: Int, ruleSetID: String) -> Binding<String> {
        Binding(
            get: { currentBindingTarget(scenarioIndex, ruleSetID: ruleSetID) },
            set: { selectedTargetID in
                guard !app.hasActiveTunnel, !app.isBusy else { return }
                if let index = app.profile.scenarios[scenarioIndex].bindings.firstIndex(where: { $0.ruleSetID == ruleSetID }) {
                    if selectedTargetID.isEmpty {
                        app.profile.scenarios[scenarioIndex].bindings.remove(at: index)
                    } else {
                        app.profile.scenarios[scenarioIndex].bindings[index].targetID = selectedTargetID
                    }
                } else if !selectedTargetID.isEmpty {
                    var binding = RuleBinding(ruleSetID: ruleSetID)
                    binding.targetID = selectedTargetID
                    app.profile.scenarios[scenarioIndex].bindings.append(binding)
                }
                app.save()
            }
        )
    }

    private func currentBindingTarget(_ scenarioIndex: Int, ruleSetID: String) -> String {
        guard let binding = app.profile.scenarios[scenarioIndex].bindings.first(where: { $0.ruleSetID == ruleSetID }) else {
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
