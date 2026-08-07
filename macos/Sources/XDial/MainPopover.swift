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
    @State private var hoveredModeID: String?
    @State private var showsConnectionInfo = true
    @State private var showsConnectionProgress = false

    private let minimumPopoverWidth: CGFloat = 340
    private let maximumModesPerRow = 5
    private let modeItemWidth: CGFloat = 72
    private let modeItemSpacing: CGFloat = 14
    private let modeHorizontalPadding: CGFloat = 24
    private let sphereDiameter: CGFloat = 64
    private let stormBlue = Color(
        red: 0.27,
        green: 0.43,
        blue: 0.60
    )
    private let mossGreen = Color(
        red: 0.30,
        green: 0.50,
        blue: 0.27
    )
    private let clayRed = Color(
        red: 0.69,
        green: 0.29,
        blue: 0.22
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeCarousel
            if showsStatusBand {
                Divider()
                statusBand
                if showsConnectionProgress,
                   state.isBusy,
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
            value: state.profile.modes.count
        )
        .background(Color(nsColor: .windowBackgroundColor))
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
            showsConnectionProgress = false
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
            return mossGreen
        }
        if state.isBusy {
            return stormBlue
        }
        if let report = state.presentedConnectionReport,
           report.error != nil || report.state == .failed {
            return clayRed
        }
        return Color.secondary.opacity(0.82)
    }

    @ViewBuilder
    private var modeCarousel: some View {
        if state.profile.modes.isEmpty {
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
                Text(state.tr("暂无模式", "No Modes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 142)
        } else {
            let indexedModes = Array(state.profile.modes.enumerated())
            let rowCount = Int(
                ceil(
                    Double(indexedModes.count)
                        / Double(maximumModesPerRow)
                )
            )
            VStack(spacing: 18) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    let start = rowIndex * maximumModesPerRow
                    let end = min(
                        indexedModes.count,
                        start + maximumModesPerRow
                    )
                    HStack(alignment: .top, spacing: modeItemSpacing) {
                        ForEach(
                            indexedModes[start..<end],
                            id: \.element.id
                        ) { indexedMode in
                            modeSphere(
                                indexedMode.element,
                                index: indexedMode.offset
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, modeHorizontalPadding)
            .padding(.vertical, 18)
        }
    }

    private var popoverWidth: CGFloat {
        let modeCount = state.profile.modes.count
        guard modeCount > 0 else { return minimumPopoverWidth }
        let columnCount = min(modeCount, maximumModesPerRow)
        let contentWidth = CGFloat(columnCount) * modeItemWidth
            + CGFloat(max(0, columnCount - 1)) * modeItemSpacing
            + modeHorizontalPadding * 2
        return max(minimumPopoverWidth, contentWidth)
    }

    private func modeSphere(_ mode: Mode, index: Int) -> some View {
        let visualState = visualState(for: mode)
        let hovered = hoveredModeID == mode.id
        return Button {
            performModeAction(mode, visualState: visualState)
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
                    progressRing(for: visualState, mode: mode)
                    Image(systemName: modeIcon(mode, index: index))
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
                Text(mode.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredModeID = hovering ? mode.id : nil
        }
        .help(actionHelp(for: mode, visualState: visualState))
        .accessibilityLabel(mode.name)
        .accessibilityHint(actionHelp(for: mode, visualState: visualState))
    }

    @ViewBuilder
    private func progressRing(
        for visualState: ModeVisualState,
        mode: Mode
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
                    stormBlue,
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
                .stroke(mossGreen, lineWidth: 4)
        case .failed:
            Circle()
                .trim(from: 0.06, to: 0.94)
                .stroke(
                    clayRed,
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
                    .fill(stormBlue)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                if let report = state.presentedConnectionReport,
                   !report.tasks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsConnectionProgress.toggle()
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
                                systemName: showsConnectionProgress
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                            .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        showsConnectionProgress
                            ? state.tr("收起连接步骤", "Hide connection steps")
                            : state.tr("展开连接步骤", "Show connection steps")
                    )
                }
            } else if state.configDirty && state.isConnected {
                Circle()
                    .fill(clayRed.opacity(0.9))
                    .frame(width: 8, height: 8)
                Text(
                    state.tr(
                        "模式配置已变化，点击目标圆球切换",
                        "Mode changed; click a sphere to switch"
                    )
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
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
                                showsConnectionInfo.toggle()
                            }
                        } label: {
                            Image(
                                systemName: showsConnectionInfo
                                    ? "chevron.down"
                                    : "chevron.right"
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(
                            showsConnectionInfo
                                ? state.tr("收起详情", "Collapse details")
                                : state.tr("展开详情", "Expand details")
                        )
                        .accessibilityLabel(
                            showsConnectionInfo
                                ? state.tr("收起详情", "Collapse details")
                                : state.tr("展开详情", "Expand details")
                        )
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if hasConnectionInfo && showsConnectionInfo {
                Divider()
                connectionOverview(report)
            }

            if let errorMessage = reportErrorMessage(in: report) {
                if hasConnectionInfo && showsConnectionInfo {
                    Divider()
                }
                factRow(
                    symbol: "exclamationmark.circle.fill",
                    text: errorMessage,
                    color: clayRed
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
                        .fill(mossGreen)
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
                        .foregroundStyle(mossGreen)
                        .lineLimit(1)
                    if mapping.error != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(clayRed)
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
                color: clayRed
            )
            Divider().padding(.leading, 24)

            factRow(
                symbol: report.rollbackComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill",
                text: rollbackFact(report),
                color: report.rollbackComplete &&
                    report.systemTakeoverRemoved
                    ? mossGreen
                    : clayRed
            )
        }
    }

    private func failureBlock(
        _ failure: FailurePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(clayRed)
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

    private var currentRuntimeModeID: String? {
        state.presentedConnectionReport?.mode.id
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
            return stormBlue
        case .ready, .committed:
            return mossGreen
        case .failed:
            return clayRed
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

    private func visualState(for mode: Mode) -> ModeVisualState {
        if let targetModeID = state.modeSwitchTargetID {
            if mode.id == targetModeID { return .connecting }
            return .idle
        }
        guard mode.id == currentRuntimeModeID else {
            return mode.id == state.profile.activeModeID
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

    private func performModeAction(
        _ mode: Mode,
        visualState: ModeVisualState
    ) {
        if let targetModeID = state.modeSwitchTargetID {
            if mode.id == targetModeID {
                state.disconnect()
            } else {
                state.switchMode(to: mode.id)
            }
            return
        }

        if mode.id != currentRuntimeModeID {
            state.switchMode(to: mode.id)
            return
        }

        switch visualState {
        case .connecting:
            state.disconnect()
        case .connected:
            state.disconnect()
        case .failed, .idle, .idleSelected:
            state.switchMode(to: mode.id)
        }
    }

    private func badge(
        for visualState: ModeVisualState,
        hovered: Bool
    ) -> ModeBadge? {
        switch visualState {
        case .idle, .idleSelected:
            return hovered
                ? ModeBadge(symbol: "play.fill", color: stormBlue)
                : nil
        case .connecting:
            return hovered
                ? ModeBadge(symbol: "xmark", color: stormBlue)
                : nil
        case .connected:
            return hovered
                ? ModeBadge(symbol: "power", color: clayRed)
                : ModeBadge(symbol: "checkmark", color: mossGreen)
        case .failed:
            return hovered
                ? ModeBadge(symbol: "arrow.clockwise", color: stormBlue)
                : ModeBadge(
                    symbol: "exclamationmark",
                    color: clayRed
                )
        }
    }

    private func actionHelp(
        for mode: Mode,
        visualState: ModeVisualState
    ) -> String {
        if let targetModeID = state.modeSwitchTargetID {
            return mode.id == targetModeID
                ? state.tr("取消切换", "Cancel switch")
                : state.tr("切换连接", "Switch connection")
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
                && mode.id != currentRuntimeModeID {
                return state.tr("切换连接", "Switch connection")
            }
            return state.tr("连接", "Connect")
        }
    }

    private func modeIcon(_ mode: Mode, index: Int) -> String {
        let normalizedName = mode.name.lowercased()
        if normalizedName.contains("vpn") {
            return "briefcase"
        }
        if normalizedName.contains("国内") ||
            normalizedName.contains("china") {
            return "globe.asia.australia"
        }
        if normalizedName.contains("公司") ||
            normalizedName.contains("office") ||
            normalizedName.contains("work") {
            return "building.2"
        }
        if normalizedName.contains("全季") ||
            normalizedName.contains("season") {
            return "leaf"
        }
        if normalizedName.contains("全代理") ||
            normalizedName.contains("global") {
            return "shield.lefthalf.filled"
        }
        let icons = [
            "briefcase",
            "globe.asia.australia",
            "building.2",
            "leaf",
            "shield.lefthalf.filled",
            "point.3.connected.trianglepath.dotted",
        ]
        return icons[index % icons.count]
    }

    private func iconColor(for visualState: ModeVisualState) -> Color {
        switch visualState {
        case .connected:
            mossGreen
        case .failed:
            clayRed
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
        guard let mode = state.profile.modes.first(where: {
            $0.id == report.mode.id
        }) else {
            return []
        }

        var mappings = mode.bindings.map { binding in
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

        if !mode.defaultLineID.isEmpty
            || !mode.defaultSubscriptionID.isEmpty {
            mappings.append(
                PolicyMapping(
                    id: "default",
                    ruleName: state.tr("其他流量", "Other Traffic"),
                    lineName: policyTargetName(
                        lineID: mode.defaultLineID,
                        subscriptionID: mode.defaultSubscriptionID
                    ),
                    error: lineError(
                        lineID: mode.defaultLineID,
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

private enum ModeVisualState {
    case idle
    case idleSelected
    case connecting
    case connected
    case failed
}

private struct ModeBadge {
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
