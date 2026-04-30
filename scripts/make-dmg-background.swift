// Generates the DMG installer background image. Re-run only when the
// design changes:
//
//   swift scripts/make-dmg-background.swift > scripts/dmg-background.png
//
// 540×380 matches the DMG window size set by package.sh; the icon
// positions in package.sh align with the arrow drawn here.
import AppKit

let W = 540
let H = 380

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: W, height: H,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext creation failed") }

// Vertical gradient — colors picked to match the app icon background.
let topColor    = CGColor(red: 0.31, green: 0.52, blue: 0.82, alpha: 1.0)
let bottomColor = CGColor(red: 0.18, green: 0.32, blue: 0.62, alpha: 1.0)
let gradient = CGGradient(
    colorsSpace: cs,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: H),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Subtle 2×2 tile motif at the corners, echoing the app icon. Drawn at
// low opacity so it reads as a watermark, not as decoration competing
// with the dragdrop affordance.
func drawTileBadge(at center: CGPoint, alpha: CGFloat) {
    let s: CGFloat = 26
    let r: CGFloat = 6
    let gap: CGFloat = 4
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
        (1.00, 0.62, 0.20),  // orange
        (0.42, 0.78, 0.42),  // green
        (0.40, 0.70, 0.95),  // blue
        (0.72, 0.50, 0.90),  // purple
    ]
    let positions = [
        CGPoint(x: -s - gap/2, y:  gap/2),
        CGPoint(x:  gap/2,     y:  gap/2),
        CGPoint(x: -s - gap/2, y: -s - gap/2),
        CGPoint(x:  gap/2,     y: -s - gap/2),
    ]
    for (i, p) in positions.enumerated() {
        let rect = CGRect(x: center.x + p.x, y: center.y + p.y, width: s, height: s)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let (red, green, blue) = colors[i]
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        ctx.addPath(path)
        ctx.fillPath()
    }
}
drawTileBadge(at: CGPoint(x: 60, y: 60), alpha: 0.18)
drawTileBadge(at: CGPoint(x: W - 60, y: 60), alpha: 0.18)

// Centered arrow pointing app → Applications. y=190 matches the icon
// centers configured in package.sh.
let arrowY: CGFloat = 190
let arrowFromX: CGFloat = 235
let arrowToX: CGFloat = 355
let arrowHead: CGFloat = 16

ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: arrowFromX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowToX, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: arrowToX - arrowHead, y: arrowY + arrowHead))
ctx.addLine(to: CGPoint(x: arrowToX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowToX - arrowHead, y: arrowY - arrowHead))
ctx.strokePath()

// "TileBar" wordmark, top center. Optional but anchors the scene.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.92),
]
let title = NSAttributedString(string: "TileBar", attributes: titleAttrs)
let tw = title.size().width
title.draw(at: CGPoint(x: (CGFloat(W) - tw) / 2, y: CGFloat(H) - 60))
NSGraphicsContext.restoreGraphicsState()

guard let img = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
else { fatalError("PNG encoding failed") }
FileHandle.standardOutput.write(png)
