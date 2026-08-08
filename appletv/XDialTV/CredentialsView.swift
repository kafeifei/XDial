import SwiftUI

/// AnyConnect 凭据输入。host/username 用 TextField，password 用 SecureField，
/// tvOS 上聚焦文本框并按中键会自动弹出屏幕键盘。
///
/// 配置优先从 Mac 端同步，这里是「遥控器手动输入」兜底。绑定到 profile 里
/// VPN 类型的 Line（`vpnServer/vpnUsername/vpnPassword`），通过 index binding
/// 直接写回 @Published profile，避免操作 Line 值拷贝导致丢改动。
struct CredentialsView: View {
    @EnvironmentObject private var app: AppState

    private enum Field: Hashable {
        case host, username, password
    }
    @FocusState private var focus: Field?

    var body: some View {
        Group {
            if let idx = vpnLineIndex {
                form(lineIndex: idx)
            } else {
                noVPNLine
            }
        }
        .navigationTitle(app.tr("AnyConnect 凭据", "AnyConnect Credentials"))
    }

    // MARK: - 表单

    private func form(lineIndex idx: Int) -> some View {
        Form {
            Section {
                TextField(
                    app.tr("服务器地址", "Server host"),
                    text: fieldBinding(idx, \.vpnServer)
                )
                .focused($focus, equals: .host)
                #if os(tvOS)
                .textContentType(.URL)
                #endif

                TextField(
                    app.tr("用户名", "Username"),
                    text: fieldBinding(idx, \.vpnUsername)
                )
                .focused($focus, equals: .username)
                #if os(tvOS)
                .textContentType(.username)
                #endif

                SecureField(
                    app.tr("密码", "Password"),
                    text: fieldBinding(idx, \.vpnPassword)
                )
                .focused($focus, equals: .password)
                #if os(tvOS)
                .textContentType(.password)
                #endif
            } header: {
                Text(app.tr("凭据（\(app.profile.lines[idx].name)）",
                            "Credentials (\(app.profile.lines[idx].name))"))
            } footer: {
                Text(app.tr("在电视上打字较慢，建议从 Mac 端同步。",
                            "Typing on TV is slow — prefer syncing from your Mac."))
            }

            Section {
                Button(app.tr("保存", "Save")) {
                    app.save()
                }
            }
        }
        .onAppear { focus = .host }
    }

    private var noVPNLine: some View {
        VStack(spacing: 24) {
            Image(systemName: "key.slash")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text(app.tr("没有可编辑的 AnyConnect 线路", "No AnyConnect line to edit"))
                .font(.title2)
            Text(app.tr("请先从 Mac 端同步包含 AnyConnect 线路的配置",
                        "Sync a configuration that includes an AnyConnect line from your Mac"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }

    // MARK: - 选择要编辑的 VPN 线路

    /// 选中当前 active 场景实际用到的 VPN 线路；找不到则退回第一个 VPN 类型线路。
    private var vpnLineIndex: Int? {
        if let scenario = app.activeScenario {
            var usedIDs = Set(scenario.bindings.map { $0.lineID })
            if !scenario.defaultLineID.isEmpty { usedIDs.insert(scenario.defaultLineID) }
            if let idx = app.profile.lines.firstIndex(where: {
                $0.type == "vpn" && usedIDs.contains($0.id)
            }) {
                return idx
            }
        }
        return app.profile.lines.firstIndex { $0.type == "vpn" }
    }

    /// 对 profile.lines[idx] 的某个 String 字段做双向绑定，写回 @Published profile。
    private func fieldBinding(_ idx: Int, _ key: WritableKeyPath<Line, String>) -> Binding<String> {
        Binding(
            get: {
                guard app.profile.lines.indices.contains(idx) else { return "" }
                return app.profile.lines[idx][keyPath: key]
            },
            set: { newValue in
                guard app.profile.lines.indices.contains(idx) else { return }
                app.profile.lines[idx][keyPath: key] = newValue
            }
        )
    }
}
