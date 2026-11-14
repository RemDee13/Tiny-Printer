import CoreImage
import XCTest
@testable import TinyPrinterKit

final class LabelTests: XCTestCase {
    /// Decodes QR codes from a rendered label the way a phone camera would (digitally, at least).
    private func decodeQR(_ bm: MonoBitmap) -> [String] {
        let img = CIImage(cgImage: bm.cgImage()!).transformed(by: CGAffineTransform(scaleX: 3, y: 3))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        return detector.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    func testQRLabelsScanInEveryLayout() {
        var q = QRLabel()
        q.content = "https://example.com/item/INV-0042"
        q.caption = "INV-0042\nКоробка"
        for layout in QRLayout.allCases {
            q.layout = layout
            let bm = q.render(width: 384)
            XCTAssertEqual(bm.width, 384)
            XCTAssertEqual(decodeQR(bm), [q.content], "\(layout)")
        }
    }

    func testSmallQRStillScans() {
        var q = QRLabel()
        q.content = "https://example.com/a/very/long/path?with=query&and=more"
        q.qrSizeMM = 15
        XCTAssertEqual(decodeQR(q.render(width: 384)), [q.content])
    }

    func testFixedLengthIsRespected() {
        var q = QRLabel()
        q.caption = "A-1\nКоробка"
        q.layout = .side
        q.lengthMM = 30
        XCTAssertEqual(q.render(width: 384).height, Units.dots(mm: 30))
        var t = TextLabel()
        t.lengthMM = 25
        XCTAssertEqual(t.render(width: 384).height, Units.dots(mm: 25))
    }

    func testAlongTapeRotates() {
        var t = TextLabel()
        t.text = "Длинная надпись"
        t.alongTape = true
        t.autoFit = false
        t.sizePt = 30
        let bm = t.render(width: 384)
        XCTAssertEqual(bm.width, 384)
        XCTAssertGreaterThan(bm.height, 384)   // runs along the tape
    }

    func testDitherKeepsTone() {
        var g = GrayImage(width: 64, height: 64, fill: 0.5)
        g.data[0] = 0.5
        for m in [DitherMethod.floydSteinberg, .ordered] {
            XCTAssertEqual(g.dithered(m).blackRatio, 0.5, accuracy: 0.05, "\(m)")
        }
        XCTAssertEqual(GrayImage(width: 8, height: 8, fill: 1).dithered(.atkinson).blackRatio, 0)
    }

    func testPDFPageRendersAtHeadWidth() throws {
        // A 57x40 mm page with a black bar must come out 384 dots wide, 40 mm long.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 57 / 25.4 * 72, height: 40 / 25.4 * 72)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        let pages = DocumentRenderer.renderPDF(data: data as Data, width: 384, options: DocumentRenderOptions())
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].width, 384)
        XCTAssertEqual(pages[0].height, Units.dots(mm: 40), accuracy: 2)
        XCTAssertGreaterThan(pages[0].blackRatio, 0.05)
    }
}
