import AppKit
import SwiftUI

private struct PolicyMapping: Identifiable {
    let id: String
    let ruleName: String
    let lineName: String
    let error: ConnectionReportError?
}

private struct FailurePresentation {
    let title: String
    let detail: String?
}

struct MainPopover: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var networkInfo = NetworkInfo.shared
    @StateObject private var trafficInfo = TrafficInfo()
    @State private var hoveredScenarioID: String?
    @State private var showsConnectionDetails = true

    private let minimumPopoverWidth: CGFloat = 340
    private let maximumScenariosPerRow = 4
    private let scenarioItemWidth: CGFloat = 72
    private let scenarioItemSpacing: CGFloat = 14
    private let scenarioHorizontalPadding: CGFloat = 24
    private let sphereDiameter: CGFloat = 64
    private let actionColor = XDialPalette.primaryAction
    private let progressColor = XDialPalette.progress
    private let successColor = XDialPalette.success
    private let dangerColor = XDialPalette.danger
    private let warningColor = XDialPalette.warning

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scenarioCarousel
            if showsStatusBand {
                Divider()
                statusBand
                if showsConnectionDetails,
                   state.isBusy,
                   state.scenarioSwitchTargetID == nil,
                   let report = state.presentedConnectionReport,
                   !report.tasks.isEmpty {
                    Divider()
                        .padding(.horizontal, 20)
                    connectionProgressDetails(report)
                }
            }
            if let report = expandableReport {
                Divider()
                details(report)
            }
        }
        .frame(width: popoverWidth)
        .animation(
            .easeInOut(duration: 0.2),
            value: state.profile.scenarios.count
        )
        .background(XDialPalette.elevated)
        .contextMenu {
            Button(state.tr("安装状态…", "Installation Status…")) {
                state.installation.present()
            }
            Divider()
            Button(state.tr("退出 XDial", "Quit XDial")) {
                NSApp.terminate(nil)
            }
        }
        .onAppear { synchronizeTrafficSampling() }
        .onDisappear { trafficInfo.stop() }
        .onChange(of: state.engine.status) {
            synchronizeTrafficSampling()
        }
        .onChange(of: state.presentedConnectionReport?.transactionID) {
            synchronizeTrafficSampling()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("XDial")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.25)
                if state.isConnected,
                   let connectedAt = state.engine.connectedAt {
                    Circle()
                        .fill(headerAccent.opacity(0.72))
                        .frame(width: 3.5, height: 3.5)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(
                            formatDuration(
                                Int(
                                    context.date.timeIntervalSince(
                                        connectedAt
                                    )
                                )
                            )
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .foregroundStyle(headerAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            headerAccent.opacity(0.12),
                            in: Capsule()
                        )
                    }
                }
            }
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.82))
            .help(state.tr("设置", "Settings"))
            .accessibilityLabel(state.tr("设置", "Settings"))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background {
            LinearGradient(
                colors: [
                    headerAccent.opacity(0.09),
                    headerAccent.opacity(0.025),
                    Color.clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var headerAccent: Color {
        if state.isConnected {
            return successColor
        }
        if state.isBusy {
            return progressColor
        }
        if let report = state.presentedConnectionReport,
           report.error != nil || report.state == .failed {
            return dangerColor
        }
        return Color.secondary.opacity(0.82)
    }

    @ViewBuilder
    private var scenarioCarousel: some View {
        if state.profile.scenarios.isEmpty {
            VStack(spacing: 7) {
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: sphereDiameter, height: sphereDiameter)
                    .overlay {
                        Image(systemName: "circle.dashed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                Text(state.tr("暂无场景", "No Scenarios"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 142)
        } else {
            let indexedScenarios = Array(state.profile.scenarios.enumerated())
            let columnCount = scenarioColumnCount
            let rowCount = Int(
                ceil(
                    Double(indexedScenarios.count)
                        / Double(columnCount)
                )
            )
            VStack(spacing: 18) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    let start = rowIndex * columnCount
                    let end = min(
                        indexedScenarios.count,
                        start + columnCount
                    )
                    HStack(alignment: .top, spacing: scenarioItemSpacing) {
                        ForEach(
                            indexedScenarios[start..<end],
                            id: \.element.id
                        ) { indexedScenario in
                            scenarioSphere(indexedScenario.element)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, scenarioHorizontalPadding)
            .padding(.vertical, 18)
        }
    }

    private var popoverWidth: CGFloat {
        let scenarioCount = state.profile.scenarios.count
        guard scenarioCount > 0 else { return minimumPopoverWidth }
        let columnCount = scenarioColumnCount
        let contentWidth = CGFloat(columnCount) * scenarioItemWidth
            + CGFloat(max(0, columnCount - 1)) * scenarioItemSpacing
            + scenarioHorizontalPadding * 2
        return max(minimumPopoverWidth, contentWidth)
    }

    /// 先以每行最多四个求出不可避免的最少行数，再把项目均匀分到这些行。
    /// 这样 5 个是 3+2，6 个是 3+3，不会因为新增一行仍保持四列宽。
    private var scenarioColumnCount: Int {
        ScenarioGridLayout.columnCount(
            itemCount: state.profile.scenarios.count,
            maximumPerRow: maximumScenariosPerRow
        )
    }

    private func scenarioSphere(_ scenario: Scenario) -> some View {
        let visualState = visualState(for: scenario)
        let hovered = hoveredScenarioID == scenario.id
        return Button {
            performScenarioAction(scenario, visualState: visualState)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.025))
                    Circle()
                        .stroke(
                            Color.secondary.opacity(0.34),
                            lineWidth: 1.2
                        )
                    progressRing(for: visualState, scenario: scenario)
                    Image(systemName: scenarioIcon(scenario))
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(iconColor(for: visualState))
                }
                .frame(width: sphereDiameter, height: sphereDiameter)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = badge(
                        for: visualState,
                        hovered: hovered
                    ) {
                        Image(systemName: badge.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(badge.color, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color(nsColor: .windowBackgroundColor),
                                        lineWidth: 2
                                    )
                            }
                    }
                }
                Text(scenario.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredScenarioID = hovering ? scenario.id : nil
        }
        .help(actionHelp(for: scenario, visualState: visualState))
        .accessibilityLabel(scenario.name)
        .accessibilityHint(actionHelp(for: scenario, visualState: visualState))
    }

    @ViewBuilder
    private func progressRing(
        for visualState: ScenarioVisualState,
        scenario: Scenario
    ) -> some View {
        switch visualState {
        case .idleSelected:
            Circle()
                .stroke(Color.secondary.opacity(0.48), lineWidth: 3)
        case .idle:
            EmptyView()
        case .connecting:
            Circle()
                .stroke(
                    Color.secondary.opacity(0.34),
                    style: StrokeStyle(lineWidth: 4, dash: [8, 4])
                )
            Circle()
                .trim(from: 0, to: max(0.035, connectionProgress))
                .stroke(
                    progressColor,
                    style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .butt
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(
                    .easeInOut(duration: 0.25),
                    value: connectionProgress
                )
        case .connected:
            Circle()
                .stroke(successColor, lineWidth: 4)
        case .failed:
            Circle()
                .trim(from: 0.06, to: 0.94)
                .stroke(
                    dangerColor,
                    style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .butt
                    )
                )
                .rotationEffect(.degrees(-90))
        }
    }

    private var statusBand: some View {
        HStack(spacing: 8) {
            if state.isBusy {
                Circle()
                    .fill(progressColor)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                if let report = state.presentedConnectionReport,
                   !report.tasks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsConnectionDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(
                                state.tr(
                                    "连接进度",
                                    "Connection progress"
                                )
                            )
                            Text(
                                "\(completedTaskCount(in: report))/"
                                    + "\(report.tasks.count)"
                            )
                            .monospacedDigit()
                            Image(
                                systemName: connectionDetailsSymbol
                            )
                            .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        connectionDetailsActionLabel
                    )
                    .accessibilityLabel(connectionDetailsActionLabel)
                }
            } else if state.configDirty && state.isConnected {
                if state.canConnect {
                    Button { state.reconnect() } label: {
                        dirtyStatusRow(showsAction: true)
                    }
                    .buttonStyle(.plain)
                    .help(
                        state.tr(
                            "应用已保存配置并重连",
                            "Apply saved changes and reconnect"
                        )
                    )
                    .accessibilityLabel(
                        state.tr(
                            "修改已保存，当前连接尚未应用",
                            "Saved changes are not applied"
                        )
                    )
                    .accessibilityHint(
                        state.tr(
                            "按下以应用配置并重连",
                            "Press to apply the configuration and reconnect"
                        )
                    )
                } else {
                    dirtyStatusRow(showsAction: false)
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            if state.configDirty && state.isConnected && !state.isBusy {
                LinearGradient(
                    colors: [
                        warningColor.opacity(0.075),
                        warningColor.opacity(0.025),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    private func dirtyStatusRow(showsAction: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    state.tr(
                        "修改已保存，当前连接尚未应用",
                        "Saved changes are not applied"
                    )
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                if !showsAction {
                    Text(dirtyConfigurationBlocker)
                        .font(.system(size: 9.5))
                        .foregroundStyle(warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsAction {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(actionColor)
                    .frame(width: 28, height: 28)
                    .background(actionColor.opacity(0.09), in: Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var dirtyConfigurationBlocker: String {
        if !state.installation.isReady {
            return state.tr("请先完成安装", "Complete setup first")
        }
        if state.activeScenario == nil {
            return state.tr("请先选择场景", "Choose a scenario first")
        }
        return state.tr(
            "请先完善当前场景",
            "Complete the current scenario first"
        )
    }

    private func connectionProgressDetails(
        _ report: ConnectionReport
    ) -> some View {
        FlowLayout(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(report.tasks) { task in
                let color = progressStepColor(task.state)
                HStack(spacing: 5) {
                    Image(systemName: progressStepSymbol(task.state))
                        .font(.system(size: 8, weight: .semibold))
                    Text(task.name)
                        .fontWeight(.medium)
                    Text(progressStepStateText(task.state))
                        .foregroundStyle(color.opacity(0.84))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(color.opacity(0.085), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(color.opacity(0.18), lineWidth: 0.5)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsStatusBand: Bool {
        state.isBusy || (state.configDirty && state.isConnected)
    }

    private var connectionDetailsSymbol: String {
        showsConnectionDetails ? "chevron.down" : "chevron.right"
    }

    private var connectionDetailsActionLabel: String {
        showsConnectionDetails
            ? state.tr("收起详情", "Collapse details")
            : state.tr("展开详情", "Expand details")
    }

    @ViewBuilder
    private func details(_ report: ConnectionReport) -> some View {
        if state.isConnected && report.state == .committed {
            connectedDetails(report)
        } else {
            failedDetails(report)
        }
    }

    private func connectedDetails(_ report: ConnectionReport) -> some View {
        let hasConnectionInfo = !lineTasks(in: report).isEmpty
            || !policyMappings(in: report).isEmpty
        return VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 0) {
                    metric(
                        symbol: "arrow.down",
                        value: formatRate(
                            trafficInfo.downloadBytesPerSecond
                        )
                    )
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 7)
                    metric(
                        symbol: "arrow.up",
                        value: formatRate(
                            trafficInfo.uploadBytesPerSecond
                        )
                    )
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    Color.primary.opacity(0.032),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            Color.primary.opacity(0.055),
                            lineWidth: 0.5
                        )
                }

                HStack {
                    Spacer(minLength: 0)
                    if hasConnectionInfo {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsConnectionDetails.toggle()
                            }
                        } label: {
                            Image(
                                systemName: connectionDetailsSymbol
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(connectionDetailsActionLabel)
                        .accessibilityLabel(connectionDetailsActionLabel)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if hasConnectionInfo && showsConnectionDetails {
                Divider()
                connectionOverview(report)
            }

            if let errorMessage = reportErrorMessage(in: report) {
                if hasConnectionInfo && showsConnectionDetails {
                    Divider()
                }
                factRow(
                    symbol: "exclamationmark.circle.fill",
                    text: errorMessage,
                    color: dangerColor
                )
            }
        }
    }

    private func connectionOverview(
        _ report: ConnectionReport
    ) -> some View {
        let hasLines = !lineTasks(in: report).isEmpty
        let hasPolicies = !policyMappings(in: report).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if hasLines {
                lineOverview(report)
            }
            if hasLines && hasPolicies {
                Divider()
                    .opacity(0.55)
            }
            if hasPolicies {
                policyOverview(report)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func lineOverview(_ report: ConnectionReport) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 6,
            verticalSpacing: 6
        ) {
            ForEach(lineTasks(in: report)) { task in
                GridRow {
                    Circle()
                        .fill(successColor)
                        .frame(width: 7, height: 7)
                    Text(task.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(lineSummary(task, report: report))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func policyOverview(_ report: ConnectionReport) -> some View {
        let mappings = policyMappings(in: report)
        let columns = [
            GridItem(.flexible(), spacing: 16, alignment: .leading),
            GridItem(.flexible(), alignment: .leading),
        ]
        return LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(mappings) { mapping in
                HStack(spacing: 5) {
                    Text(mapping.ruleName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(mapping.lineName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(successColor)
                        .lineLimit(1)
                    if mapping.error != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(dangerColor)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .help(
                    mapping.error?.message
                        ?? "\(mapping.ruleName) → \(mapping.lineName)"
                    )
            }
        }
    }

    private func failedDetails(_ report: ConnectionReport) -> some View {
        let failure = failurePresentation(report)
        return VStack(spacing: 0) {
            failureBlock(failure)
            Divider().padding(.leading, 24)

            let ingress = report.tasks.first { $0.kind == "ingress" }
            factRow(
                symbol: "circle.fill",
                text: ingressFact(ingress),
                color: dangerColor
            )
            Divider().padding(.leading, 24)

            factRow(
                symbol: report.rollbackComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill",
                text: rollbackFact(report),
                color: report.rollbackComplete &&
                    report.systemTakeoverRemoved
                    ? successColor
                    : dangerColor
            )
        }
    }

    private func failureBlock(
        _ failure: FailurePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dangerColor)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = failure.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func failurePresentation(
        _ report: ConnectionReport
    ) -> FailurePresentation {
        let error = report.error
        let rawMessage = error?.message
            ?? state.engine.lastError
            ?? state.tr("连接失败", "Connection failed")
        let taskName = error.flatMap { failure in
            report.tasks.first { $0.id == failure.taskID }?.name
        }?.trimmingCharacters(in: .whitespacesAndNewlines)

        let reason: String
        if rawMessage.localizedCaseInsensitiveContains("SERVFAIL")
            || rawMessage.localizedCaseInsensitiveContains("lookup ") {
            reason = state.tr(
                "服务器域名解析失败",
                "Server name resolution failed"
            )
        } else if rawMessage.localizedCaseInsensitiveContains(
            "context deadline exceeded"
        ) || rawMessage.localizedCaseInsensitiveContains("timed out") {
            reason = state.tr(
                "连接服务器超时",
                "Server connection timed out"
            )
        } else if rawMessage.localizedCaseInsensitiveContains(
            "connection refused"
        ) {
            reason = state.tr(
                "服务器拒绝连接",
                "Server refused the connection"
            )
        } else if rawMessage.localizedCaseInsensitiveContains("certificate")
            || rawMessage.localizedCaseInsensitiveContains("tls handshake") {
            reason = state.tr("TLS 验证失败", "TLS verification failed")
        } else if error?.code == ProxyResourceReadiness.lineFailureCode {
            reason = state.tr(
                "真实出口检查失败",
                "Real egress check failed"
            )
        } else if error?.code
            == ProxyResourceReadiness.subscriptionFailureCode {
            reason = state.tr(
                "订阅出口检查失败",
                "Subscription egress check failed"
            )
        } else {
            reason = state.tr("连接失败", "Connection failed")
        }

        let title: String
        if let taskName, !taskName.isEmpty {
            title = "\(taskName)：\(reason)"
        } else {
            title = reason
        }
        return FailurePresentation(
            title: title,
            detail: rawMessage == title ? nil : rawMessage
        )
    }

    private func metric(symbol: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func factRow(
        symbol: String,
        text: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
    }

    private var currentRuntimeScenarioID: String? {
        state.presentedConnectionReport?.scenario.id
    }

    private var expandableReport: ConnectionReport? {
        guard let report = state.presentedConnectionReport else {
            return nil
        }
        if state.isConnected && report.state == .committed {
            return report
        }
        if report.error != nil || report.state == .failed {
            return report
        }
        return nil
    }

    private var connectionProgress: Double {
        // During a staged Switch the committed report still describes the
        // source generation. It must never be presented as candidate progress.
        guard state.scenarioSwitchTargetID == nil else { return 0 }
        guard let report = state.presentedConnectionReport,
              !report.tasks.isEmpty else {
            return 0
        }
        let total = Double(report.tasks.count)
        let progress = report.tasks.reduce(0.0) { partial, task in
            partial + taskProgress(task.state)
        }
        return min(1, max(0, progress / total))
    }

    private func taskProgress(_ taskState: ConnectionTaskState) -> Double {
        switch taskState {
        case .ready, .committed, .rolledBack, .skipped:
            return 1
        case .running, .committing, .rollingBack:
            return 0.5
        case .failed:
            return 0.75
        case .pending:
            return 0
        }
    }

    private func completedTaskCount(in report: ConnectionReport) -> Int {
        report.tasks.filter {
            switch $0.state {
            case .ready, .committed, .rolledBack, .skipped:
                true
            default:
                false
            }
        }.count
    }

    private func progressStepSymbol(
        _ taskState: ConnectionTaskState
    ) -> String {
        switch taskState {
        case .pending:
            return "circle"
        case .running, .committing:
            return "ellipsis"
        case .ready, .committed:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        case .rollingBack:
            return "arrow.uturn.backward"
        case .rolledBack:
            return "arrow.uturn.backward.circle"
        case .skipped:
            return "minus"
        }
    }

    private func progressStepColor(
        _ taskState: ConnectionTaskState
    ) -> Color {
        switch taskState {
        case .pending, .skipped:
            return Color.secondary.opacity(0.72)
        case .running, .committing:
            return progressColor
        case .ready, .committed:
            return successColor
        case .failed:
            return dangerColor
        case .rollingBack, .rolledBack:
            return Color.secondary.opacity(0.82)
        }
    }

    private func progressStepStateText(
        _ taskState: ConnectionTaskState
    ) -> String {
        switch taskState {
        case .pending:
            return state.tr("等待", "Waiting")
        case .running:
            return state.tr("进行中", "Running")
        case .ready:
            return state.tr("就绪", "Ready")
        case .failed:
            return state.tr("失败", "Failed")
        case .committing:
            return state.tr("提交中", "Committing")
        case .committed:
            return state.tr("已提交", "Committed")
        case .rollingBack:
            return state.tr("回滚中", "Rolling back")
        case .rolledBack:
            return state.tr("已回滚", "Rolled back")
        case .skipped:
            return state.tr("已跳过", "Skipped")
        }
    }

    private func visualState(for scenario: Scenario) -> ScenarioVisualState {
        if let targetScenarioID = state.scenarioSwitchTargetID {
            if scenario.id == targetScenarioID { return .connecting }
            if scenario.id == currentRuntimeScenarioID,
               state.isConnected {
                return .connected
            }
            return .idle
        }
        guard scenario.id == currentRuntimeScenarioID else {
            return scenario.id == state.profile.activeScenarioID
                ? .idleSelected
                : .idle
        }
        if state.isConnected { return .connected }
        if state.isBusy { return .connecting }
        if let report = state.presentedConnectionReport,
           report.error != nil || report.state == .failed {
            return .failed
        }
        return .idleSelected
    }

    private func performScenarioAction(
        _ scenario: Scenario,
        visualState: ScenarioVisualState
    ) {
        if let targetScenarioID = state.scenarioSwitchTargetID {
            if scenario.id == targetScenarioID {
                state.cancelPendingScenarioSwitch()
            } else if scenario.id == currentRuntimeScenarioID,
                      state.isConnected {
                state.disconnect()
            } else {
                state.switchScenario(to: scenario.id)
            }
            return
        }

        if !state.isConnected && !state.isBusy {
            state.connectScenario(scenario.id)
            return
        }

        if scenario.id != currentRuntimeScenarioID {
            state.switchScenario(to: scenario.id)
            return
        }

        switch visualState {
        case .connecting:
            state.disconnect()
        case .connected:
            state.disconnect()
        case .failed, .idle, .idleSelected:
            state.switchScenario(to: scenario.id)
        }
    }

    private func badge(
        for visualState: ScenarioVisualState,
        hovered: Bool
    ) -> ScenarioBadge? {
        switch visualState {
        case .idle, .idleSelected:
            return hovered
                ? ScenarioBadge(symbol: "play.fill", color: actionColor)
                : nil
        case .connecting:
            return hovered
                ? ScenarioBadge(symbol: "xmark", color: actionColor)
                : nil
        case .connected:
            return hovered
                ? ScenarioBadge(symbol: "power", color: dangerColor)
                : ScenarioBadge(symbol: "checkmark", color: successColor)
        case .failed:
            return hovered
                ? ScenarioBadge(symbol: "arrow.clockwise", color: actionColor)
                : ScenarioBadge(
                    symbol: "exclamationmark",
                    color: dangerColor
                )
        }
    }

    private func actionHelp(
        for scenario: Scenario,
        visualState: ScenarioVisualState
    ) -> String {
        if let targetScenarioID = state.scenarioSwitchTargetID {
            if scenario.id == targetScenarioID {
                return state.tr("取消切换", "Cancel switch")
            }
            if scenario.id == currentRuntimeScenarioID,
               state.isConnected {
                return state.tr("断开", "Disconnect")
            }
            return state.tr("切换连接", "Switch connection")
        }
        switch visualState {
        case .connecting:
            return state.tr("取消连接", "Cancel connection")
        case .connected:
            return state.tr("断开", "Disconnect")
        case .failed:
            return state.tr("重试", "Retry")
        case .idle, .idleSelected:
            if (state.isConnected || state.isBusy)
                && scenario.id != currentRuntimeScenarioID {
                return state.tr("切换连接", "Switch connection")
            }
            return state.tr("连接", "Connect")
        }
    }

    private func scenarioIcon(_ scenario: Scenario) -> String {
        ScenarioIconCatalog.resolvedPreset(for: scenario).symbol
    }

    private func iconColor(for visualState: ScenarioVisualState) -> Color {
        switch visualState {
        case .connected:
            successColor
        case .failed:
            dangerColor
        default:
            Color.primary.opacity(0.84)
        }
    }

    private func lineTasks(
        in report: ConnectionReport
    ) -> [ConnectionTaskReport] {
        report.tasks.filter { $0.kind == "line" }
    }

    private func policyMappings(
        in report: ConnectionReport
    ) -> [PolicyMapping] {
        guard let scenario = state.profile.scenarios.first(where: {
            $0.id == report.scenario.id
        }) else {
            return []
        }

        var mappings = scenario.bindings.map { binding in
            let ruleName = state.profile.ruleSets.first {
                $0.id == binding.ruleSetID
            }?.name ?? binding.ruleSetID
            return PolicyMapping(
                id: "rule:\(binding.ruleSetID)",
                ruleName: ruleName,
                lineName: policyTargetName(
                    lineID: binding.lineID,
                    subscriptionID: binding.subscriptionID
                ),
                error: policyError(binding, in: report)
            )
        }

        if !scenario.defaultLineID.isEmpty
            || !scenario.defaultSubscriptionID.isEmpty {
            mappings.append(
                PolicyMapping(
                    id: "default",
                    ruleName: state.tr("其他流量", "Other Traffic"),
                    lineName: policyTargetName(
                        lineID: scenario.defaultLineID,
                        subscriptionID: scenario.defaultSubscriptionID
                    ),
                    error: lineError(
                        lineID: scenario.defaultLineID,
                        in: report
                    )
                )
            )
        }
        return mappings
    }

    private func policyTargetName(
        lineID: String,
        subscriptionID: String
    ) -> String {
        if !subscriptionID.isEmpty {
            return state.profile.subscriptions.first {
                $0.id == subscriptionID
            }?.name ?? subscriptionID
        }
        return state.profile.lines.first {
            $0.id == lineID
        }?.name ?? lineID
    }

    private func policyError(
        _ binding: RuleBinding,
        in report: ConnectionReport
    ) -> ConnectionReportError? {
        report.tasks.first {
            $0.kind == "rule_set"
                && $0.resourceID == binding.ruleSetID
        }?.error ?? lineError(lineID: binding.lineID, in: report)
    }

    private func lineError(
        lineID: String,
        in report: ConnectionReport
    ) -> ConnectionReportError? {
        guard !lineID.isEmpty else { return nil }
        return report.tasks.first {
            $0.kind == "line" && $0.resourceID == lineID
        }?.error
    }

    private func reportErrorMessage(
        in report: ConnectionReport
    ) -> String? {
        report.error?.message
            ?? report.tasks.compactMap { $0.error?.message }.first
    }

    private func lineSummary(
        _ task: ConnectionTaskReport,
        report: ConnectionReport
    ) -> String {
        networkInfo.observation(
            for: task.resourceID,
            transactionID: report.transactionID
        )?.summary.nonEmpty ?? "—"
    }

    private func ingressFact(
        _ task: ConnectionTaskReport?
    ) -> String {
        guard let task else {
            return state.tr(
                "系统接管状态不可用",
                "System takeover state unavailable"
            )
        }
        switch task.state {
        case .committed:
            return state.tr(
                "系统接管已提交",
                "System takeover committed"
            )
        case .rolledBack:
            return state.tr(
                "系统接管已撤销",
                "System takeover removed"
            )
        default:
            return state.tr(
                "系统接管未提交",
                "System takeover not committed"
            )
        }
    }

    private func rollbackFact(_ report: ConnectionReport) -> String {
        if report.rollbackComplete && report.systemTakeoverRemoved {
            return state.tr(
                "已回滚，原网络可用",
                "Rolled back; original network available"
            )
        }
        if let rollbackError = report.rollbackError {
            return rollbackError.message
        }
        return state.tr(
            "回滚状态尚未确认",
            "Rollback state not confirmed"
        )
    }

    private func synchronizeTrafficSampling() {
        guard
            state.isConnected,
            let report = state.presentedConnectionReport,
            report.state == .committed
        else {
            trafficInfo.stop()
            return
        }
        trafficInfo.start(
            transactionID: report.transactionID,
            engine: state.engine
        )
    }

    private func formatRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond >= 0 else {
            return "—"
        }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1_000 && unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func formatDuration(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        let remainingSeconds = safeSeconds % 60
        return String(
            format: "%02d:%02d:%02d",
            hours,
            minutes,
            remainingSeconds
        )
    }
}

private enum ScenarioVisualState {
    case idle
    case idleSelected
    case connecting
    case connected
    case failed
}

private struct ScenarioBadge {
    let symbol: String
    let color: Color
}

private struct FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let availableWidth = proposal.width
            ?? sizes.reduce(0) { $0 + $1.width }
                + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
        return arrangement(
            sizes: sizes,
            availableWidth: availableWidth
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = arrangement(
            sizes: sizes,
            availableWidth: bounds.width
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.origins[index].x,
                    y: bounds.minY + result.origins[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func arrangement(
        sizes: [CGSize],
        availableWidth: CGFloat
    ) -> (size: CGSize, origins: [CGPoint]) {
        guard !sizes.isEmpty else { return (.zero, []) }
        let lineWidth = max(0, availableWidth)
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > lineWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, max(0, x - horizontalSpacing))
        }
        return (
            CGSize(width: min(usedWidth, lineWidth), height: y + rowHeight),
            origins
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
