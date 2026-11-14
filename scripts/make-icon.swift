// Draws the Tiny Printer app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift scripts/make-icon.swift out.png
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin, y down. Note: shadow offsets stay in device space (positive y = up).
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// Apple-like continuous-corner squircle (superellipse).
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...1440 {
        let t = CGFloat(i) / 1440 * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + a * copysign(pow(abs(c), 2 / n), c),
                         y: r.midY + b * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func withShadow(_ offsetY: CGFloat, blur: CGFloat, _ color: CGColor, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur, color: color)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: Background tile

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)
withShadow(12, blur: 28, rgb(0x000000, 0.30)) { fill(tilePath, rgb(0xFF7E8E)) }
fill(tilePath, gradient([rgb(0xFFC58F), rgb(0xFF8A8A), rgb(0xF2609A)], [0, 0.5, 1]),
     from: CGPoint(x: 180, y: 120), to: CGPoint(x: 860, y: 920))
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// Soft light from the top-left, a little depth at the bottom.
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: 260, y: 200), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 200), endRadius: 520, options: [])
ctx.drawRadialGradient(gradient([rgb(0x9B1F63, 0), rgb(0x9B1F63, 0.22)]), startCenter: CGPoint(x: 512, y: 430), startRadius: 380,
                       endCenter: CGPoint(x: 512, y: 430), endRadius: 720, options: [])
// Confetti "stickers" floating around.
let confetti: [(CGRect, CGFloat, UInt32)] = [
    (CGRect(x: 176, y: 300, width: 46, height: 46), 0.35, 0xFFFFFF),
    (CGRect(x: 800, y: 640, width: 34, height: 34), 0.30, 0xFFFFFF),
    (CGRect(x: 196, y: 690, width: 28, height: 28), 0.25, 0xFFFFFF),
    (CGRect(x: 812, y: 250, width: 22, height: 22), 0.40, 0xFFFFFF),
]
for (r, a, c) in confetti { fill(CGPath(ellipseIn: r, transform: nil), rgb(c, a)) }
ctx.restoreGState()

// MARK: Printer

let body = CGRect(x: 262, y: 176, width: 500, height: 400)
let bodyRadius: CGFloat = 128
// Base lip gives the box some thickness.
withShadow(26, blur: 46, rgb(0x7A1340, 0.40)) {
    fill(rounded(body.offsetBy(dx: 0, dy: 18), bodyRadius), rgb(0xD8D3E2))
}
fill(rounded(body.offsetBy(dx: 0, dy: 18), bodyRadius), gradient([rgb(0xE4E0EC), rgb(0xC9C3D6)]),
     from: CGPoint(x: 0, y: body.maxY - 40), to: CGPoint(x: 0, y: body.maxY + 18))
fill(rounded(body, bodyRadius), gradient([rgb(0xFFFFFF), rgb(0xF4F2F8), rgb(0xE6E3EE)], [0, 0.55, 1]),
     from: CGPoint(x: 0, y: body.minY), to: CGPoint(x: 0, y: body.maxY))
// Top-edge highlight.
ctx.saveGState()
ctx.addPath(rounded(body, bodyRadius))
ctx.clip()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
ctx.setLineWidth(6)
ctx.addPath(rounded(body.insetBy(dx: 3, dy: 3), bodyRadius - 3))
ctx.strokePath()
ctx.restoreGState()

// Round window on top.
let lens = CGPoint(x: 512, y: 352)
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }
fill(circle(lens, 132), gradient([rgb(0xD9D5E3), rgb(0xF6F4FA)]), from: CGPoint(x: 0, y: lens.y - 132), to: CGPoint(x: 0, y: lens.y + 132))
withShadow(-3, blur: 6, rgb(0x000000, 0.25)) {
    ctx.saveGState()
    ctx.addPath(circle(lens, 110))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x4A4A66), rgb(0x1E1E2E), rgb(0x0D0D15)], [0, 0.55, 1]),
                           startCenter: CGPoint(x: lens.x - 30, y: lens.y - 40), startRadius: 0,
                           endCenter: lens, endRadius: 112, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}
// Gloss.
ctx.saveGState()
ctx.addPath(circle(lens, 110))
ctx.clip()
ctx.addPath(CGPath(ellipseIn: CGRect(x: lens.x - 92, y: lens.y - 100, width: 150, height: 92), transform: nil))
ctx.setFillColor(rgb(0xFFFFFF, 0.16))
ctx.fillPath()
ctx.restoreGState()
fill(circle(CGPoint(x: lens.x + 46, y: lens.y - 50), 13), rgb(0xFFFFFF, 0.85))
fill(circle(CGPoint(x: lens.x + 70, y: lens.y - 22), 6), rgb(0xFFFFFF, 0.6))

// Status LED.
withShadow(0, blur: 18, rgb(0x2EE6C8, 0.9)) { fill(circle(CGPoint(x: 700, y: 236), 11), rgb(0x3BEBD0)) }

// MARK: Paper with a QR sticker

let slot = CGRect(x: 322, y: 524, width: 380, height: 24)
fill(rounded(slot, 12), gradient([rgb(0x2A2838), rgb(0x55526A)]), from: CGPoint(x: 0, y: slot.minY), to: CGPoint(x: 0, y: slot.maxY))

let paperX: CGFloat = 352, paperW: CGFloat = 320, paperTop: CGFloat = 536, paperBottom: CGFloat = 878
let fold: CGFloat = 64
let paper = CGMutablePath()
paper.move(to: CGPoint(x: paperX, y: paperTop))
paper.addLine(to: CGPoint(x: paperX + paperW, y: paperTop))
paper.addLine(to: CGPoint(x: paperX + paperW, y: paperBottom - fold))
paper.addLine(to: CGPoint(x: paperX + paperW - fold, y: paperBottom))
paper.addLine(to: CGPoint(x: paperX, y: paperBottom))
paper.closeSubpath()
withShadow(14, blur: 26, rgb(0x7A1340, 0.35)) { fill(paper, rgb(0xFFFFFF)) }
// Shade where the paper leaves the slot.
fill(paper, gradient([rgb(0xC9C4D6), rgb(0xFFFFFF, 0)], [0, 1]), from: CGPoint(x: 0, y: paperTop + 12), to: CGPoint(x: 0, y: paperTop + 70))

// QR code printed on the sticker.
let qrFilter = CIFilter.qrCodeGenerator()
qrFilter.message = Data("TINY".utf8)
qrFilter.correctionLevel = "L"
let qrCI = qrFilter.outputImage!
let qrCG = CIContext().createCGImage(qrCI, from: qrCI.extent)!
let qw = qrCG.width
let qctx = CGContext(data: nil, width: qw, height: qw, bitsPerComponent: 8, bytesPerRow: qw, space: CGColorSpaceCreateDeviceGray(),
                     bitmapInfo: CGImageAlphaInfo.none.rawValue)!
qctx.draw(qrCG, in: CGRect(x: 0, y: 0, width: qw, height: qw))
let qdata = qctx.data!.bindMemory(to: UInt8.self, capacity: qw * qw)
var minX = qw, maxX = 0
for y in 0..<qw { for x in 0..<qw where qdata[y * qw + x] < 128 { minX = min(minX, x); maxX = max(maxX, x) } }
let modules = maxX - minX + 1
let m: CGFloat = 9.5
let qrSide = m * CGFloat(modules)
let qrOrigin = CGPoint(x: 512 - qrSide / 2 - 10, y: 600)
ctx.setFillColor(rgb(0x262433))
for row in 0..<modules {
    for col in 0..<modules where qdata[(row + minX) * qw + (col + minX)] < 128 {
        ctx.addPath(CGPath(roundedRect: CGRect(x: qrOrigin.x + CGFloat(col) * m - 0.3, y: qrOrigin.y + CGFloat(row) * m - 0.3,
                                               width: m + 0.6, height: m + 0.6), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
    }
}
ctx.fillPath()

// Peeled corner: the flap is the corner reflected over the fold line, showing the pink backing.
let a = CGPoint(x: paperX + paperW, y: paperBottom - fold)
let b = CGPoint(x: paperX + paperW - fold, y: paperBottom)
let p = CGPoint(x: paperX + paperW - fold, y: paperBottom - fold)
let flap = CGMutablePath()
flap.move(to: a); flap.addLine(to: b); flap.addLine(to: p); flap.closeSubpath()
withShadow(6, blur: 12, rgb(0x5A0F30, 0.35)) {
    fill(flap, gradient([rgb(0xFFE3EA), rgb(0xFFB9CB)]), from: p, to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
}

// MARK: Save

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
