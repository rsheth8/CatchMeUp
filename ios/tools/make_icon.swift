import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)

// deep teal gradient background, full bleed (iOS masks the corners)
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.10, green: 0.67, blue: 0.72, alpha: 1),
    CGColor(red: 0.03, green: 0.31, blue: 0.35, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// soft highlight, upper-left
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 320, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 320, y: 760), endRadius: 680, options: [])

// waveform: five pill bars, the third one caught mid-rise
let heights: [CGFloat] = [0.30, 0.56, 0.94, 0.50, 0.38]
let barW: CGFloat = 94, gap: CGFloat = 54, maxH: CGFloat = 560
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (S - totalW) / 2
let midY = S / 2
for (i, h) in heights.enumerated() {
    let bh = maxH * h
    let r = CGRect(x: x, y: midY - bh / 2, width: barW, height: bh)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(i == 2
        ? CGColor(red: 0.86, green: 0.98, blue: 0.97, alpha: 1)
        : CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()
    x += barW + gap
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote", out.path)
