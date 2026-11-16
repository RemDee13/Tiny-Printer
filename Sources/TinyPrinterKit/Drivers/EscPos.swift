import CoreBluetooth
import Foundation

// ESC/POS-based printers. Raster: GS v 0 (1D 76 30 00 wL wH hL hH data), rows MSB-first, 1 = black.

/// Splits a bitmap into GS v 0 blocks of at most `blockLines` rows.
func rasterBlocks(_ bm: MonoBitmap, blockLines: Int) -> [UInt8] {
    var out: [UInt8] = []
    var y = 0
    while y < bm.height {
        let n = min(blockLines, bm.height - y)
        out += [0x1D, 0x76, 0x30, 0x00] + le16(bm.bytesPerRow) + le16(n)
        for row in y..<(y + n) { out += bm.packedRow(row, msbFirst: true) }
        y += n
    }
    return out
}

// MARK: - Phomemo M02 / T02 family (Phomemo, Print Master apps)

public final class PhomemoDriver: PrinterDriver {
    public static let id = "phomemo"
    public static let displayName = "Phomemo (M02 / T02, ESC/POS)"
    static let names = ["M02", "MR.IN", "MR2", "T02", "C02", "KP-Q1", "M03", "M04", "Q02", "Q1", "SANDYMARO"]
    static let wideNames = ["M02S", "M02 PRO", "M02PRO", "M02X", "M04"]   // 300 dpi, 576 dots

    public static func score(name: String, gatt: DiscoveredGATT?) -> Int {
        let hasService = gatt?.has(service: UUIDs.ff00) ?? false
        if nameMatches(name, prefixes: names) { return hasService || gatt == nil ? 85 : 30 }
        if nameMatches(name, prefixes: LuckJingleDriver.names) { return 0 }
        return (gatt?.has(service: UUIDs.ff00, chars: [UUIDs.ff02]) ?? false) ? 40 : 0
    }

    public static func make(gatt: DiscoveredGATT) -> PrinterDriver {
        PhomemoDriver(width: nameMatches(gatt.name, prefixes: wideNames) ? 576 : 384)
    }

    public static func probe(gatt: DiscoveredGATT) -> DriverProbe? {
        // Battery query: answered with 1A 04 nn.
        DriverProbe(service: UUIDs.ff00, write: UUIDs.ff02, bytes: Data([0x1F, 0x11, 0x0E])) { d in
            d.count >= 2 && d[d.startIndex] == 0x1A
        }
    }

    public let profile = GATTProfile(service: UUIDs.ff00, command: UUIDs.ff02, notify: UUIDs.ff01)
    public let widthDots: Int
    public let maxChunk = 128
    public let chunkDelay: TimeInterval = 0.02

    init(width: Int) { widthDots = width }

    public func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep] {
        let bm = bitmap.fitted(toWidth: widthDots).padded(bottom: Units.dots(mm: settings.feedAfterMM))
        let d = settings.darkness
        let concentration: UInt8 = d < 0.3 ? 0x01 : d < 0.55 ? 0x02 : 0x04
        var job: [UInt8] = [0x1B, 0x40, 0x1B, 0x61, 0x01, 0x1F, 0x11, 0x02, concentration]
        job += rasterBlocks(bm, blockLines: 255)
        job += [0x1B, 0x64, 0x02, 0x1B, 0x64, 0x02]
        job += [0x1F, 0x11, 0x0E, 0x1F, 0x11, 0x11]          // ask battery + paper state afterwards
        return [.send(Data(job), .command)]
    }

    public func statusSteps() -> [JobStep] {
        [.send(Data([0x1F, 0x11, 0x0E, 0x1F, 0x11, 0x11, 0x1F, 0x11, 0x12]), .command), .delay(0.4)]
    }

    private var status = PrinterStatus()

    public func handle(notification data: Data) -> DriverEvent? {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == 0x1A else { return nil }
        switch b[1] {
        case 0x04: status.battery = Int(b[2]) <= 100 ? Int(b[2]) : nil; status.lowBattery = (0xA1...0xA3).contains(b[2])
        case 0x06: status.paperOut = b[2] == 0x88
        case 0x05: status.coverOpen = b[2] == 0x99
        case 0x03: status.overheated = b[2] == 0xA9
        default: return nil
        }
        status.raw = data.hex
        return .status(status)
    }
}

// MARK: - Luck Jingle / LuckP (FF00 + 10 FF commands)

public final class LuckJingleDriver: PrinterDriver {
    public static let id = "luck"
    public static let displayName = "Luck Jingle / LuckP (10 FF)"
    static let names = ["LUCKJINGLE", "LJ-", "DP_", "D1Y", "AIYIN", "LUCKP"]

    public static func score(name: String, gatt: DiscoveredGATT?) -> Int {
        guard nameMatches(name, prefixes: names) else { return 0 }
        return gatt == nil || gatt!.has(service: UUIDs.ff00) ? 85 : 20
    }

    public static func make(gatt: DiscoveredGATT) -> PrinterDriver { LuckJingleDriver() }

    public let profile = GATTProfile(service: UUIDs.ff00, command: UUIDs.ff02, notify: UUIDs.ff01)
    public let widthDots = 384
    public let maxChunk = 120
    public let chunkDelay: TimeInterval = 0.025

    public func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep] {
        let bm = bitmap.fitted(toWidth: widthDots)
        var job: [UInt8] = [0x10, 0xFF, 0xF1, 0x03] + [UInt8](repeating: 0, count: 12)
        job += rasterBlocks(bm, blockLines: 255)
        var feed = Units.dots(mm: settings.feedAfterMM)
        while feed > 0 { job += [0x1B, 0x4A, UInt8(min(255, feed))]; feed -= 255 }
        job += [0x10, 0xFF, 0xF1, 0x45]
        return [
            .send(Data(job), .command),
            .maybeWait(label: String(localized: "окончание печати", bundle: .tinyPrinter), timeout: 10 + Double(bm.height) / 60) { d in
                (d.count >= 2 && d[d.startIndex] == 0x4F && d[d.startIndex + 1] == 0x4B) || d.first == 0xAA
            },
        ]
    }

    public func statusSteps() -> [JobStep] { [.send(Data([0x10, 0xFF, 0x40]), .command), .delay(0.3)] }

    public func handle(notification data: Data) -> DriverEvent? {
        let b = [UInt8](data)
        // Reply to 10 FF 40 is a single status byte.
        guard b.count == 1 else { return nil }
        var s = PrinterStatus()
        s.paperOut = b[0] & 0x04 != 0
        s.lowBattery = b[0] & 0x08 != 0
        s.overheated = b[0] & 0x50 != 0
        s.raw = data.hex
        return .status(s)
    }
}

// MARK: - Generic ESC/POS over BLE (incl. YHK / InstaPrint)

public final class EscPosDriver: PrinterDriver {
    public static let id = "escpos"
    public static let displayName = String(localized: "ESC/POS (универсальный)", bundle: .tinyPrinter)
    static let yhkNames = ["YHK", "CTP", "COREPRINT", "INSTAPRINT"]

    struct Layout { let service: CBUUID; let write: [CBUUID]; let notify: CBUUID? }
    static let layouts: [Layout] = [
        Layout(service: CBUUID(string: "18F0"), write: [CBUUID(string: "2AF1")], notify: CBUUID(string: "2AF0")),
        Layout(service: CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
               write: [CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")], notify: nil),
        Layout(service: CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
               write: [CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"), CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE")],
               notify: CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")),
    ]

    public static func score(name: String, gatt: DiscoveredGATT?) -> Int {
        guard let gatt else { return nameMatches(name, prefixes: yhkNames) ? 60 : 0 }
        let found = layouts.contains { l in gatt.has(service: l.service) && l.write.contains { gatt.services[l.service]!.contains($0) || gatt.services[l.service]!.isEmpty } }
        guard found else { return 0 }
        return nameMatches(name, prefixes: yhkNames) ? 70 : 30
    }

    public static func make(gatt: DiscoveredGATT) -> PrinterDriver {
        let layout = layouts.first { gatt.has(service: $0.service) } ?? layouts[0]
        let chars = gatt.services[layout.service] ?? []
        let write = layout.write.first(where: chars.contains) ?? layout.write[0]
        return EscPosDriver(profile: GATTProfile(service: layout.service, command: write, notify: layout.notify),
                            yhk: nameMatches(gatt.name, prefixes: yhkNames))
    }

    public let profile: GATTProfile
    public let widthDots = 384
    public let maxChunk: Int
    public let chunkDelay: TimeInterval
    let yhk: Bool

    init(profile: GATTProfile, yhk: Bool) {
        self.profile = profile
        self.yhk = yhk
        maxChunk = yhk ? 180 : 128
        chunkDelay = yhk ? 0.03 : 0.02
    }

    public func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep] {
        let bm = bitmap.fitted(toWidth: widthDots)
        var job: [UInt8] = [0x1B, 0x40]
        if yhk { job += [0x1D, 0x49, 0xF0, UInt8(10 + Int(settings.darkness * 10))] }
        // Small blocks: cheap firmware overflows on big GS v 0 images.
        job += rasterBlocks(bm, blockLines: yhk ? 1 : 32)
        var feed = Units.dots(mm: settings.feedAfterMM)
        while feed > 0 { job += [0x1B, 0x4A, UInt8(min(255, feed))]; feed -= 255 }
        return [.send(Data(job), .command), .delay(1.0)]
    }
}
