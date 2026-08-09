import AppKit
import XCTest

final class AppIconPaletteTests: XCTestCase {
    func testConnectedIconUsesSlateAndPineInsteadOfIndependentGrayScale() throws {
        let bitmap = try render(AppIcon.primary(size: 128, connected: true))
        var foundSlate = false
        var foundPine = false

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else {
                    continue
                }
                foundSlate = foundSlate || (
                    color.blueComponent > color.redComponent + 0.07
                        && color.greenComponent > color.redComponent + 0.04
                )
                foundPine = foundPine || (
                    color.greenComponent > color.redComponent + 0.08
                        && color.greenComponent > color.blueComponent + 0.025
                )
            }
        }

        XCTAssertTrue(foundSlate, "icon should contain the shared slate accent")
        XCTAssertTrue(foundPine, "connected icon should contain the shared pine status color")
    }

    func testDisconnectedIconDoesNotUseConnectedPineOutline() throws {
        let bitmap = try render(AppIcon.primary(size: 128, connected: false))
        var foundPine = false

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else {
                    continue
                }
                foundPine = foundPine || (
                    color.greenComponent > color.redComponent + 0.08
                        && color.greenComponent > color.blueComponent + 0.025
                )
            }
        }

        XCTAssertFalse(foundPine, "disconnected icon should use the neutral steel outline")
    }

    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let pixels = Int(image.size.width)
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
            throw CocoaError(.coderInvalidValue)
        }

        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
