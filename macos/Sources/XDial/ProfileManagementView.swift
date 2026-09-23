import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProfileManagementAction: String, Identifiable {
    case compatibility, copy, export, delete, empty, file, subscription
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compatibility: return "导入兼容提示"
        case .copy: return "创建本地副本"
        case .export: return "导出配置"
        case .delete: return "删除配置"
        case .empty: return "新建空白配置"
        case .file: return "从文件导入"
        case .subscription: return "从链接订阅"
        }
    }
}

struct ProfileNavigation: View {
    @EnvironmentObject var state: AppState
    @State private var showingPicker = false
    @State private var action: ProfileManagementAction?
    @State private var managedProfile: ProfileRecord?

    private var pickerWidth: CGFloat {
        let nameFont = NSFont.systemFont(ofSize: 13)
        let nameWidth = state.profileLibrary.profiles.map {
            ($0.name as NSString).size(withAttributes: [.font: nameFont]).width
        }.max() ?? 0
        let editWidth = (state.tr("修改", "Edit") as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]).width
        return min(280, max(180, ceil(nameWidth + editWidth + 72)))
    }

    var body: some View {
        Button { showingPicker.toggle() } label: {
            HStack(spacing: 4) {
                Text(state.editingRecord.name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 3)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 112, alignment: .leading)
        .font(.system(size: 13, weight: .semibold))
        .accessibilityLabel(state.tr("选择与管理配置", "Choose and Manage Configuration"))
        .help(state.editingRecord.name)
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.tr("选择配置", "Choose Configuration"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 3).padding(.bottom, 1)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.profileLibrary.profiles) { record in
                            ProfilePickerRow(name: record.name, selected: record.id == state.editingRecord.id,
                                             editTitle: state.tr("修改", "Edit")) {
                                state.selectEditingProfile(record.id)
                                showingPicker = false
                            } edit: {
                                showingPicker = false
                                managedProfile = record
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(max(0, CGFloat(state.profileLibrary.profiles.count) * 30 - 2), 238))
                Divider().padding(.vertical, 3)
                Text(state.tr("添加配置", "Add Configuration"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 1)
                addButton(.empty, title: "新建空白配置…", icon: "plus")
                addButton(.file, title: "从文件导入…", icon: "doc")
                addButton(.subscription, title: "从链接订阅…", icon: "link")
            }
            .padding(6).frame(width: pickerWidth)
        }
        .sheet(item: $managedProfile) { record in
            ProfileDetailSheet(record: record)
        }
        .sheet(item: $action) { action in
            ProfileManagementSheet(action: action, record: state.editingRecord)
        }
    }

    private func addButton(_ value: ProfileManagementAction, title: String, icon: String) -> some View {
        Button {
            showingPicker = false
            action = value
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProfilePickerRow: View {
    let name: String
    let selected: Bool
    let editTitle: String
    let select: () -> Void
    let edit: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Control?
    private enum Control: Hashable { case select, edit }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark" : "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? XDialPalette.accent : XDialPalette.textSecondary)
                        .frame(width: 16)
                    Text(name).lineLimit(1).truncationMode(.tail).help(name)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 8).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .select)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text(editTitle), edit)
            Button(editTitle, action: edit)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(XDialPalette.accent)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(XDialPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                .padding(.trailing, 4)
                .opacity(hovered || focused != nil ? 1 : 0)
                .focused($focused, equals: .edit)
                .accessibilityLabel("\(editTitle) \(name)")
        }
        .font(.system(size: 13))
        .background(hovered || focused != nil ? XDialPalette.accent.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// Manages the requested record without changing which Profile is selected or connected.
struct ProfileDetailSheet: View {
    let record: ProfileRecord
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var interval: Double = 86400
    @State private var error: String?
    @State private var action: ProfileManagementAction?
    @State private var confirmingRegenerate = false

    private var current: ProfileRecord {
        state.profileLibrary.profiles.first { $0.id == record.id } ?? record
    }
    private var refreshing: Bool { state.refreshingProfileIDs.contains(record.id) }
    private var sourceChanged: Bool {
        url != (current.source?.url ?? "") || interval != (current.source?.refreshInterval ?? 86400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("修改配置").font(.headline)
                Spacer()
                Text(current.source == nil ? "本地配置" : "订阅配置")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("配置名称", text: $name).textFieldStyle(.roundedBorder)
            }
            if current.source != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("订阅链接").font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS 订阅链接", text: $url).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("自动更新", selection: $interval) {
                            Text("手动更新").tag(0.0)
                            Text("每 6 小时").tag(21600.0)
                            Text("每天").tag(86400.0)
                            Text("每周").tag(604800.0)
                        }
                        Spacer()
                        Button(refreshing ? "正在更新…" : "立即更新") { state.refreshProfile(record.id) }
                            .disabled(refreshing || sourceChanged)
                            .help(sourceChanged ? "保存订阅设置后即可更新" : "更新这份配置的订阅")
                    }
                    if let updated = current.source?.updatedAt {
                        Text("上次更新：\(updated.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if current.source != nil, current.baseline != nil {
                let available = state.profileLibrary.availableTemplateCount(profileID: record.id)
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新线路和规则，并同步已跟随的组成员；保留你的场景与选线设置。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("导入新增组和场景（\(available)）") { state.importSourceTemplates(record.id) }
                            .disabled(available == 0 || refreshing)
                        Button("从订阅重新生成…") { confirmingRegenerate = true }.disabled(refreshing)
                    }
                }
            }
            if !current.profile.importWarnings.isEmpty || !current.profile.importAdjustments.isEmpty {
                Button { action = .compatibility } label: {
                    Label("导入兼容说明", systemImage: "info.circle")
                }
                .buttonStyle(.link)
            }
            Divider()
            HStack(spacing: 8) {
                Button("创建本地副本…") { action = .copy }
                Button("导出配置…") { action = .export }
                Spacer()
                Button("删除…", role: .destructive) { action = .delete }
                    .disabled(!state.canDeleteProfile(record.id))
            }
            if !state.canDeleteProfile(record.id) {
                Text(state.profileLibrary.profiles.count == 1 ? "至少保留一份配置。" : "全局组或场景仍引用此配置，或正在切换场景，暂时无法删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = error ?? state.profilePersistenceError ?? state.profileOperationError {
                Text(error).font(.caption).foregroundStyle(XDialPalette.danger).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 480)
        .confirmationDialog("从订阅重新生成线路组和场景？", isPresented: $confirmingRegenerate) {
            Button("重新生成", role: .destructive) { state.importSourceTemplates(record.id, replacing: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将覆盖由此订阅创建的组和场景设置，保留已有 SSID；手动新建的组和场景不受影响。")
        }
        .onAppear {
            name = current.name
            url = current.source?.url ?? ""
            interval = current.source?.refreshInterval ?? 86400
        }
        .sheet(item: $action, onDismiss: {
            if !state.profileLibrary.profiles.contains(where: { $0.id == record.id }) { dismiss() }
        }) { action in
            ProfileManagementSheet(action: action, record: current)
        }
    }

    private func save() {
        var source = current.source
        if source != nil {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed), parsed.scheme == "https", parsed.host != nil else {
                error = "请填写完整的 HTTPS 订阅链接"; return
            }
            if source?.url != trimmed { source?.updatedAt = nil }
            source?.url = trimmed
            source?.refreshInterval = interval
        }
        guard state.updateProfileMetadata(record.id, name: name, source: source) else {
            error = state.profilePersistenceError ?? "配置已不存在，无法保存修改"; return
        }
        dismiss()
    }
}

struct ProfileManagementSheet: View {
    let action: ProfileManagementAction
    let record: ProfileRecord
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var interval: Double = 86400
    @State private var fileContents = ""
    @State private var fileName = ""
    @State private var preview: Profile?
    @State private var error: String?
    @State private var busy = false
    @State private var nodesOnly = false
    @State private var acknowledgedWarnings = false
    @State private var task: Task<Void, Never>?
    @State private var newID = UUID().uuidString.lowercased()

    private var imports: Bool { action == .file || action == .subscription }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.headline)
            if action == .compatibility {
                importDetails(record.profile)
            } else if action == .delete {
                Text("删除「\(record.name)」及其中的线路和规则？")
                Text("订阅服务和服务器上的内容不会被删除。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if action == .export {
                Text("导出此 Profile 的线路和规则。全局线路组和场景不包含在内；密码、密钥和订阅地址将被移除，使用前需要重新填写。")
                    .font(.callout)
            } else {
                TextField("配置名称", text: $name).textFieldStyle(.roundedBorder)
                if action == .subscription {
                    TextField("订阅链接", text: $url).textFieldStyle(.roundedBorder)
                    Picker("自动更新", selection: $interval) {
                        Text("手动更新").tag(0.0)
                        Text("每 6 小时").tag(21600.0)
                        Text("每天").tag(86400.0)
                        Text("每周").tag(604800.0)
                    }
                }
                if action == .file {
                    HStack {
                        Button("选择配置文件…", action: chooseFile)
                        Text(fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                }
                if action == .empty { Text("创建一份独立的线路和规则来源。随后可在全局线路组和场景中使用这些资源。").font(.caption).foregroundStyle(.secondary) }
                if action == .file || action == .subscription { Toggle("仅导入线路，另建默认场景", isOn: $nodesOnly).font(.caption) }
                if let preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(preview.lines.count) 条线路 · \(preview.ruleSets.count) 个规则集 · \(preview.scenarios.count) 个场景")
                        Text(preview.scenarios.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        importDetails(preview)
                        if !preview.importWarnings.isEmpty {
                            Toggle("确认以上规则不生效，导入其余配置", isOn: $acknowledgedWarnings)
                                .font(.caption)
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle, role: action == .delete ? .destructive : nil, action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (preview?.importWarnings.isEmpty == false && !acknowledgedWarnings) || (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && action != .delete && action != .export))
            }
        }
        .padding(24).frame(width: 440)
        .onAppear {
            name = [.empty, .file, .subscription].contains(action) ? "新配置" : record.name + (action == .copy ? " 副本" : "")
            url = record.source?.url ?? ""
            interval = record.source?.refreshInterval ?? 86400
        }
        .onChange(of: url) { preview = nil }
        .onChange(of: nodesOnly) { preview = nil }
        .onDisappear { task?.cancel() }
    }

    private var primaryTitle: String {
        if imports { return preview == nil ? "解析并预览" : "保存配置" }
        if action == .compatibility { return "完成" }
        switch action {
        case .empty, .copy: return "创建"
        case .delete: return "删除"
        case .export: return "导出…"
        default: return "保存"
        }
    }

    @ViewBuilder
    private func importDetails(_ profile: Profile) -> some View {
        ForEach(Array(profile.importAdjustments.enumerated()), id: \.offset) { _, adjustment in
            if adjustment.code == "anytls-tfo-disabled" {
                Text("已为 \(adjustment.count) 条 AnyTLS 线路关闭 TCP Fast Open：sing-box 不支持此组合，线路和分流规则已保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if profile.matchingResources.contains(where: { $0.url.hasPrefix("https://raw.githubusercontent.com/SagerNet/sing-geoip/") }) {
            Text("GEOIP 使用 SagerNet 国家 IP 规则集，可在规则中查看和修改来源。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if profile.matchingResources.contains(where: { $0.url.hasPrefix("https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/asn/") }) {
            Text("ASN 使用 MetaCubeX IP 规则集，可在规则中查看和修改来源。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !profile.importWarnings.isEmpty {
            Text("以下 \(profile.importWarnings.count) 条 USER-AGENT 规则无法执行。原始条目会保留；其他域名、IP 和进程规则照常导入。")
                .font(.caption).foregroundStyle(XDialPalette.danger)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(profile.importWarnings.enumerated()), id: \.offset) { _, rule in
                        Text("\(rule.type), \(rule.value) → \(rule.group)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption).textSelection(.enabled)
            }
            .frame(maxHeight: 110)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let data = try Data(contentsOf: selected, options: .mappedIfSafe)
            guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                throw ProfileLibraryError.invalid("配置文件必须为 UTF-8 文本，且不能超过 4 MiB")
            }
            let previousFileName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            fileContents = text; fileName = selected.lastPathComponent; preview = nil
            if name == "新配置" || name == previousFileName || name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = selected.deletingPathExtension().lastPathComponent
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func perform() {
        error = nil
        if imports && preview == nil {
            busy = true
            task = Task {
                defer { busy = false }
                do {
                    let parsed = try await ProfileDocumentService.read(content: fileContents,
                        url: action == .subscription ? url : "", profileID: newID, nodesOnly: nodesOnly)
                    try Task.checkCancellation()
                    acknowledgedWarnings = false
                    preview = parsed
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            }
            return
        }
        switch action {
        case .compatibility: break
        case .delete:
            guard state.deleteProfile(record.id) else {
                error = state.profilePersistenceError ?? "配置正在使用或已不存在，无法删除"; return
            }
        case .empty:
            var created = ProfileRecord.empty(named: name)
            created.profile.scenarios = []; created.profile.activeScenarioID = ""
            if !state.insertProfile(created) { error = state.profileOperationError ?? state.profilePersistenceError; return }
        case .copy:
            var copied = record
            copied.id = newID; copied.name = name; copied.source = nil; copied.baseline = nil
            do { copied.profile = try ProfileDocumentService.copy(record.profile, id: newID) }
            catch { self.error = error.localizedDescription; return }
            if !state.insertProfile(copied) { error = state.profileOperationError ?? state.profilePersistenceError; return }
        case .file, .subscription:
            guard let preview else { return }
            let source = action == .subscription ? ProfileSource(url: url, nodesOnly: nodesOnly, refreshInterval: interval, updatedAt: Date()) : nil
            let imported = ProfileRecord(id: newID, name: name, profile: preview, source: source, baseline: source == nil ? nil : preview)
            if !state.insertProfile(imported) { error = state.profileOperationError ?? state.profilePersistenceError; return }
        case .export:
            do {
                let data = try ProfileDocumentService.export(record.profile)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = record.name + ".json"
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try data.write(to: destination, options: .atomic)
            } catch { self.error = error.localizedDescription; return }
        }
        if let persistenceError = state.profilePersistenceError { error = persistenceError; return }
        dismiss()
    }
}
