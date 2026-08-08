import SwiftUI

/// 三个 Tab 统一使用的可折叠卡片组件
struct CollapsibleCard<Header: View, Detail: View>: View {
    let isExpanded: Bool
    let locked: Bool  // 不可展开
    let onToggle: () -> Void
    let onDelete: (() -> Void)?
    let enabled: Binding<Bool>?
    let accentBar: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let detail: () -> Detail

    init(
        isExpanded: Bool,
        locked: Bool = false,
        onToggle: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        enabled: Binding<Bool>? = nil,
        accentBar: Bool = false,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.isExpanded = isExpanded
        self.locked = locked
        self.onToggle = onToggle
        self.onDelete = onDelete
        self.enabled = enabled
        self.accentBar = accentBar
        self.header = header
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 折叠头
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(locked ? .quaternary : .secondary)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)

                header()

                Spacer()

                if let enabled {
                    Toggle("", isOn: enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(locked)
                }

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !locked { withAnimation(.easeInOut(duration: 0.2)) { onToggle() } }
            }
            .allowsHitTesting(!locked)

            // 展开内容
            if isExpanded && !locked {
                detail()
                    .padding(.leading, 19)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        accentBar
                            ? XDialPalette.selection.opacity(0.10)
                            : XDialPalette.surface
                    )
                if accentBar {
                    HStack(spacing: 0) {
                        XDialPalette.selection.opacity(0.72)
                            .frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5))
                        Spacer()
                    }
                    .padding(.vertical, 7)
                }
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    accentBar
                        ? XDialPalette.selection.opacity(0.18)
                        : Color.primary.opacity(0.065),
                    lineWidth: 0.5
                )
        }
    }
}

/// 底部添加栏，三个 Tab 统一样式
struct AddBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Spacer()
            content()
                .menuStyle(.borderlessButton)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(XDialPalette.primaryAction)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    XDialPalette.primaryAction.opacity(0.09),
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(
                        XDialPalette.primaryAction.opacity(0.16),
                        lineWidth: 0.5
                    )
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(0.015))
    }
}

/// 通用设置使用与列表卡片相同的表面层级。
struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 0.5)
            }
    }
}
