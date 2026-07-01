import SwiftUI

/// 模式选择列表。展示 AppState.profile.modes，中键选中即设为 activeMode。
///
/// tvOS 标准交互：List 每行是一个 Button（可聚焦），方向键上下移动焦点，
/// 中键触发选中。@FocusState 记录当前聚焦行，进入时自动落在当前 active 模式上。
struct ModePickerView: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var focusedModeID: String?

    var body: some View {
        Group {
            if app.profile.modes.isEmpty {
                emptyState
            } else {
                modeList
            }
        }
        .navigationTitle(app.tr("选择模式", "Select Mode"))
        .onAppear {
            // 优先聚焦当前激活模式，否则第一条
            focusedModeID = app.activeMode?.id ?? app.profile.modes.first?.id
        }
    }

    private var modeList: some View {
        List {
            ForEach(app.profile.modes) { mode in
                Button {
                    select(mode)
                } label: {
                    row(for: mode)
                }
                .focused($focusedModeID, equals: mode.id)
            }
        }
    }

    private func row(for mode: Mode) -> some View {
        HStack(spacing: 20) {
            Image(systemName: isActive(mode) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive(mode) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.name)
                    .font(.headline)
                Text(subtitle(for: mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "shuffle")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text(app.tr("暂无模式", "No modes yet"))
                .font(.title2)
            Text(app.tr("请从 Mac 端同步配置", "Sync configuration from your Mac"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isActive(_ mode: Mode) -> Bool {
        app.profile.activeModeID == mode.id
    }

    /// 模式的分流规则数量作为副标题，纯数据派生，不依赖连接结果。
    private func subtitle(for mode: Mode) -> String {
        let count = mode.bindings.count
        return app.tr("\(count) 条分流绑定", "\(count) binding(s)")
    }

    private func select(_ mode: Mode) {
        app.profile.activeModeID = mode.id
        app.save()
    }
}
