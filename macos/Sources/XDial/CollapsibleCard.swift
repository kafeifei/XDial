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
        VStack(alignment: .leading, spacing: 6) {
            // 折叠头
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(locked ? .quaternary : .secondary)
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
                    .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(accentBar ? 0.06 : 0.08))
                if accentBar {
                    HStack(spacing: 0) {
                        Color.accentColor.opacity(0.5)
                            .frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5))
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        )
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
                .padding(8)
        }
    }
}
