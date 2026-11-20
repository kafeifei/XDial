import SwiftUI

/// These views have no AppState or network side effects, including in previews.
struct ScenarioRuntimeSummaryView: View {
    let title: String
    let detail: String
    let runningScenario: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let runningScenario {
                Text(runningScenario).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
