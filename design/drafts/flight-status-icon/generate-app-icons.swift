import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct GenerateAppIcons {
    private static let fileManager = FileManager.default
    private static let root = URL(
        fileURLWithPath: fileManager.currentDirectoryPath,
        isDirectory: true
    )

    static func main() throws {
        if CommandLine.arguments.dropFirst().contains("--check") {
            try checkGeneratedAssets()
            return
        }
        if CommandLine.arguments.dropFirst().contains("--preview") {
            try generateStatePreview()
            return
        }

        try generateMacIcon()
        try renderPNG(
            path: "ios/XDialIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            width: 1024,
            height: 1024,
            hasAlpha: false
        ) { context, rect in
            FlightStatusGlyph.draw(
                in: context,
                rect: rect,
                state: .cruising,
                background: .square
            )
        }
        try generateTVAssets()
        try checkGeneratedAssets()
    }

    private static func generateStatePreview() throws {
        let states: [FlightVisualState] = [
            .takingOff,
            .cruising,
            .landing,
            .crashed,
        ]
        try renderPNG(
            path: "build/flight-status-preview.png",
            width: 1200,
            height: 300,
            hasAlpha: false
        ) { context, rect in
            context.setFillColor(FlightStatusGlyph.graphite)
            context.fill(rect)
            for (index, state) in states.enumerated() {
                let cell = CGRect(
                    x: CGFloat(index) * 300,
                    y: 0,
                    width: 300,
                    height: 300
                )
                FlightStatusGlyph.draw(
                    in: context,
                    rect: cell.insetBy(dx: 15, dy: 15),
                    state: state,
                    phase: 0.6,
                    background: .none
                )
            }
        }
    }

    private static func generateMacIcon() throws {
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("xdial-app-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = temporaryRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]

        for variant in variants {
            try renderPNG(
                url: iconset.appendingPathComponent(variant.name),
                width: variant.pixels,
                height: variant.pixels,
                hasAlpha: true
            ) { context, rect in
                FlightStatusGlyph.draw(
                    in: context,
                    rect: rect,
                    state: .cruising,
                    background: .squircle
                )
            }
        }

        try run(
            "/usr/bin/iconutil",
            arguments: [
                "--convert", "icns",
                "--output", root.appendingPathComponent("macos/AppIcon.icns").path,
                iconset.path,
            ]
        )
    }

    private static func generateTVAssets() throws {
        let tvRoot = "appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
        let backRoot = "\(tvRoot)/App Icon.imagestack/Back.imagestacklayer/Content.imageset"
        let contentRoot = "\(tvRoot)/App Icon.imagestack/Content.imagestacklayer/Content.imageset"

        for scale in [1, 2] {
            let width = 400 * scale
            let height = 240 * scale
            try renderPNG(
                path: "\(backRoot)/back-\(width)x\(height).png",
                width: width,
                height: height,
                hasAlpha: false
            ) { context, rect in
                context.setFillColor(FlightStatusGlyph.graphite)
                context.fill(rect)
            }
            try renderPNG(
                path: "\(contentRoot)/appicon-\(width)x\(height).png",
                width: width,
                height: height,
                hasAlpha: true
            ) { context, rect in
                let side = rect.height * 0.78
                let glyphRect = CGRect(
                    x: rect.midX - side / 2,
                    y: rect.midY - side / 2,
                    width: side,
                    height: side
                )
                FlightStatusGlyph.draw(
                    in: context,
                    rect: glyphRect,
                    state: .cruising,
                    background: .none
                )
            }
        }

        try renderPNG(
            path: "\(tvRoot)/Top Shelf Image.imageset/topshelf-1920x720.png",
            width: 1920,
            height: 720,
            hasAlpha: false
        ) { context, rect in
            context.setFillColor(FlightStatusGlyph.graphite)
            context.fill(rect)
            let side: CGFloat = 460
            FlightStatusGlyph.draw(
                in: context,
                rect: CGRect(
                    x: rect.midX - side / 2,
                    y: rect.midY - side / 2,
                    width: side,
                    height: side
                ),
                state: .cruising,
                background: .none
            )
        }
    }

    private static func renderPNG(
        path: String,
        width: Int,
        height: Int,
        hasAlpha: Bool,
        drawing: (CGContext, CGRect) -> Void
    ) throws {
        try renderPNG(
            url: root.appendingPathComponent(path),
            width: width,
            height: height,
            hasAlpha: hasAlpha,
            drawing: drawing
        )
    }

    private static func renderPNG(
        url: URL,
        width: Int,
        height: Int,
        hasAlpha: Bool,
        drawing: (CGContext, CGRect) -> Void
    ) throws {
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        ) else {
            throw GeneratorError("无法创建 \(width)x\(height) 位图")
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        drawing(
            context,
            CGRect(x: 0, y: 0, width: width, height: height)
        )

        guard let image = context.makeImage() else {
            throw GeneratorError("无法编码 \(url.lastPathComponent)")
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw GeneratorError("无法创建 \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GeneratorError("无法写入 \(url.lastPathComponent)")
        }
    }

    private static func checkGeneratedAssets() throws {
        let pngs: [(String, Int, Int, Bool)] = [
            ("ios/XDialIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", 1024, 1024, false),
            ("appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Back.imagestacklayer/Content.imageset/back-400x240.png", 400, 240, false),
            ("appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Back.imagestacklayer/Content.imageset/back-800x480.png", 800, 480, false),
            ("appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Content.imagestacklayer/Content.imageset/appicon-400x240.png", 400, 240, true),
            ("appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Content.imagestacklayer/Content.imageset/appicon-800x480.png", 800, 480, true),
            ("appletv/XDialTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/Top Shelf Image.imageset/topshelf-1920x720.png", 1920, 720, false),
        ]
        for asset in pngs {
            try checkPNG(
                path: asset.0,
                width: asset.1,
                height: asset.2,
                requiresAlpha: asset.3
            )
        }

        let icon = root.appendingPathComponent("macos/AppIcon.icns")
        guard fileManager.fileExists(atPath: icon.path) else {
            throw GeneratorError("缺少 macos/AppIcon.icns")
        }
        print("App icon assets verified")
    }

    private static func checkPNG(
        path: String,
        width: Int,
        height: Int,
        requiresAlpha: Bool
    ) throws {
        let url = root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw GeneratorError("无法读取 \(path)")
        }
        guard bitmap.pixelsWide == width, bitmap.pixelsHigh == height else {
            throw GeneratorError(
                "\(path) 尺寸为 \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)，预期 \(width)x\(height)"
            )
        }
        guard bitmap.hasAlpha == requiresAlpha else {
            throw GeneratorError(
                "\(path) 透明通道为 \(bitmap.hasAlpha)，预期 \(requiresAlpha)"
            )
        }
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GeneratorError("\(executable) 退出码 \(process.terminationStatus)")
        }
    }
}

private struct GeneratorError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
