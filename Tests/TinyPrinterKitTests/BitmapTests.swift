import XCTest
@testable import TinyPrinterKit

final class BitmapTests: XCTestCase {
    func testPacking() {
        var bm = MonoBitmap(width: 16, height: 1)
        bm[0, 0] = true; bm[9, 0] = true
        XCTAssertEqual(bm.packedRow(0, msbFirst: true), [0x80, 0x40])
        XCTAssertEqual(bm.packedRow(0, msbFirst: false), [0x01, 0x02])
    }
}
