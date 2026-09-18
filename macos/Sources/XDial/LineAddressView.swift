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
                .frame(width: 76, alignment: .leading)
                .help(name)
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
            if !address.isEmpty {
                Divider()
                Button(language == .zh ? "复制地址" : "Copy address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
            }
            if failed {
                Button(text("retryLabel")) { retry(family) }
            }
        } label: {
            HStack(spacing: 6) {
                if !address.isEmpty {
                    addressText(address)
                } else if pending {
                    ProgressView().controlSize(.mini).accessibilityLabel(text("query"))
                } else {
                    Text(text(failed ? "missing" : "unavailable")).font(.system(size: 11)).lineLimit(1)
                }
                if failed { Image(systemName: "info.circle").font(.system(size: 10)) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(XDialPalette.textSecondary)
        .lineLimit(1)
        .help(address.isEmpty ? text("display") : address)
        .accessibilityLabel(name + ", " + text("display"))
        .accessibilityValue((family == .ipv4 ? "IPv4" : "IPv6") + ", " + address)
    }

    /// Full addresses remain available in the menu and clipboard, never wrapped.
    private func addressText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
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
