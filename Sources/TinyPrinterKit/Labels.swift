import AppKit
import CoreGraphics
import Foundation

// All renderers produce a MonoBitmap exactly `width` dots wide (the print head width).
// "Length" is measured along the tape (the feed direction).

// MARK: - Text sticker

public struct TextLabel: Codable, Equatable {
    public var text = "Привет!"
    public var fontName = ""            // empty = system font
    public var sizePt: Double = 28
    public var bold = true
    public var align: TextAlign = .center
    /// Rotate 90° so the text runs along the tape: long narrow labels for boxes, cables, shelves.
    public var alongTape = false
    /// Along tape: grow the font to fill the tape width.
    public var autoFit = true
    public var lengthMM: Double = 0     // 0 = as long as the content needs
    public var invert = false
    public var border = false
    public var paddingMM: Double = 2

    public init() {}

    public func render(width: Int) -> MonoBitmap {
        let pad = CGFloat(Units.dots(mm: paddingMM))
        let text = self.text.isEmpty ? " " : self.text
        if !alongTape {
            let font = TextStyle.font(name: fontName, sizePt: sizePt, bold: bold)
            let s = TextStyle.attributed(text, font: font, align: align)
            let boxW = CGFloat(width) - pad * 2
            let size = TextStyle.measure(s, maxWidth: boxW)
            let h = lengthMM > 0 ? Units.dots(mm: lengthMM) : Int(size.height + pad * 2)
            let canvas = Canvas(width: width, height: h)
            let y = (CGFloat(h) - size.height) / 2
            canvas.draw(s, in: CGRect(x: pad, y: y, width: boxW, height: size.height + 2))
            if border { canvas.stroke(CGRect(x: 0, y: 0, width: width, height: h), lineWidth: 3) }
            let bm = canvas.gray.threshold(0.5)
            return invert ? bm.inverted() : bm
        }
        // Along the tape: lay out on a canvas whose height is the tape width, then rotate.
        let across = CGFloat(width) - pad * 2
        var pt = sizePt
        var font = TextStyle.font(name: fontName, sizePt: pt, bold: bold)
        var s = TextStyle.attributed(text, font: font, align: align, wrap: false)
        var size = TextStyle.measure(s)
        let fixedLength = lengthMM > 0 ? CGFloat(Units.dots(mm: lengthMM)) - pad * 2 : nil
        if autoFit || size.height > across || (fixedLength.map { size.width > $0 } ?? false) {
            var scale = across / max(1, size.height)
            if let L = fixedLength { scale = min(scale, L / max(1, size.width)) }
            if !autoFit { scale = min(scale, 1) }
            pt = max(4, pt * Double(scale) * 0.98)
            font = TextStyle.font(name: fontName, sizePt: pt, bold: bold)
            s = TextStyle.attributed(text, font: font, align: align, wrap: false)
            size = TextStyle.measure(s)
        }
        let length = fixedLength.map { Int($0 + pad * 2) } ?? Int(size.width + pad * 2)
        let canvas = Canvas(width: length, height: width)
        let x: CGFloat
        switch align {
        case .left: x = pad
        case .center: x = (CGFloat(length) - size.width) / 2
        case .right: x = CGFloat(length) - pad - size.width
        }
        canvas.draw(s, in: CGRect(x: x, y: (CGFloat(width) - size.height) / 2, width: size.width + 2, height: size.height + 2))
        if border { canvas.stroke(CGRect(x: 0, y: 0, width: length, height: width), lineWidth: 3) }
        var bm = canvas.gray.threshold(0.5).rotatedClockwise()
        if invert { bm = bm.inverted() }
        return bm
    }
}

// MARK: - QR sticker

public enum QRLayout: String, Codable, CaseIterable, Identifiable {
    case stacked, side
    public var id: String { rawValue }
    public var title: String { self == .stacked ? "QR сверху, подпись снизу" : "QR слева, подпись справа" }
}

public struct QRLabel: Codable, Equatable {
    public var content = "https://example.com"
    public var caption = ""
    public var captionSizePt: Double = 12
    public var layout: QRLayout = .stacked
    public var qrSizeMM: Double = 30
    public var lengthMM: Double = 0      // 0 = auto
    public var correction: QRCorrection = .medium
    public var paddingMM: Double = 2

    public init() {}

    public func render(width: Int) -> MonoBitmap {
        let lines = caption.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return QRRenderer.render(content: content, lines: lines.isEmpty || caption.isEmpty ? [] : lines.enumerated().map {
            CaptionLine(text: $0.element, sizePt: captionSizePt, bold: $0.offset == 0)
        }, layout: layout, qrSizeMM: qrSizeMM, lengthMM: lengthMM, paddingMM: paddingMM,
           correction: correction, width: width)
    }
}

public struct CaptionLine {
    public var text: String
    public var sizePt: Double
    public var bold: Bool
    public init(text: String, sizePt: Double, bold: Bool) { self.text = text; self.sizePt = sizePt; self.bold = bold }
}

public enum QRRenderer {
    public static func render(content: String, lines: [CaptionLine], layout: QRLayout, qrSizeMM: Double,
                              lengthMM: Double, paddingMM: Double, correction: QRCorrection, width: Int) -> MonoBitmap {
        let pad = Units.dots(mm: paddingMM)
        guard let qr = QRMatrix(content, correction: correction) else {
            var t = TextLabel(); t.text = "QR: пусто"; t.sizePt = 12
            return t.render(width: width)
        }
        let fixedLen = lengthMM > 0 ? Units.dots(mm: lengthMM) : nil
        switch layout {
        case .stacked:
            var target = min(Units.dots(mm: qrSizeMM), width - pad * 2)
            // Fixed length: keep room for the caption block.
            let captionBlock = lines.isEmpty ? 0 : lines.reduce(0) { $0 + Int(Units.dots(pt: $1.sizePt) * 1.3) } + pad
            if let L = fixedLen { target = min(target, L - pad * 2 - captionBlock) }
            let module = max(1, target / qr.size)
            let qrDots = module * qr.size
            let fitted = fitLines(lines, box: CGSize(width: width - pad * 2, height: max(captionBlock, 1)), align: .center)
            let textH = Int(fitted.reduce(0) { $0 + $1.1.height })
            let h = fixedLen ?? (pad + qrDots + (lines.isEmpty ? 0 : pad / 2 + textH) + pad)
            let canvas = Canvas(width: width, height: h)
            let contentH = qrDots + (lines.isEmpty ? 0 : pad / 2 + textH)
            var y = CGFloat(max(pad, (h - contentH) / 2))
            canvas.draw(qr, at: CGPoint(x: (width - qrDots) / 2, y: Int(y)), moduleSize: module)
            y += CGFloat(qrDots + pad / 2)
            for (s, size) in fitted {
                canvas.draw(s, in: CGRect(x: CGFloat(pad), y: y, width: CGFloat(width - pad * 2), height: size.height + 2))
                y += size.height
            }
            return canvas.gray.threshold(0.5)

        case .side:
            let L = fixedLen ?? (min(Units.dots(mm: qrSizeMM), width * 2 / 3) + pad * 2)
            let target = min(L - pad * 2, lines.isEmpty ? width - pad * 2 : width * 2 / 3)
            let module = max(1, target / qr.size)
            let qrDots = module * qr.size
            let canvas = Canvas(width: width, height: L)
            let qrX = lines.isEmpty ? (width - qrDots) / 2 : pad
            canvas.draw(qr, at: CGPoint(x: qrX, y: (L - qrDots) / 2), moduleSize: module)
            if !lines.isEmpty {
                let textX = pad + qrDots + pad
                let box = CGSize(width: width - textX - pad / 2, height: L - pad * 2)
                let fitted = fitLines(lines, box: box)
                let total = fitted.reduce(0) { $0 + $1.1.height }
                var y = (CGFloat(L) - total) / 2
                for (s, size) in fitted {
                    canvas.draw(s, in: CGRect(x: CGFloat(textX), y: y, width: box.width + 2, height: size.height + 2))
                    y += size.height
                }
            }
            return canvas.gray.threshold(0.5)
        }
    }

    /// Shrinks every line by the same factor until the block fits in `box`. Lines never wrap.
    static func fitLines(_ lines: [CaptionLine], box: CGSize, align: TextAlign = .left) -> [(NSAttributedString, CGSize)] {
        guard !lines.isEmpty else { return [] }
        var scale: Double = 1
        for _ in 0..<4 {
            let laid = lines.map { line -> (NSAttributedString, CGSize) in
                let f = TextStyle.font(name: "", sizePt: max(4, line.sizePt * scale), bold: line.bold)
                let s = TextStyle.attributed(line.text.isEmpty ? " " : line.text, font: f, align: align, wrap: false)
                return (s, TextStyle.measure(s))
            }
            let w = laid.map { $0.1.width }.max() ?? 0
            let h = laid.reduce(0) { $0 + $1.1.height }
            let k = min(Double(box.width / max(w, 1)), Double(box.height / max(h, 1)))
            if k >= 1 || scale * k * (lines.map(\.sizePt).min() ?? 12) < 4 { return laid }
            scale *= k * 0.97
        }
        return lines.map { line in
            let f = TextStyle.font(name: "", sizePt: max(4, line.sizePt * scale), bold: line.bold)
            let s = TextStyle.attributed(line.text, font: f, align: align, wrap: false)
            return (s, TextStyle.measure(s))
        }
    }
}

// MARK: - Photo sticker

public struct PhotoSettings: Codable, Equatable {
    public var dither: DitherMethod = .atkinson
    public var brightness: Double = 0.05
    public var contrast: Double = 0.1
    public var gamma: Double = 1.0
    public var sharpen: Double = 0.4
    public var widthPercent: Double = 100
    public var rotate = false            // 90°: landscape photos come out bigger
    public var maxLengthMM: Double = 0   // 0 = no limit
    public var invert = false

    public init() {}

    public func render(_ image: CGImage, width: Int) -> MonoBitmap {
        let img = rotate ? ImageLoader.rotatedClockwise(image) : image
        var w = max(8, Int(Double(width) * widthPercent / 100))
        var h = max(1, Int((Double(img.height) * Double(w) / Double(img.width)).rounded()))
        if maxLengthMM > 0 {
            let maxH = Units.dots(mm: maxLengthMM)
            if h > maxH {
                h = maxH
                w = max(8, Int((Double(img.width) * Double(h) / Double(img.height)).rounded()))
            }
        }
        let gray = GrayImage(cgImage: img, width: w, height: h)
            .adjusted(brightness: Float(brightness), contrast: Float(contrast), gamma: Float(gamma))
            .sharpened(amount: Float(sharpen))
        var bm = gray.dithered(dither)
        if invert { bm = bm.inverted() }
        return bm.fitted(toWidth: width)
    }
}
