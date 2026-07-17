// Generates the Cadence Doctor app icon (1024x1024 PNG).
// Motif: a cadence/pulse trace running over a row of film frames,
// with one dropped (dashed) frame under the spike — the defect the app finds.
import AppKit
import CoreGraphics

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let accent = rgba(0.38, 0.72, 0.98)
let amber  = rgba(0.98, 0.72, 0.28)

// --- Background rounded rect with shadow ---
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin)
let bgPath = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 42, color: rgba(0, 0, 0, 0.55))
ctx.addPath(bgPath)
ctx.setFillColor(rgba(0.08, 0.09, 0.12))
ctx.fillPath()
ctx.restoreGState()

// Gradient fill
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgba(0.135, 0.155, 0.215), rgba(0.045, 0.055, 0.085)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Faint horizontal scanlines
ctx.setFillColor(rgba(1, 1, 1, 0.018))
var y: CGFloat = 130
while y < 900 { ctx.fill(CGRect(x: margin, y: y, width: rect.width, height: 3)); y += 46 }

// --- Film frame row (bottom third). Frame 4 of 5 is the dropped one. ---
let frameW: CGFloat = 118, frameH: CGFloat = 150, gap: CGFloat = 22
let total = 5 * frameW + 4 * gap
let startX = (1024 - total) / 2
let frameY: CGFloat = 236
var centers: [CGFloat] = []
for i in 0..<5 {
    let x = startX + CGFloat(i) * (frameW + gap)
    centers.append(x + frameW / 2)
    let r = CGRect(x: x, y: frameY, width: frameW, height: frameH)
    let p = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
    if i == 3 {
        // dropped frame: dashed amber outline, empty
        ctx.saveGState()
        ctx.addPath(p)
        ctx.setStrokeColor(amber)
        ctx.setLineWidth(7)
        ctx.setLineDash(phase: 0, lengths: [22, 16])
        ctx.setShadow(offset: .zero, blur: 26, color: amber.copy(alpha: 0.55))
        ctx.strokePath()
        ctx.restoreGState()
    } else {
        ctx.addPath(p)
        ctx.setFillColor(rgba(1, 1, 1, 0.10))
        ctx.fillPath()
        ctx.addPath(p)
        ctx.setStrokeColor(rgba(1, 1, 1, 0.22))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
}

// --- Pulse / cadence trace ---
let baseY: CGFloat = 620
let pip: CGFloat = 58        // normal cadence tick height
let spike: CGFloat = 218     // the anomaly, above the dropped frame
let halfW: CGFloat = 34

let path = CGMutablePath()
path.move(to: CGPoint(x: margin + 46, y: baseY))
for (i, c) in centers.enumerated() {
    let h = (i == 3) ? spike : pip
    let w = (i == 3) ? halfW + 10 : halfW
    path.addLine(to: CGPoint(x: c - w, y: baseY))
    path.addLine(to: CGPoint(x: c, y: baseY + h))
    path.addLine(to: CGPoint(x: c + w, y: baseY))
}
path.addLine(to: CGPoint(x: 1024 - margin - 46, y: baseY))

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: accent.copy(alpha: 0.75))
ctx.addPath(path)
ctx.setStrokeColor(accent)
ctx.setLineWidth(30)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()

// bright core line
ctx.addPath(path)
ctx.setStrokeColor(rgba(0.78, 0.90, 1.0, 0.9))
ctx.setLineWidth(10)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()

// spike apex dot
ctx.setFillColor(rgba(1, 1, 1, 0.95))
let apex = CGPoint(x: centers[3], y: baseY + spike)
ctx.fillEllipse(in: CGRect(x: apex.x - 13, y: apex.y - 13, width: 26, height: 26))

// subtle top edge highlight on the tile
ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(rgba(1, 1, 1, 0.07))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// --- Write PNG ---
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png") as CFURL,
    "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote icon")
