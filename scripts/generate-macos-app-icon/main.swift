import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs(
        "usage: generate-app-icon <AppIcon.iconset> [dock-preview.png]\n",
        stderr
    )
    exit(2)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
let representations: [(name: String, pixels: Int)] = [
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

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func writePNG(
    _ image: NSImage,
    pixels: Int,
    to url: URL
) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
}

for representation in representations {
    let pixels = representation.pixels
    try writePNG(
        AppIcon.primary(size: CGFloat(pixels), connected: true),
        pixels: pixels,
        to: outputDirectory.appendingPathComponent(representation.name)
    )
}

if CommandLine.arguments.count == 3 {
    let previewSize = 512
    try writePNG(
        AppIcon.dock(size: CGFloat(previewSize), connected: true),
        pixels: previewSize,
        to: URL(fileURLWithPath: CommandLine.arguments[2])
    )
}
