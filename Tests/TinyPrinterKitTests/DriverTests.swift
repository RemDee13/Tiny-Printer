import CoreBluetooth
import XCTest
@testable import TinyPrinterKit

final class DriverTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    func testCRC8Vectors() {
        XCTAssertEqual(crc8([0x00]), 0x00)
        XCTAssertEqual(crc8([0x01]), 0x07)
        XCTAssertEqual(crc8([0x32]), 0x9E)
        XCTAssertEqual(crc8([0x30, 0x00]), 0xF9)
        XCTAssertEqual(crc8([0xE0, 0x2E]), 0x89)
    }

    func testCatFramesMatchCaptures() {
        func f(_ c: UInt8, _ p: [UInt8]) -> String { hex(CatPrinterDriver.frame(c, p, prefixed: false)) }
        XCTAssertEqual(f(0xAF, [0xE0, 0x2E]), "51 78 AF 00 02 00 E0 2E 89 FF")
        XCTAssertEqual(f(0xA1, [0x30, 0x00]), "51 78 A1 00 02 00 30 00 F9 FF")
        XCTAssertEqual(f(0xA3, [0x00]), "51 78 A3 00 01 00 00 00 FF")
        XCTAssertEqual(f(0xA4, [0x33]), "51 78 A4 00 01 00 33 99 FF")
        XCTAssertEqual(f(0xBD, [0x1E]), "51 78 BD 00 01 00 1E 5A FF")
        XCTAssertEqual(f(0xA6, CatPrinterDriver.latticeStart), "51 78 A6 00 0B 00 AA 55 17 38 44 5F 5F 5F 44 38 2C A1 FF")
        XCTAssertEqual(f(0xA6, CatPrinterDriver.latticeEnd), "51 78 A6 00 0B 00 AA 55 17 00 00 00 00 00 00 00 17 11 FF")
        XCTAssertEqual(f(0xBF, [0x7F, 0x7F, 0x7F, 0x03]), "51 78 BF 00 04 00 7F 7F 7F 03 A8 FF")
    }

    func testCatRLE() {
        var bm = MonoBitmap(width: 384, height: 2)
        XCTAssertEqual(CatPrinterDriver.rle(bm, row: 0), [0x7F, 0x7F, 0x7F, 0x03])
        for x in 0..<10 { bm[x, 1] = true }
        XCTAssertEqual(CatPrinterDriver.rle(bm, row: 1), [0x80 | 10, 0x7F, 0x7F, 0x7F - 10 + 3])
    }

    func testCatJobUsesLSBFirstRows() {
        var bm = MonoBitmap(width: 384, height: 1)
        for x in stride(from: 0, to: 384, by: 2) { bm[x, 0] = true }   // checkerboard row: RLE too long → raw A2
        let drv = CatPrinterDriver(prefixed: false, v5g: false)
        guard case .send(let data, _) = drv.printSteps(bm, settings: PrintSettings()).first! else { return XCTFail() }
        let bytes = [UInt8](data)
        let a2 = bytes.firstRange(of: [0x51, 0x78, 0xA2, 0x00, 0x30, 0x00])!
        XCTAssertEqual(bytes[a2.upperBound], 0x55)        // pixels 0,2,4,6 → bits 0,2,4,6
        XCTAssertEqual(bytes.suffix(9).map { $0 }, CatPrinterDriver.frame(0xA3, [0x00], prefixed: false))
    }

    func testMXW01Frames() {
        XCTAssertEqual(hex(MXW01Driver.frame(0xA9, [0x64, 0x00, 0x30, 0x00])), "22 21 A9 00 04 00 64 00 30 00 F4 FF")
        XCTAssertEqual(hex(MXW01Driver.frame(0xA2, [0x5D])), "22 21 A2 00 01 00 5D 94 FF")
        let steps = MXW01Driver().printSteps(MonoBitmap(width: 384, height: 10), settings: PrintSettings())
        // Short jobs are padded to the 90-line minimum (4320 bytes).
        let raster = steps.compactMap { s -> Data? in if case .send(let d, .data) = s { return d }; return nil }.first!
        XCTAssertGreaterThanOrEqual(raster.count, 4320)
        XCTAssertEqual(raster.count % 48, 0)
    }

    func testEscPosRaster() {
        var bm = MonoBitmap(width: 384, height: 300)
        bm[0, 0] = true
        let out = rasterBlocks(bm, blockLines: 255)
        XCTAssertEqual(Array(out.prefix(8)), [0x1D, 0x76, 0x30, 0x00, 0x30, 0x00, 0xFF, 0x00])
        XCTAssertEqual(out[8], 0x80)                                   // MSB-first
        XCTAssertEqual(out.count, 8 * 2 + 300 * 48)
    }

    func testNameMatching() {
        XCTAssertTrue(nameMatches("X6h-1A2B", prefixes: CatPrinterDriver.names))
        XCTAssertFalse(nameMatches("X6h-1A2B", prefixes: MXW01Driver.names))
        XCTAssertTrue(nameMatches("MXW01", prefixes: MXW01Driver.names))
        XCTAssertTrue(nameMatches("X2-0001", prefixes: MXW01Driver.names))
        XCTAssertTrue(nameMatches("M02S", prefixes: PhomemoDriver.wideNames))
    }

    func testRanking() {
        let ae30: [CBUUID: [CBUUID]] = [CBUUID(string: "AE30"): ["AE01", "AE02", "AE03"].map { CBUUID(string: $0) }]
        XCTAssertEqual(DriverRegistry.ranked(for: DiscoveredGATT(name: "GB03", services: ae30)).first?.type.id, "cat")
        XCTAssertEqual(DriverRegistry.ranked(for: DiscoveredGATT(name: "MXW01", services: ae30)).first?.type.id, "mxw01")
        // Unknown name on AE30: both families fit closely → the transport probes.
        let unknown = DriverRegistry.ranked(for: DiscoveredGATT(name: "Printer", services: ae30))
        XCTAssertEqual(Set(unknown.map { $0.type.id }), ["cat", "mxw01"])
        let ff00: [CBUUID: [CBUUID]] = [CBUUID(string: "FF00"): ["FF01", "FF02", "FF03"].map { CBUUID(string: $0) }]
        XCTAssertEqual(DriverRegistry.ranked(for: DiscoveredGATT(name: "M02", services: ff00)).first?.type.id, "phomemo")
        let isscGatt: [CBUUID: [CBUUID]] = [CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"): [CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")]]
        XCTAssertEqual(DriverRegistry.ranked(for: DiscoveredGATT(name: "YHK-1234", services: isscGatt)).first?.type.id, "escpos")
    }

    func testFlowControlParsing() {
        let d = CatPrinterDriver(prefixed: false, v5g: false)
        XCTAssertEqual(d.handle(notification: Data([0x51, 0x78, 0xAE, 0x01, 0x01, 0x00, 0x10, 0x70, 0xFF])), .pause)
        XCTAssertEqual(d.handle(notification: Data([0x51, 0x78, 0xAE, 0x01, 0x01, 0x00, 0x00, 0x00, 0xFF])), .resume)
        if case .status(let s) = d.handle(notification: Data([0x51, 0x78, 0xA3, 0x01, 0x01, 0x00, 0x01, 0x07, 0xFF])) {
            XCTAssertTrue(s.paperOut)
        } else { XCTFail() }
    }
}
