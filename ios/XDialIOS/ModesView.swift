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
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            app.profile.activeModeID = mode.id
                            app.save()
                        } label: {
                            Label(app.tr("使用", "Use"), systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                }
            }
            .overlay {
                if app.profile.modes.isEmpty {
                    ContentUnavailableView(
                        app.tr("暂无模式", "No modes"),
                        systemImage: "shuffle",
                        description: Text(app.tr("点击右上角新建一个模式。", "Create a mode from the toolbar."))
                    )
                }
            }
            .navigationTitle(app.tr("模式", "Modes"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.createMode(from: .blank, named: app.tr("新模式", "New Mode"))
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func modeSummary(_ mode: Mode) -> String {
        let defaultName = app.profile.lines.first { $0.id == mode.defaultLineID }?.name
            ?? app.tr("未设置出口", "No default route")
        return app.tr("默认：\(defaultName) · \(mode.bindings.count) 条规则",
                      "Default: \(defaultName) · \(mode.bindings.count) rules")
    }
}

private struct ModeDetailView: View {
    @EnvironmentObject private var app: AppState
    let modeID: String

    var body: some View {
        Form {
            if let index = modeIndex {
                Section(app.tr("基本信息", "Basics")) {
                    TextField(app.tr("模式名称", "Mode name"), text: modeBinding(index, \.name))

                    Picker(app.tr("默认线路", "Default line"), selection: modeBinding(index, \.defaultLineID)) {
                        ForEach(app.profile.lines.filter(\.enabled)) { line in
                            Text(line.name).tag(line.id)
                        }
                    }
                }

                Section(app.tr("分流绑定", "Rule bindings")) {
                    if app.profile.ruleSets.isEmpty {
                        Text(app.tr("暂无规则集", "No rule sets"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.profile.ruleSets) { ruleSet in
                            Picker(ruleSet.name, selection: bindingTarget(index, ruleSetID: ruleSet.id)) {
                                Text(app.tr("跟随默认", "Use default")).tag("")
                                ForEach(app.profile.lines.filter(\.enabled)) { line in
                                    Text(line.name).tag(line.id)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        app.profile.activeModeID = modeID
                        app.save()
                    } label: {
                        Label(app.tr("设为当前模式", "Use this mode"), systemImage: "checkmark.circle")
                    }
                    .disabled(app.profile.activeModeID == modeID)
                }
            }
        }
        .navigationTitle(app.tr("编辑模式", "Edit Mode"))
        .onDisappear { app.save() }
    }

    private var modeIndex: Int? {
        app.profile.modes.firstIndex { $0.id == modeID }
    }

    private func modeBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Mode, T>) -> Binding<T> {
        Binding(
            get: { app.profile.modes[index][keyPath: keyPath] },
            set: { app.profile.modes[index][keyPath: keyPath] = $0 }
        )
    }

    private func bindingTarget(_ modeIndex: Int, ruleSetID: String) -> Binding<String> {
        Binding(
            get: {
                app.profile.modes[modeIndex].bindings.first { $0.ruleSetID == ruleSetID }?.lineID ?? ""
            },
            set: { lineID in
                if let index = app.profile.modes[modeIndex].bindings.firstIndex(where: { $0.ruleSetID == ruleSetID }) {
                    if lineID.isEmpty {
                        app.profile.modes[modeIndex].bindings.remove(at: index)
                    } else {
                        app.profile.modes[modeIndex].bindings[index].lineID = lineID
                    }
                } else if !lineID.isEmpty {
                    app.profile.modes[modeIndex].bindings.append(RuleBinding(ruleSetID: ruleSetID, lineID: lineID))
                }
            }
        )
    }
}
