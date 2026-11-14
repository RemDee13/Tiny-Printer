import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Physical units of a 203 dpi thermal head.
public enum Units {
    public static let dpi: Double = 203
    public static func dots(mm: Double) -> Int { Int((mm / 25.4 * dpi).rounded()) }
    public static func mm(dots: Int) -> Double { Double(dots) / dpi * 25.4 }
    /// Typographic points → dots, so "24 pt" looks like 24 pt in Pages.
    public static func dots(pt: Double) -> CGFloat { CGFloat(pt * dpi / 72) }
}

/// Grayscale drawing surface measured in printer dots, origin at the top-left.
public final class Canvas {
    public let width: Int
    public let height: Int
    public let ctx: CGContext

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        ctx = GrayImage.makeContext(width: self.width, height: self.height)
        ctx.translateBy(x: 0, y: CGFloat(self.height))
        ctx.scaleBy(x: 1, y: -1)
    }

    public func fill(_ rect: CGRect, gray: CGFloat = 0) {
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(rect)
    }

    public func stroke(_ rect: CGRect, lineWidth: CGFloat) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    public func draw(_ text: NSAttributedString, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    public func draw(_ image: CGImage, in rect: CGRect, smooth: Bool = true) {
        ctx.saveGState()
        // Undo the flip locally so the image is not drawn upside down.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = smooth ? .high : .none
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Draws QR modules as crisp integer-sized squares (no interpolation), which keeps codes scannable.
    public func draw(_ qr: QRMatrix, at origin: CGPoint, moduleSize: Int) {
        ctx.setFillColor(gray: 0, alpha: 1)
        let m = CGFloat(moduleSize)
        for y in 0..<qr.size {
            for x in 0..<qr.size where qr[x, y] {
                ctx.fill(CGRect(x: origin.x.rounded() + CGFloat(x) * m, y: origin.y.rounded() + CGFloat(y) * m, width: m, height: m))
            }
        }
    }

    public var gray: GrayImage { GrayImage(context: ctx) }
}

// MARK: - Text

public enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    public var id: String { rawValue }
    var ns: NSTextAlignment {
        switch self { case .left: return .left; case .center: return .center; case .right: return .right }
    }
}

public enum TextStyle {
    public static func font(name: String, sizePt: Double, bold: Bool) -> NSFont {
        let size = Units.dots(pt: sizePt)
        var font: NSFont
        if name.isEmpty {
            font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        } else {
            font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        }
        return font
    }

    public static func attributed(_ text: String, font: NSFont, align: TextAlign = .center, wrap: Bool = true) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = align.ns
        p.lineBreakMode = wrap ? .byWordWrapping : .byClipping
        return NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: p, .foregroundColor: NSColor.black,
        ])
    }

    /// Size of the text when laid out within `maxWidth` (use .greatestFiniteMagnitude for no wrapping).
    public static func measure(_ s: NSAttributedString, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }
}

// MARK: - QR

public enum QRCorrection: String, Codable, CaseIterable, Identifiable {
    case low = "L", medium = "M", quartile = "Q", high = "H"
    public var id: String { rawValue }
}

/// QR symbol as a boolean module grid, without quiet zone.
public struct QRMatrix {
    public let size: Int
    public let modules: [Bool]

    public subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    public init?(_ text: String, correction: QRCorrection = .medium) {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = context.createCGImage(output, from: output.extent.integral) else { return nil }
        let w = cg.width, h = cg.height
        let gray = GrayImage(cgImage: cg, width: w, height: h)
        // Strip the generator's quiet zone: bounding box of dark modules.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where gray.data[y * w + x] < 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxX - minX == maxY - minY else { return nil }
        let n = maxX - minX + 1
        var mods = [Bool](repeating: false, count: n * n)
        for y in 0..<n {
            for x in 0..<n { mods[y * n + x] = gray.data[(y + minY) * w + (x + minX)] < 0.5 }
        }
        size = n
        modules = mods
    }
}

// MARK: - Images

public enum ImageLoader {
    /// Loads any ImageIO-supported file (JPEG, PNG, HEIC, …) with EXIF orientation applied.
    public static func load(url: URL, maxPixelSize: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src, maxPixelSize: maxPixelSize)
    }

    public static func load(data: Data, maxPixelSize: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src, maxPixelSize: maxPixelSize)
    }

    private static func load(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// Rotates an image 90° clockwise.
    public static func rotatedClockwise(_ image: CGImage) -> CGImage {
        let w = image.height, h = image.width
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }
}
