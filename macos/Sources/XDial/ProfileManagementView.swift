import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProfileManagementAction: String, Identifiable {
    case rename, source, compatibility, copy, export, delete, empty, file, subscription, existingDebug
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rename: return "重命名配置"
        case .source: return "订阅设置"
        case .compatibility: return "导入兼容提示"
        case .copy: return "创建本地副本"
        case .export: return "导出配置"
        case .delete: return "删除配置"
        case .empty: return "新建空白配置"
        case .file: return "从文件导入"
        case .subscription: return "从链接订阅"
        case .existingDebug: return "从 XDail Debug 导入"
        }
    }
}

struct ProfileNavigation: View {
    @EnvironmentObject var state: AppState
    @State private var action: ProfileManagementAction?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Section(state.tr("选择配置", "Choose Configuration")) {
                    ForEach(state.profileLibrary.profiles) { record in
                        Button {
                            state.selectEditingProfile(record.id)
                        } label: {
                            Label(record.name, systemImage: record.id == state.editingRecord.id ? "checkmark" : "folder")
                        }
                    }
                }
                Section("当前配置 · \(state.editingRecord.name)") {
                    Button("重命名…") { action = .rename }
                    if state.editingRecord.source != nil {
                        Button("订阅设置…") { action = .source }
                        Button(state.refreshingProfileIDs.contains(state.editingRecord.id) ? "正在更新订阅…" : "立即更新订阅") {
                            state.refreshProfile(state.editingRecord.id)
                        }
                        .disabled(state.refreshingProfileIDs.contains(state.editingRecord.id))
                    }
                    if !state.editingRecord.profile.importWarnings.isEmpty {
                        Button("导入兼容提示…") { action = .compatibility }
                    }
                    Button("创建本地副本…") { action = .copy }
                    Button("导出配置…") { action = .export }
                    Button("删除配置…", role: .destructive) { action = .delete }
                        .disabled(!state.canDeleteEditingProfile)
                }
                Section("添加配置") {
                    Button("新建空白配置…") { action = .empty }
                    Button("从文件导入…") { action = .file }
                    Button("从链接订阅…") { action = .subscription }
                    Button("从 XDail Debug 导入…") { action = .existingDebug }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(state.editingRecord.name)
                        .lineLimit(1)
                        .frame(maxWidth: 190, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel(state.tr("选择与管理配置", "Choose and Manage Configuration"))

            Spacer(minLength: 12)

            Button {
                ApplicationWindowLifecycleController.shared.prepareToPresentSettingsWindow()
                openWindow(id: "general")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(state.tr("通用", "General"), systemImage: "slider.horizontal.3")
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium))
        .sheet(item: $action) { action in
            ProfileManagementSheet(action: action, record: state.editingRecord)
        }
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

    private var imports: Bool { action == .file || action == .subscription || action == .existingDebug }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.headline)
            if action == .compatibility {
                importDetails(record.profile)
            } else if action == .delete {
                Text("删除「\(record.name)」及其中的线路、规则和场景？")
                Text("订阅服务和服务器上的内容不会被删除。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if action == .export {
                Text("导出为包含场景的 XDial 配置。密码、密钥和订阅地址将被移除，使用前需要重新填写。")
                    .font(.callout)
            } else {
                if action == .source {
                    Text(record.name).font(.callout)
                } else {
                    TextField("配置名称", text: $name).textFieldStyle(.roundedBorder)
                }
                if action == .subscription || action == .source {
                    TextField("订阅链接", text: $url).textFieldStyle(.roundedBorder)
                    Picker("自动更新", selection: $interval) {
                        Text("手动更新").tag(0.0)
                        Text("每 6 小时").tag(21600.0)
                        Text("每天").tag(86400.0)
                        Text("每周").tag(604800.0)
                    }
                    if action == .source { importDetails(record.profile) }
                    if let updated = record.source?.updatedAt, action == .source {
                        Text("上次更新：\(updated.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if action == .file {
                    HStack {
                        Button("选择配置文件…", action: chooseFile)
                        Text(fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                }
                if action == .empty { Text("创建直连线路和默认场景，随后可以自行添加。\n保存配置后，在菜单栏点击场景即可连接。").font(.caption).foregroundStyle(.secondary) }
                if action == .existingDebug {
                    Text("将本机 XDail Debug 的线路、规则、场景和已保存密码复制到独立配置。\n原应用继续运行。Tailscale 需要在 Next 中单独登录。").font(.caption).foregroundStyle(.secondary)
                }
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
            if action == .existingDebug { name = "XDail Debug 导入" }
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
                    let parsed: Profile
                    if action == .existingDebug {
                        parsed = try ProfileDocumentService.importExistingDebug(id: newID)
                    } else {
                        parsed = try await ProfileDocumentService.read(content: fileContents,
                            url: action == .subscription ? url : "", profileID: newID, nodesOnly: nodesOnly)
                    }
                    try Task.checkCancellation()
                    acknowledgedWarnings = false
                    preview = parsed
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            }
            return
        }
        switch action {
        case .compatibility: break
        case .rename: state.renameEditingProfile(name)
        case .delete: state.deleteEditingProfile()
        case .empty:
            if !state.insertProfile(.empty(named: name)) { error = state.profilePersistenceError; return }
        case .copy:
            var copied = record
            copied.id = newID; copied.name = name; copied.source = nil; copied.baseline = nil
            do { copied.profile = try ProfileDocumentService.copy(record.profile, id: newID) }
            catch { self.error = error.localizedDescription; return }
            if !state.insertProfile(copied) { error = state.profilePersistenceError; return }
        case .file, .subscription, .existingDebug:
            guard let preview else { return }
            let source = action == .subscription ? ProfileSource(url: url, nodesOnly: nodesOnly, refreshInterval: interval, updatedAt: Date()) : nil
            let imported = ProfileRecord(id: newID, name: name, profile: preview, source: source, baseline: source == nil ? nil : preview)
            if !state.insertProfile(imported) { error = state.profilePersistenceError; return }
        case .source:
            guard let index = state.profileLibrary.profiles.firstIndex(where: { $0.id == record.id }) else { return }
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else {
                error = "请填写完整的 HTTPS 订阅链接"; return
            }
            state.profileLibrary.profiles[index].source = ProfileSource(url: url, nodesOnly: action == .source ? (record.source?.nodesOnly ?? false) : nodesOnly, refreshInterval: interval, updatedAt: url == record.source?.url ? record.source?.updatedAt : nil)
            guard state.persistProfileLibrary() else { error = state.profilePersistenceError; return }
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
