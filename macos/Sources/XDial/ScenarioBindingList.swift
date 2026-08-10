import AppKit
import SwiftUI

struct ScenarioBindingList: View {
    @SwiftUI.Binding var bindings: [RuleBinding]
    let scenarioID: String
    @ObservedObject var state: AppState
    let onSave: () -> Void

    @State private var draggedItem: SettingsReorderItem?
    @State private var hasMoved = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach($bindings) { $binding in
                let item = SettingsReorderItem(
                    kind: "scenario-binding:\(scenarioID)",
                    id: binding.ruleSetID
                )
                bindingRow(
                    $binding,
                    position: position(of: binding.ruleSetID)
                )
                .settingsReorderable(
                    item,
                    draggedItem: $draggedItem,
                    onDrop: commitReorder
                ) { dragged, targetID in
                    moveBinding(dragged, to: targetID)
                }
            }
        }
        .settingsReorderDropArea(
            draggedItem: $draggedItem,
            onDrop: commitReorder
        )
    }

    private func moveBinding(
        _ item: SettingsReorderItem,
        to targetID: String
    ) -> Bool {
        guard item.kind == "scenario-binding:\(scenarioID)",
              item.id != targetID,
              let source = bindings.firstIndex(where: {
                  $0.ruleSetID == item.id
              }),
              let target = bindings.firstIndex(where: {
                  $0.ruleSetID == targetID
              }) else { return false }
        let binding = bindings.remove(at: source)
        bindings.insert(binding, at: min(target, bindings.endIndex))
        hasMoved = true
        return true
    }

    private func commitReorder() {
        guard hasMoved else { return }
        hasMoved = false
        onSave()
    }

    private func position(of ruleSetID: String) -> Int {
        (bindings.firstIndex(where: { $0.ruleSetID == ruleSetID }) ?? 0) + 1
    }

    private func ruleName(for ruleSetID: String) -> String {
        state.profile.ruleSets.first(where: { $0.id == ruleSetID })?.name
            ?? state.tr("（已删除）", "(Deleted)")
    }

    @ViewBuilder
    private func bindingRow(
        _ binding: SwiftUI.Binding<RuleBinding>,
        position: Int
    ) -> some View {
        let ruleSetID = binding.wrappedValue.ruleSetID
        let ruleName = ruleName(for: ruleSetID)

        HStack {
            HStack(spacing: 6) {
                reorderHandle(
                    ruleSetID: ruleSetID,
                    ruleName: ruleName,
                    position: position
                )

                HStack(spacing: 4) {
                    if binding.wrappedValue.lineID.isEmpty
                        && binding.wrappedValue.subscriptionID.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(XDialPalette.warning)
                    }
                    Text(ruleName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(ruleName)
                }
                .frame(width: 166, alignment: .leading)
            }
            .frame(width: 200, alignment: .leading)

            Picker(
                "",
                selection: SwiftUI.Binding(
                    get: { binding.wrappedValue.targetID },
                    set: { targetID in
                        guard binding.wrappedValue.targetID != targetID else {
                            return
                        }
                        binding.wrappedValue.targetID = targetID
                        onSave()
                    }
                )
            ) {
                ForEach(state.profile.lines.filter(\.enabled)) { line in
                    Text(line.name).tag("port:\(line.id)")
                }
                if !state.profile.subscriptions.filter(\.enabled).isEmpty {
                    Divider()
                    ForEach(state.profile.subscriptions.filter(\.enabled)) {
                        subscription in
                        Label(
                            "\(subscription.name) (\(subscription.lines.count))",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .tag("sub:\(subscription.id)")
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(state.tr(
                "\(ruleName) 的线路",
                "Line for \(ruleName)"
            ))

            Button {
                bindings.removeAll { $0.ruleSetID == ruleSetID }
                onSave()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(XDialPalette.danger)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(state.tr(
                "移除 \(ruleName) 配对",
                "Remove \(ruleName) binding"
            ))
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func reorderHandle(
        ruleSetID: String,
        ruleName: String,
        position: Int
    ) -> some View {
        let enabled = bindings.count > 1
        let image = Image(systemName: "line.3.horizontal")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(
                enabled
                    ? XDialPalette.textSecondary
                    : XDialPalette.disabled
            )
            .frame(width: 28, height: 28)
            .accessibilityElement()
            .accessibilityLabel(state.tr(
                "拖动排序：\(ruleName)",
                "Reorder: \(ruleName)"
            ))
            .accessibilityValue(state.tr(
                "第 \(position) 项，共 \(bindings.count) 项",
                "Item \(position) of \(bindings.count)"
            ))

        if enabled {
            image
                .onHover { hovering in
                    (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .accessibilityAction(
                    named: Text(state.tr("上移", "Move Up"))
                ) {
                    moveBinding(ruleSetID: ruleSetID, by: -1)
                }
                .accessibilityAction(
                    named: Text(state.tr("下移", "Move Down"))
                ) {
                    moveBinding(ruleSetID: ruleSetID, by: 1)
                }
        } else {
            image
        }
    }

    private func moveBinding(ruleSetID: String, by offset: Int) {
        guard let source = bindings.firstIndex(where: {
            $0.ruleSetID == ruleSetID
        }) else { return }
        let destination = source + offset
        guard bindings.indices.contains(destination) else { return }
        bindings.move(
            fromOffsets: IndexSet(integer: source),
            toOffset: destination > source ? destination + 1 : destination
        )
        onSave()
    }
}
