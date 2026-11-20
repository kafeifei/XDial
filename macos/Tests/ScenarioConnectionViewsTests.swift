import AppKit
import SwiftUI
import XCTest

final class ScenarioConnectionViewsTests: XCTestCase {
    @MainActor
    func testRuntimeSummaryRendersInBothLanguagesAndAppearances() throws {
        for english in [false, true] {
            for dark in [false, true] {
                for status in [ScenarioConnectionPresentation.inactive, .failed, .preparing, .disconnecting,
                               .reconnecting, .direct, .vpn, .routed, .unconfirmed]
                    + WakeReconnectPhase.allCases.map({ .wakeReconnecting($0) }) {
                    let tr: (String, String) -> String = { english ? $1 : $0 }
                    let content = ScenarioRuntimeSummaryView(
                        title: status.title(tr, statusText: tr("连接状态或当前任务", "Connection status or current task")),
                        detail: status.detail(tr),
                        runningScenario: tr("运行场景：公司 · 很长的自定义场景名称", "Running scenario: Office — a long custom scenario name"))
                        .padding(16)
                        .frame(width: 340)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.nsImage)
                    XCTAssertEqual(image.size.width, 340, accuracy: 1)
                    XCTAssertGreaterThan(image.size.height, 60)
                    XCTAssertLessThan(image.size.height, 240)
                }
            }
        }
    }
}
