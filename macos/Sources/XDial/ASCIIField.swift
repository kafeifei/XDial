import SwiftUI

extension String {
    /// 把全角 ASCII（U+FF01-U+FF5E）转半角，全角空格转半角空格。
    /// 用于密码、URL、服务器地址等只允许 ASCII 的字段。
    func normalizedASCII() -> String {
        var out = ""
        out.reserveCapacity(self.unicodeScalars.count)
        for ch in self.unicodeScalars {
            let v = ch.value
            if v >= 0xFF01 && v <= 0xFF5E {
                if let s = Unicode.Scalar(v - 0xFEE0) {
                    out.append(Character(s))
                }
            } else if v == 0x3000 {
                out.append(" ")
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

/// 只接受 ASCII 的明文字段。输入全角字符时自动转半角。
struct ASCIITextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .autocorrectionDisabled(true)
            .onChange(of: text) { _, newValue in
                let n = newValue.normalizedASCII()
                if n != newValue { text = n }
            }
    }
}

/// 只接受 ASCII 的密码字段，带眼睛按钮可切换显隐。
struct ASCIISecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .autocorrectionDisabled(true)
            .onChange(of: text) { _, newValue in
                let n = newValue.normalizedASCII()
                if n != newValue { text = n }
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "隐藏" : "显示")
        }
    }
}
