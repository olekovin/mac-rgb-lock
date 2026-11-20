// Renders the 1024px app icon: indigo squircle, white display symbol, additive R/G/B circles on screen.
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824px body inset 100px, ~185px corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.36, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.35, alpha: 1)])!
    .draw(in: squircle, angle: -90)

// White display symbol.
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 10, width: s.width, height: s.height))

// The symbol's screen is solid white; paint it dark so additive RGB circles show.
// shortcut: screen rect measured from the rendered 470pt "display" symbol, re-measure if size/symbol changes.
let screen = NSRect(x: 276, y: 410, width: 472, height: 306)
NSColor(srgbRed: 0.04, green: 0.05, blue: 0.14, alpha: 1).setFill()
NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18).fill()

let screenCenter = CGPoint(x: screen.midX, y: screen.midY - 14)
let r: CGFloat = 88, d: CGFloat = 56
ctx.setBlendMode(.screen)
for (i, color) in [NSColor.systemRed, .systemGreen, .systemBlue].enumerated() {
    let a = CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 3
    let c = CGPoint(x: screenCenter.x + d * cos(a), y: screenCenter.y + d * sin(a))
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
