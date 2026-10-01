import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
        NSGradient(starting: NSColor(red: 0.13, green: 0.37, blue: 0.90, alpha: 1), ending: NSColor(red: 0.08, green: 0.13, blue: 0.30, alpha: 1))!.draw(in: background, angle: -60)
        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: 250, y: 375)); bridge.line(to: NSPoint(x: 512, y: 650)); bridge.line(to: NSPoint(x: 774, y: 375))
        bridge.lineWidth = 58; bridge.lineCapStyle = .round; bridge.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); bridge.stroke()
        let baseline = NSBezierPath(); baseline.move(to: NSPoint(x: 250, y: 375)); baseline.line(to: NSPoint(x: 774, y: 375))
        baseline.lineWidth = 26; NSColor.white.withAlphaComponent(0.35).setStroke(); baseline.stroke()
        for (x, y) in [(250, 375), (512, 650), (774, 375)] {
            NSColor(red: 0.50, green: 0.93, blue: 0.90, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 65, y: y - 65, width: 130, height: 130)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
