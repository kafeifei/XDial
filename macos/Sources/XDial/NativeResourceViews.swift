import SwiftUI

struct LineGroupRow: View {
    @Binding var line: Line
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState
    private var expanded: Bool {
        get { state.editorPosition.expandedLineIDs.contains(line.id) }
        nonmutating set {
            if newValue { state.editorPosition.expandedLineIDs.insert(line.id) }
            else { state.editorPosition.expandedLineIDs.remove(line.id) }
        }
    }
    private var readOnly: Bool { state.editingRecord.baseline?.lines.contains(where: { $0.id == line.id }) == true }

    var body: some View {
        CollapsibleCard(isExpanded: expanded, onToggle: { expanded.toggle() },
                        onDelete: readOnly ? nil : onDelete,
                        header: {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            Text(line.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(line.type == "urltest" ? "自动测速" : "手动选择").font(.caption).foregroundStyle(.secondary)
            Text(readOnly ? "订阅" : "自建").font(.caption).foregroundStyle(.secondary)
        }, detail: {
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: $line.name).textFieldStyle(.roundedBorder)
                    .disabled(readOnly).onChange(of: line.name) { state.saveEditingProfile() }
                if line.type == "selector" {
                    Picker("选用线路", selection: $line.groupDefault) {
                        Text("第一条成员").tag("")
                        ForEach(line.groupMembers, id: \.self) { id in
                            Text(state.editingProfile.lines.first { $0.id == id }?.name ?? id).tag(id)
                        }
                    }
                    .onChange(of: line.groupDefault) { state.saveEditingProfile() }
                } else {
                    TextField("测速 URL（留空采用核心默认值）", text: $line.groupURL)
                        .textFieldStyle(.roundedBorder).disabled(readOnly)
                        .onChange(of: line.groupURL) { state.saveEditingProfile() }
                    TextField("间隔，例如 3m", text: $line.groupInterval)
                        .textFieldStyle(.roundedBorder).disabled(readOnly)
                        .onChange(of: line.groupInterval) { state.saveEditingProfile() }
                }
                ForEach(state.editingProfile.lines.filter { $0.id != line.id && $0.type != "vpn" && $0.type != "tailscale" && (line.type != "urltest" || $0.type != "direct") }) { member in
                    Toggle(member.name, isOn: Binding(get: { line.groupMembers.contains(member.id) }, set: { selected in
                        if selected { line.groupMembers.append(member.id) }
                        else {
                            line.groupMembers.removeAll { $0 == member.id }
                            if line.groupDefault == member.id { line.groupDefault = "" }
                        }
                        state.saveEditingProfile()
                    })).disabled(readOnly)
                }
            }.font(.caption)
        })
    }
}

struct NativeRuleEditor: View {
    @Binding var rule: RuleSet
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var error: String?
    private var readOnly: Bool { state.editingRecord.baseline?.ruleSets.contains(where: { $0.id == rule.id }) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("sing-box 匹配规则").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110).disabled(readOnly)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            if !readOnly {
                Button("保存规则") {
                    do {
                        let candidate = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                        var profile = state.editingProfile
                        guard let index = profile.ruleSets.firstIndex(where: { $0.id == rule.id }) else { return }
                        profile.ruleSets[index].nativeRule = candidate
                        try ProfileDocumentService.validate(profile)
                        rule.nativeRule = candidate
                        state.saveEditingProfile()
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { text = rule.nativeRule?.formatted ?? "{}" }
        .onChange(of: rule.nativeRule) { text = rule.nativeRule?.formatted ?? "{}" }
    }
}

struct NativeLineOptionsEditor: View {
    @Binding var line: Line
    @EnvironmentObject var state: AppState
    @State private var text = "{}"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填写 TLS、传输等附加选项；服务器与凭据使用上方表单。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 110)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            Button("保存高级选项") {
                do {
                    let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                    guard case .object = value else { throw ProfileLibraryError.invalid("高级选项必须是 JSON 对象") }
                    var profile = state.editingProfile
                    guard let index = profile.lines.firstIndex(where: { $0.id == line.id }) else { return }
                    profile.lines[index].nativeOptions = value
                    try ProfileDocumentService.validate(profile)
                    line.nativeOptions = value
                    state.saveEditingProfile()
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
        .onAppear { text = line.nativeOptions?.formatted ?? "{}" }
        .onChange(of: line.nativeOptions) { text = line.nativeOptions?.formatted ?? "{}" }
    }
}
