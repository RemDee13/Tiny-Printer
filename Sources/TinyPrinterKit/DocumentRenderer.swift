import CoreGraphics
import Foundation

/// Turns documents coming from the macOS print system (PDF) or files (images) into printable bitmaps.
public struct DocumentRenderOptions: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable, Identifiable {
        case auto, text, photo
        public var id: String { rawValue }
        public var title: String {
            switch self { case .auto: return String(localized: "Авто", bundle: .tinyPrinter); case .text: return String(localized: "Текст / QR", bundle: .tinyPrinter); case .photo: return String(localized: "Фото", bundle: .tinyPrinter) }
        }
    }

    public var mode: Mode = .auto
    public var photoDither: DitherMethod = .atkinson
    public var textThreshold: Double = 0.55
    /// Drop blank space at the end of each page (saves tape on receipts).
    public var trimBottom = false
    public var pagesSeparated = true

    public init() {}
}

public enum DocumentRenderer {
    /// Renders every page of a PDF. Narrow pages (label sizes) are rendered at 203 dpi and center-cropped
    /// to the head; wide pages (A4/Letter sent by mistake) are scaled down to fit.
    public static func renderPDF(data: Data, width: Int, options: DocumentRenderOptions) -> [MonoBitmap] {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return [] }
        var pages: [MonoBitmap] = []
        for index in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: index) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let pageW = rotated ? box.height : box.width
            let pageH = rotated ? box.width : box.height
            var scale = CGFloat(Units.dpi / 72)
            if pageW * scale > CGFloat(width) * 1.35 { scale = CGFloat(width) / pageW }
            let pw = Int((pageW * scale).rounded()), ph = Int((pageH * scale).rounded())
            let ctx = GrayImage.makeContext(width: pw, height: ph)
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            let rect = CGRect(x: 0, y: 0, width: pageW, height: pageH)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            var bm = toMono(GrayImage(context: ctx), options: options).fitted(toWidth: width)
            if options.trimBottom { bm = bm.trimmedBottom(margin: Units.dots(mm: 2)) }
            if bm.height > 0 { pages.append(bm) }
        }
        return pages
    }

    public static func renderImage(_ image: CGImage, width: Int, options: DocumentRenderOptions) -> MonoBitmap {
        var s = PhotoSettings()
        s.dither = options.mode == .text ? .threshold : options.photoDither
        if options.mode == .auto {
            let probe = GrayImage(cgImage: image, targetWidth: min(width, 256))
            if probe.midtoneRatio < 0.03 { s.dither = .threshold; s.sharpen = 0; s.contrast = 0; s.brightness = 0 }
        }
        return s.render(image, width: width)
    }

    public static func toMono(_ gray: GrayImage, options: DocumentRenderOptions) -> MonoBitmap {
        switch options.mode {
        case .text: return gray.threshold(Float(options.textThreshold))
        case .photo: return gray.adjusted(brightness: 0.05, contrast: 0.1).dithered(options.photoDither)
        case .auto:
            // Pages with lots of mid-tones are pictures; crisp threshold keeps text and QR codes sharp.
            return gray.midtoneRatio > 0.04
                ? gray.adjusted(brightness: 0.03, contrast: 0.05).dithered(options.photoDither)
                : gray.threshold(Float(options.textThreshold))
        }
    }

    /// Single entry point for files: PDF or any image ImageIO understands.
    public static func render(fileData: Data, contentType: String?, width: Int, options: DocumentRenderOptions) -> [MonoBitmap] {
        let isPDF = contentType?.contains("pdf") == true || fileData.starts(with: Array("%PDF".utf8))
        if isPDF { return renderPDF(data: fileData, width: width, options: options) }
        if let img = ImageLoader.load(data: fileData) { return [renderImage(img, width: width, options: options)] }
        return []
    }
}
