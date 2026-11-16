import CoreBluetooth
import Foundation

// MXW01 / "V5X" family (Fun Print, iBleem apps).
// GATT: service AE30, control AE01, notify AE02, raw raster AE03 (all write-without-response).
// Frame: 22 21 CMD 00 LEN_lo LEN_hi PAYLOAD CRC8 FF. Rows: 48 bytes LSB-first, 1 = black.
// Job: A2 intensity → A1 status → A9 print request(lines) → raster on AE03 → AD flush → wait AA "done".
// Sources: jeremy46231/MXW01-catprinter, MaikelChan/CatPrinterBLE, Dejniel/TiMini-Print.

public final class MXW01Driver: PrinterDriver {
    public static let id = "mxw01"
    public static let displayName = "MXW01 / V5X (22 21 · Fun Print)"
    static let names = ["X1", "X2", "MXW01", "MXW", "C17", "PORTABLEPRINTER", "INSTANTPRINTPLUS", "REKA", "HDMDT", "KERUI", "BQ17", "JK01"]
    static let ambiguousNames = ["MX05", "MX06", "MX10", "YT01"]

    public static let probePriority = 10

    public static func score(name: String, gatt: DiscoveredGATT?) -> Int {
        let hasService = gatt.map { $0.has(service: UUIDs.ae30) || $0.has(service: UUIDs.af30) } ?? false
        if nameMatches(name, prefixes: names) { return hasService || gatt == nil ? 90 : 40 }
        if nameMatches(name, prefixes: ambiguousNames) { return hasService || gatt == nil ? 60 : 0 }
        // Unknown name on an AE30 printer: plausible, the probe decides.
        return (gatt?.has(service: UUIDs.ae30, chars: [UUIDs.ae03]) ?? false) ? 35 : 0
    }

    public static func make(gatt: DiscoveredGATT) -> PrinterDriver { MXW01Driver() }

    public static func probe(gatt: DiscoveredGATT) -> DriverProbe? {
        // Version query: harmless, answered with a 22 21 frame only by this family.
        DriverProbe(service: UUIDs.ae30, write: UUIDs.ae01, bytes: Data(frame(0xB1, [0x00]))) { d in
            d.count >= 3 && d[d.startIndex] == 0x22 && d[d.startIndex + 1] == 0x21
        }
    }

    public let profile = GATTProfile(service: UUIDs.ae30, command: UUIDs.ae01, data: UUIDs.ae03, notify: UUIDs.ae02)
    public let widthDots = 384
    public let maxChunk = 180
    public let chunkDelay: TimeInterval = 0.012

    static func frame(_ cmd: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x22, 0x21, cmd, 0x00] + le16(payload.count) + payload + [crc8(payload), 0xFF]
    }

    static func isFrame(_ d: Data, _ cmd: UInt8) -> Bool {
        let b = [UInt8](d)
        return b.count >= 3 && b[0] == 0x22 && b[1] == 0x21 && b[2] == cmd
    }

    public func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep] {
        var bm = bitmap.fitted(toWidth: widthDots).padded(bottom: Units.dots(mm: settings.feedAfterMM))
        if bm.height < 90 { bm = bm.padded(bottom: 90 - bm.height) }   // firmware wants ≥ 4320 bytes
        let levels: [UInt8] = [0x58, 0x5A, 0x5D, 0x5F, 0x62]
        let level = levels[min(4, Int((settings.darkness * 4).rounded()))]
        let lines = bm.height
        var raster: [UInt8] = []
        raster.reserveCapacity(lines * bm.bytesPerRow)
        for y in 0..<lines { raster += bm.packedRow(y, msbFirst: false) }
        return [
            .send(Data(Self.frame(0xA2, [level])), .command),
            .send(Data(Self.frame(0xA1, [0x00])), .command),
            .maybeWait(label: String(localized: "статус MXW01", bundle: .tinyPrinter), timeout: 2) { Self.isFrame($0, 0xA1) },
            .send(Data(Self.frame(0xA9, le16(lines) + [0x30, 0x00])), .command),
            .wait(label: String(localized: "разрешение печати", bundle: .tinyPrinter), timeout: 4) { Self.isFrame($0, 0xA9) },
            .send(Data(raster), .data),
            .send(Data(Self.frame(0xAD, [0x00])), .command),
            .wait(label: String(localized: "окончание печати", bundle: .tinyPrinter), timeout: 15 + Double(lines) / 60) { Self.isFrame($0, 0xAA) },
        ]
    }

    public func statusSteps() -> [JobStep] {
        [.send(Data(Self.frame(0xA1, [0x00])), .command), .delay(0.4)]
    }

    public func handle(notification data: Data) -> DriverEvent? {
        let b = [UInt8](data)
        if b.count >= 2 && b[0] == 0xAA { return b[1] == 0x01 ? .pause : .resume }
        guard b.count >= 3, b[0] == 0x22, b[1] == 0x21 else { return nil }
        switch b[2] {
        case 0xAE, 0xA8:
            return b.count > 6 && (b[6] == 0x10 || b[6] == 0x20) ? .pause : .resume
        case 0xA1 where b.count >= 14:
            // payload: [0] state, [3] battery, [4] temperature, [6] error group, [7] error code
            let p = Array(b[6...])
            var s = PrinterStatus()
            s.battery = Int(p[3]) <= 100 ? Int(p[3]) : nil
            if p[6] != 0 {
                switch p[7] {
                case 1, 9: s.paperOut = true
                case 4: s.overheated = true
                case 8: s.lowBattery = true
                default: break
                }
            }
            s.raw = data.hex
            return .status(s)
        default:
            return nil
        }
    }
}
