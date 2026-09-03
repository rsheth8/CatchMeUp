import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// CatchMeUp app icon — "Constellation C".
// Five memo nodes on an arc that reads as a C. The middle node is the one you're
// caught up to: a mint tile with the CatchMeUp waveform. The other four are blank
// and fade toward the tips. Connectors are straight, edge-anchored with a small gap.
//
//   swift make_icon.swift <out.png>     (writes a 1024×1024 PNG)

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
let S = CGFloat(size)

func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}
func rrect(_ p: CGPoint, _ sz: CGFloat, _ cr: CGFloat = 0.24) -> CGPath {
    CGPath(roundedRect: CGRect(x: p.x - sz / 2, y: p.y - sz / 2, width: sz, height: sz),
           cornerWidth: sz * cr, cornerHeight: sz * cr, transform: nil)
}

// Draw everything in a 0…1 unit square; the transform scales it to 1024 and
// carries shadow blur / stroke widths with it.
ctx.scaleBy(x: S, y: S)

// deep teal gradient background, full bleed (iOS masks the corners)
let bg = CGGradient(colorsSpace: cs, colors: [
    col(0.12, 0.70, 0.75), col(0.02, 0.17, 0.20),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0.1, y: 1), end: CGPoint(x: 0.95, y: 0.02), options: [])

// arc of five nodes; index 2 (the belly of the C) is lit
let center = CGPoint(x: 0.535, y: 0.5)
let radius: CGFloat = 0.305
let degs: [CGFloat] = [56, 118, 180, 242, 304]
let P = degs.map { d -> CGPoint in
    CGPoint(x: center.x + radius * cos(d * .pi / 180),
            y: center.y + radius * sin(d * .pi / 180))
}
let lit = 2
let dist = [2, 1, 0, 1, 2]            // steps from the lit node
let litSize: CGFloat = 0.255
let dormSize: CGFloat = 0.155
let neighbourAlpha = 0.82            // dormant node next to the lit one
let tipAlpha = 0.55                  // dormant node at a tip of the C

// activation glow behind the lit node
func bloom(_ p: CGPoint, _ r: CGFloat, _ inner: CGColor) {
    let g = CGGradient(colorsSpace: cs, colors: [inner, col(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}
bloom(P[lit], 0.60, col(1, 1, 1, 0.09))
bloom(P[lit], 0.30, col(0.60, 0.94, 0.86, 0.55))

// straight connectors, anchored just off each node with a small gap
ctx.setStrokeColor(col(1, 1, 1, 0.34))
ctx.setLineWidth(0.013)
ctx.setLineCap(.butt)
let inset = dormSize * 0.5 + 0.014
for i in 0..<(P.count - 1) {
    let a = P[i], b = P[i + 1]
    var dx = b.x - a.x, dy = b.y - a.y
    let n = max(0.0001, (dx * dx + dy * dy).squareRoot()); dx /= n; dy /= n
    ctx.move(to: CGPoint(x: a.x + dx * inset, y: a.y + dy * inset))
    ctx.addLine(to: CGPoint(x: b.x - dx * inset, y: b.y - dy * inset))
    ctx.strokePath()
}

// the lit node: mint tile + five-bar CatchMeUp waveform
func waveform(_ p: CGPoint, _ sz: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    let heights: [CGFloat] = [0.34, 0.62, 1.0, 0.55, 0.40]
    let barW = sz * 0.108, step = sz * 0.188
    var x = p.x - step * 2
    for h in heights {
        let bh = sz * 0.52 * h
        ctx.addPath(CGPath(roundedRect: CGRect(x: x - barW / 2, y: p.y - bh / 2, width: barW, height: bh),
                           cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        x += step
    }
    ctx.fillPath()
}

for (i, p) in P.enumerated() {
    ctx.saveGState()
    if i == lit {
        ctx.setShadow(offset: CGSize(width: 0, height: -0.012), blur: 0.03, color: col(0, 0, 0, 0.30))
        ctx.setFillColor(col(0.60, 0.94, 0.86))
        ctx.addPath(rrect(p, litSize)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        waveform(p, litSize, col(0.03, 0.26, 0.28))
    } else {
        let alpha = dist[i] == 1 ? neighbourAlpha : tipAlpha
        ctx.setShadow(offset: CGSize(width: 0, height: -0.009), blur: 0.02, color: col(0, 0, 0, 0.22 * alpha))
        ctx.setFillColor(col(0.985, 0.992, 0.992, alpha))
        ctx.addPath(rrect(p, dormSize)); ctx.fillPath()
    }
    ctx.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote", out.path)
