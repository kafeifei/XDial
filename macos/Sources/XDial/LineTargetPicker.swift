import SwiftUI

/// Only materialize the shared catalog when a user opens one selector.
/// A Scenario with many bindings otherwise creates thousands of menu options.
struct LineTargetPicker: View {
    @ObservedObject var state: AppState
    @Binding var selection: String
    var label: String = "选择出口"
    var allowsSubscriptions = true
    @State private var presented = false
    @State private var query = ""

    private var selectedName: String {
        if selection.hasPrefix("sub:") {
            return state.editingProfile.subscriptions.first { "sub:\($0.id)" == selection }?.name ?? "（已删除）"
        }
        return state.editingProfile.lines.first { "port:\($0.id)" == selection }?.name ?? state.tr("选择出口", "Choose Exit")
    }

    var body: some View {
        Button { query = ""; presented = true } label: {
            HStack(spacing: 6) {
                Text(selectedName).lineLimit(1).truncationMode(.middle)
                if let line = state.editingProfile.lines.first(where: { "port:\($0.id)" == selection }) {
                    LineLatencyView(store: state.lineLatencies, line: line, profileID: state.editingRecord.id, allowsTesting: false)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityLabel(label).accessibilityValue(selectedName)
        .popover(isPresented: $presented) {
            VStack(spacing: 8) {
                SettingsSearchField(state.tr("搜索线路或组", "Search lines or groups"), text: $query)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        choices(groups: true)
                        choices(groups: false)
                        ForEach(state.editingProfile.subscriptions.filter { allowsSubscriptions && $0.enabled && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { sub in
                            choice(name: sub.name, detail: state.tr("订阅", "Subscription"), target: "sub:\(sub.id)")
                        }
                    }
                }.frame(height: 310)
            }.padding(12).frame(width: 390)
        }
    }

    @ViewBuilder
    private func choices(groups: Bool) -> some View {
        let lines = state.editingProfile.lines.filter {
            $0.enabled && $0.isGroup == groups && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        if !lines.isEmpty {
            Text(groups ? state.tr("线路组", "Line Groups") : state.tr("线路", "Lines"))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            ForEach(lines) { line in
                HStack(spacing: 4) {
                    choice(name: line.name, detail: line.memberTypeLabel, target: "port:\(line.id)")
                    LineLatencyView(store: state.lineLatencies, line: line, profileID: state.editingRecord.id)
                }
            }
        }
    }

    private func choice(name: String, detail: String, target: String) -> some View {
        Button {
            selection = target
            presented = false
        } label: {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Image(systemName: selection == target ? "checkmark" : "circle")
                    .opacity(selection == target ? 1 : 0).frame(width: 12)
            }.padding(.horizontal, 7).frame(minHeight: 28)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
