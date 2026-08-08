import SwiftUI

/// 场景选择列表。展示 AppState.profile.scenarios，中键选中即设为 activeScenario。
///
/// tvOS 标准交互：List 每行是一个 Button（可聚焦），方向键上下移动焦点，
/// 中键触发选中。@FocusState 记录当前聚焦行，进入时自动落在当前 active 场景上。
struct ScenarioPickerView: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var focusedScenarioID: String?

    var body: some View {
        Group {
            if app.profile.scenarios.isEmpty {
                emptyState
            } else {
                scenarioList
            }
        }
        .navigationTitle(app.tr("选择场景", "Select Scenario"))
        .onAppear {
            // 优先聚焦当前激活场景，否则第一条
            focusedScenarioID = app.activeScenario?.id ?? app.profile.scenarios.first?.id
        }
    }

    private var scenarioList: some View {
        List {
            ForEach(app.profile.scenarios) { scenario in
                Button {
                    select(scenario)
                } label: {
                    row(for: scenario)
                }
                .focused($focusedScenarioID, equals: scenario.id)
            }
        }
    }

    private func row(for scenario: Scenario) -> some View {
        HStack(spacing: 20) {
            Image(systemName: isActive(scenario) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive(scenario) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.name)
                    .font(.headline)
                Text(subtitle(for: scenario))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text(app.tr("暂无场景", "No scenarios yet"))
                .font(.title2)
            Text(app.tr("请从 Mac 端同步配置", "Sync configuration from your Mac"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isActive(_ scenario: Scenario) -> Bool {
        app.profile.activeScenarioID == scenario.id
    }

    /// 场景的分流规则数量作为副标题，纯数据派生，不依赖连接结果。
    private func subtitle(for scenario: Scenario) -> String {
        let count = scenario.bindings.count
        return app.tr("\(count) 条分流绑定", "\(count) binding(s)")
    }

    private func select(_ scenario: Scenario) {
        app.profile.activeScenarioID = scenario.id
        app.save()
    }
}
