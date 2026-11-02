// Draws the 1024×1024 app icon: a display with a blacked-out screen (moon and stars) and an
// agent's cursor still at work. Usage: swift make-icon.swift <out.png>
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Background squircle (macOS icon grid: 824pt body inset 100pt), with a soft drop shadow.
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = rgb(0, 0, 0, 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0.08, 0.09, 0.18).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0.20, 0.24, 0.44), ending: rgb(0.05, 0.06, 0.14))!.draw(in: body, angle: -90)

// Display: silver frame, stand and base.
let frame = NSRect(x: 512 - 310, y: 390, width: 620, height: 380)
let neck = NSRect(x: 512 - 48, y: 300, width: 96, height: 100)
let base = NSRect(x: 512 - 140, y: 282, width: 280, height: 30)
let silver = NSGradient(starting: rgb(0.93, 0.94, 0.96), ending: rgb(0.62, 0.64, 0.69))!
silver.draw(in: NSBezierPath(rect: neck), angle: -90)
silver.draw(in: NSBezierPath(roundedRect: base, xRadius: 15, yRadius: 15), angle: -90)
NSGraphicsContext.saveGraphicsState()
let frameShadow = NSShadow()
frameShadow.shadowColor = rgb(0, 0, 0, 0.45)
frameShadow.shadowOffset = NSSize(width: 0, height: -10)
frameShadow.shadowBlurRadius = 24
frameShadow.set()
rgb(0.8, 0.81, 0.84).setFill()
NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).fill()
NSGraphicsContext.restoreGraphicsState()
silver.draw(in: NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30), angle: -90)

// Screen: blacked out.
let screen = frame.insetBy(dx: 22, dy: 22)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 12, yRadius: 12)
let screenTop = rgb(0.05, 0.06, 0.10), screenBottom = rgb(0.01, 0.01, 0.03)
NSGradient(starting: screenTop, ending: screenBottom)!.draw(in: screenPath, angle: -90)

NSGraphicsContext.saveGraphicsState()
screenPath.addClip()

// Crescent moon: a disc with a second disc cut out of it.
let moonC = NSPoint(x: screen.midX - 60, y: screen.midY + 20)
let r: CGFloat = 92
let moon = NSBezierPath(ovalIn: NSRect(x: moonC.x - r, y: moonC.y - r, width: 2 * r, height: 2 * r))
let bite = NSBezierPath(ovalIn: NSRect(x: moonC.x - r + 52, y: moonC.y - r + 34, width: 2 * r, height: 2 * r))
NSGraphicsContext.saveGraphicsState()
let outsideBite = NSBezierPath(rect: screen)  // everything on screen except the bite
outsideBite.append(bite)
outsideBite.windingRule = .evenOdd
outsideBite.addClip()
let glow = NSShadow()
glow.shadowColor = rgb(1.0, 0.82, 0.45, 0.55)
glow.shadowBlurRadius = 40
glow.set()
NSGradient(starting: rgb(1.0, 0.92, 0.66), ending: rgb(0.98, 0.76, 0.36))!.draw(in: moon, angle: -60)
NSGraphicsContext.restoreGraphicsState()

// Stars.
for (x, y, s) in [(110.0, 260.0, 9.0), (420.0, 280.0, 7.0), (470.0, 170.0, 10.0), (90.0, 90.0, 6.0), (330.0, 70.0, 5.0)] {
    rgb(0.85, 0.88, 1.0, 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: screen.minX + x, y: screen.minY + y, width: s, height: s)).fill()
}

// The agent's cursor, still working on the dark screen.
let tip = NSPoint(x: screen.maxX - 150, y: screen.minY + 150)
let k: CGFloat = 5.2  // arrow drawn on a 0…22 grid
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -21), (5, -16.5), (8.5, -24), (12, -22.5), (8.6, -15.2), (15, -15.2)]
let arrow = NSBezierPath()
for (i, p) in pts.enumerated() {
    let q = NSPoint(x: tip.x + p.0 * k, y: tip.y + p.1 * k)
    i == 0 ? arrow.move(to: q) : arrow.line(to: q)
}
arrow.close()
arrow.lineJoinStyle = .round
NSGraphicsContext.saveGraphicsState()
let cursorGlow = NSShadow()
cursorGlow.shadowColor = rgb(0.35, 0.85, 1.0, 0.7)
cursorGlow.shadowBlurRadius = 26
cursorGlow.set()
rgb(0.36, 0.86, 1.0).setFill()
arrow.fill()
NSGraphicsContext.restoreGraphicsState()
arrow.lineWidth = 9
rgb(1, 1, 1).setStroke()
arrow.stroke()
rgb(0.36, 0.86, 1.0).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

// Glass highlight across the top of the screen.
NSGraphicsContext.saveGraphicsState()
screenPath.addClip()
let sheen = NSBezierPath()
sheen.move(to: NSPoint(x: screen.minX, y: screen.maxY))
sheen.line(to: NSPoint(x: screen.minX + screen.width * 0.55, y: screen.maxY))
sheen.line(to: NSPoint(x: screen.minX, y: screen.maxY - screen.height * 0.75))
sheen.close()
NSGradient(starting: rgb(1, 1, 1, 0.07), ending: rgb(1, 1, 1, 0))!.draw(in: sheen, angle: -45)
NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
