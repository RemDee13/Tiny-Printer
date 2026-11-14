import CoreBluetooth
import Foundation

// "Cat printer" family: Tiny Print / iPrint / Fun Print (V5G dialect) apps.
// GATT: service AE30, write AE01 (no response), notify AE02.
// Frame: [12]? 51 78 CMD 00 LEN_lo LEN_hi PAYLOAD CRC8(PAYLOAD) FF
// Rows: 384 dots = 48 bytes, LSB-first (bit 0 = leftmost pixel), 1 = black.
// Sources: NaitLee/Cat-Printer, rbaron/catprinter, WerWolv's write-up, Dejniel/TiMini-Print, velikodniy/meowprint.

public func crc8<S: Sequence>(_ data: S) -> UInt8 where S.Element == UInt8 {
    var c: UInt8 = 0
    for b in data {
        c ^= b
        for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : (c << 1) }
    }
    return c
}

enum UUIDs {
    static let ae30 = CBUUID(string: "AE30"), af30 = CBUUID(string: "AF30")
    static let ae01 = CBUUID(string: "AE01"), ae02 = CBUUID(string: "AE02"), ae03 = CBUUID(string: "AE03")
    static let ff00 = CBUUID(string: "FF00"), ff01 = CBUUID(string: "FF01"), ff02 = CBUUID(string: "FF02"), ff03 = CBUUID(string: "FF03")
}

public final class CatPrinterDriver: PrinterDriver {
    public static let id = "cat"
    public static let displayName = "Cat printer (51 78 · Tiny Print / iPrint)"

    /// Names seen on this family. MX0x/YT01 are shared with MXW01 (V5X) and resolved by probing.
    static let names = ["GB0", "GT0", "MX0", "MX1", "YT0", "LY0", "MXTP", "X5", "X6", "X7", "X5H", "X6H", "X7H", "X2H",
                        "P7", "YHK-A", "SC03", "D1", "X100", "POCKET", "CAT", "MINI", "GT-", "M2"]
    /// Firmware that wants a 0x12 byte before every frame (uncertain, from TiMini-Print).
    static let prefixedNames = ["JXM800", "LP100", "LY10", "LY11"]
    /// Fun Print / iBleem "V5G" dialect: slower speed setting, different energy.
    static let v5gNames = ["MX05", "MX06", "MX08", "MX09", "MX10", "MX11", "YT01", "PD01"]

    public static func score(name: String, gatt: DiscoveredGATT?) -> Int {
        let hasService = gatt.map { $0.has(service: UUIDs.ae30) || $0.has(service: UUIDs.af30) } ?? false
        if nameMatches(name, prefixes: MXW01Driver.names) { return hasService ? 20 : 0 }
        if nameMatches(name, prefixes: PhomemoDriver.names + LuckJingleDriver.names) { return 0 }
        if nameMatches(name, prefixes: names + prefixedNames) { return hasService || gatt == nil ? 80 : 30 }
        return hasService ? 50 : 0
    }

    public static func make(gatt: DiscoveredGATT) -> PrinterDriver {
        CatPrinterDriver(prefixed: nameMatches(gatt.name, prefixes: prefixedNames),
                         v5g: nameMatches(gatt.name, prefixes: v5gNames))
    }

    public static func probe(gatt: DiscoveredGATT) -> DriverProbe? {
        // "Get state" moves no paper. Reply: 51 78 A3 01 …
        DriverProbe(service: UUIDs.ae30, write: UUIDs.ae01, bytes: Data(frame(0xA3, [0x00], prefixed: false))) { d in
            let b = [UInt8](d)
            return b.count >= 3 && ((b[0] == 0x51 && b[1] == 0x78) || (b.count >= 4 && b[0] == 0x12 && b[1] == 0x51))
        }
    }

    public let profile = GATTProfile(service: UUIDs.ae30, command: UUIDs.ae01, notify: UUIDs.ae02)
    public let widthDots = 384
    public let maxChunk = 180
    public let chunkDelay: TimeInterval = 0.006
    let prefixed: Bool
    let v5g: Bool

    init(prefixed: Bool, v5g: Bool) {
        self.prefixed = prefixed
        self.v5g = v5g
    }

    static func frame(_ cmd: UInt8, _ payload: [UInt8], prefixed: Bool) -> [UInt8] {
        (prefixed ? [0x12] : []) + [0x51, 0x78, cmd, 0x00] + le16(payload.count) + payload + [crc8(payload), 0xFF]
    }

    func f(_ cmd: UInt8, _ payload: [UInt8]) -> [UInt8] { Self.frame(cmd, payload, prefixed: prefixed) }

    static let latticeStart: [UInt8] = [0xAA, 0x55, 0x17, 0x38, 0x44, 0x5F, 0x5F, 0x5F, 0x44, 0x38, 0x2C]
    static let latticeEnd: [UInt8] = [0xAA, 0x55, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17]

    /// Row run-length encoding (opcode BF): each byte = (color << 7) | run, run 1…127.
    static func rle(_ bm: MonoBitmap, row y: Int) -> [UInt8] {
        var out: [UInt8] = []
        var x = 0
        let base = y * bm.width
        while x < bm.width {
            let color = bm.pixels[base + x]
            var run = 0
            while x < bm.width && bm.pixels[base + x] == color && run < 127 { run += 1; x += 1 }
            out.append((color << 7) | UInt8(run))
        }
        return out
    }

    public func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep] {
        let bm = bitmap.fitted(toWidth: widthDots)
        let d = settings.darkness
        let quality = UInt8(0x31 + Int((d * 4).rounded()))                    // 0x31…0x35
        let energy = v5g ? Int(9000 + d * 6000) : Int(7000 + d * 9000)        // ~12000 for "normal" stickers
        let speed: UInt8 = v5g ? 10 : UInt8(26 + Int(d * 8))                   // larger = slower = darker
        var job: [UInt8] = []
        job += f(0xA3, [0x00])
        job += f(0xA4, [quality])
        job += f(0xA6, Self.latticeStart)
        job += f(0xAF, le16(energy))
        job += f(0xBE, [0x00])                                                 // image mode
        job += f(0xBD, [speed])
        for y in 0..<bm.height {
            if y > 0 && y % 200 == 0 { job += f(0xBD, [speed]) }               // some firmware forgets it
            let rle = Self.rle(bm, row: y)
            job += rle.count <= bm.bytesPerRow ? f(0xBF, rle) : f(0xA2, bm.packedRow(y, msbFirst: false))
        }
        // Feed with blank rows: works on every firmware (A1 feed is ignored by some MX models).
        let blank = f(0xBF, [0x7F, 0x7F, 0x7F, 0x03])
        for _ in 0..<Units.dots(mm: settings.feedAfterMM) { job += blank }
        job += f(0xBD, [0x19])
        job += f(0xA6, Self.latticeEnd)
        job += f(0xA3, [0x00])
        return [.send(Data(job), .command)]
    }

    public func statusSteps() -> [JobStep] {
        [.send(Data(f(0xA3, [0x00])), .command), .delay(0.3)]
    }

    public func handle(notification data: Data) -> DriverEvent? {
        var b = [UInt8](data)
        if b.first == 0x12 { b.removeFirst() }
        guard b.count >= 7, b[0] == 0x51, b[1] == 0x78 else { return nil }
        switch b[2] {
        case 0xAE:                       // flow control: 10 = buffer full, 00 = go on
            return b[6] == 0x10 ? .pause : .resume
        case 0xA3:
            var s = PrinterStatus()
            let flags = b[6]
            s.paperOut = flags & 0x01 != 0
            s.coverOpen = flags & 0x02 != 0
            s.overheated = flags & 0x04 != 0
            s.lowBattery = flags & 0x08 != 0
            s.raw = data.hex
            return .status(s)
        default:
            return nil
        }
    }
}
