import SwiftUI

/// 地址族菜单只选择展示项；只有终态 notice 才能显式重试地址查询。
struct LineAddressView: View {
    let name: String
    let info: LineNetInfo?
    let capability: LineAddressFamilyCapability?
    let language: Lang
    var retry: (LineAddressFamily) -> Void = { _ in }
    @State private var selection: LineAddressFamily = .ipv4

    private var family: LineAddressFamily {
        selection == .ipv6 && !isAvailable(.ipv6) ? .ipv4 : selection
    }
    private var observation: LineAddressObservation? { info?.observation(for: family) }
    private var address: String { observation?.address ?? "" }
    private var failed: Bool { observation?.phase == .failed }
    private var pending: Bool {
        isAvailable(family) && (observation == nil || observation?.phase == .querying || observation?.phase == .waiting)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(XDialPalette.success)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
                .help(name)
            if failed {
                Button { retry(family) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        addressText(address.isEmpty ? text("missing") : address)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(XDialPalette.textSecondary)
                .help(address.isEmpty ? text("retryHint") : text("updateFailed"))
                .accessibilityLabel(name + ", " + text("retryLabel"))
                .accessibilityHint(text("retryHint"))
            }
            addressMenu
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .contain)
    }

    private var addressMenu: some View {
        Menu {
            Section(text("display")) {
                ForEach(LineAddressFamily.allCases, id: \.self) { value in
                    // Use the native menu title and checkmark. A custom HStack
                    // label can truncate the address before NSMenu sizes the item.
                    Toggle(menuLabel(value), isOn: Binding(
                        get: { family == value },
                        set: { selected in if selected { selection = value } }
                    ))
                    .disabled(!isAvailable(value))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if !failed {
                    if !address.isEmpty {
                        addressText(address)
                    }
                    if pending {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(text("query"))
                    } else if address.isEmpty {
                        Text(text("unavailable")).font(.callout)
                    }
                }
                Text(family == .ipv4 ? "v4" : "v6")
                    .font(.caption2.monospaced())
                    .foregroundStyle(XDialPalette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .frame(maxWidth: failed ? nil : .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(XDialPalette.textSecondary)
        .fixedSize(horizontal: failed, vertical: true)
        .help(address.isEmpty ? text("display") : address)
        .accessibilityLabel(name + ", " + text("display"))
        .accessibilityValue((family == .ipv4 ? "IPv4" : "IPv6") + ", " + address)
    }

    /// Prefer a complete single line, then smaller type, then wrapping.
    /// Every candidate preserves all digits, including stale observations.
    private func addressText(_ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
    }

    private func menuLabel(_ value: LineAddressFamily) -> String {
        let label = value == .ipv4 ? "IPv4" : "IPv6"
        guard isAvailable(value) else { return label + " · " + text("unavailable") }
        let valueInfo = info?.observation(for: value)
        if let valueInfo, !valueInfo.address.isEmpty { return label + " · " + valueInfo.address }
        return label + " · " + text(valueInfo?.phase == .failed ? "missing" : "query")
    }

    private func isAvailable(_ value: LineAddressFamily) -> Bool {
        if let capability {
            return value == .ipv4 ? capability.ipv4Available : capability.ipv6Available
        }
        return value == .ipv4 || !(info?.ipv6?.address.isEmpty ?? true)
    }

    private var localizationBundle: Bundle {
        let code = language == .zh ? "zh-Hans" : "en"
        return Bundle.main.path(forResource: code, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
    }
    private func text(_ key: String) -> String {
        localizationBundle.localizedString(forKey: "line.address." + key, value: nil, table: nil)
    }
}
