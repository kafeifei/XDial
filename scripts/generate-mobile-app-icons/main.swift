import AppKit
import Foundation

// 用与 macOS 图标同一份 `AppIcon` / `RotaryDial` 几何生成 iOS 与 tvOS 位图资产。
// 用法：generate-mobile-app-icons <repo-root>
// 由 `make mobile-app-icons` 编译并调用；生成结果直接落到 asset catalog，需提交。

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-mobile-app-icons <repo-root>\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func writePNG(
    width: Int,
    height: Int,
    hasAlpha: Bool,
    to relativePath: String,
    draw: (NSRect) -> Void
) throws {
    // App Store 拒绝带 alpha 通道的 iOS 图标；不透明资产用 noneSkipLast 位图，
    // 编码出的 PNG 不含 alpha 通道。
    let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
    guard let cgContext = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alphaInfo.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    if !hasAlpha {
        // 先铺满底块再画内容。
        AppIcon.drawTile(in: rect, cornerRadius: 0)
    }
    draw(rect)
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = cgContext.makeImage(),
          let data = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    print("wrote \(relativePath)")
}

/// 在 `rect` 内居中放一块边长 `side` 的拨号盘网格。
func dialRect(in rect: NSRect, side: CGFloat) -> NSRect {
    NSRect(
        x: rect.midX - side / 2,
        y: rect.midY - side / 2,
        width: side,
        height: side
    )
}

// iOS：1024 满幅、不透明；系统自行裁圆角，因此拨号盘按满幅方块的比例居中。
try writePNG(
    width: 1024,
    height: 1024,
    hasAlpha: false,
    to: "ios/XDialIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
) { rect in
    AppIcon.drawDial(
        in: dialRect(in: rect, side: rect.width * AppIcon.dialGridRatio),
        connected: true
    )
}

// tvOS 分层图标：背景层满幅不透明，内容层只有拨号盘（透明），系统做视差。
let tvRoot = "appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
for scale in [1, 2] {
    let width = 400 * scale
    let height = 240 * scale
    try writePNG(
        width: width,
        height: height,
        hasAlpha: false,
        to: "\(tvRoot)/App Icon.imagestack/Back.imagestacklayer/Content.imageset/back-\(width)x\(height).png"
    ) { _ in }
    try writePNG(
        width: width,
        height: height,
        hasAlpha: true,
        to: "\(tvRoot)/App Icon.imagestack/Content.imagestacklayer/Content.imageset/appicon-\(width)x\(height).png"
    ) { rect in
        AppIcon.drawDial(
            in: dialRect(in: rect, side: rect.height * 0.78),
            connected: true
        )
    }
}

// Top Shelf：1920 × 720 不透明横幅，拨号盘居中。
try writePNG(
    width: 1920,
    height: 720,
    hasAlpha: false,
    to: "\(tvRoot)/Top Shelf Image.imageset/topshelf-1920x720.png"
) { rect in
    AppIcon.drawDial(in: dialRect(in: rect, side: 460), connected: true)
}
