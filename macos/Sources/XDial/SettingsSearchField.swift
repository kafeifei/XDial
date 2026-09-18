import SwiftUI

/// Search fields keep the same border while focused; the insertion caret shows
/// where typing will go without adding a second outline around the control.
struct SettingsSearchField: View {
    let prompt: String
    @Binding var text: String

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(XDialPalette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(XDialPalette.divider.opacity(0.45), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .focusEffectDisabled()
    }
}
