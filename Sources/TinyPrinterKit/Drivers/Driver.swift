import CoreBluetooth
import Foundation

/// User-facing print options shared by all drivers.
public struct PrintSettings: Codable, Equatable {
    public enum Paper: String, Codable, CaseIterable, Identifiable {
        case sticker, receipt
        public var id: String { rawValue }
        public var title: String { self == .sticker ? "Стикер (самоклейка)" : "Чековая лента" }
    }

    public var paper: Paper = .sticker
    /// 1 (light) … 5 (dark). Sticker paper usually needs one step more than receipt paper.
    public var density = 3
    /// Extra feed after the job so the label clears the tear bar.
    public var feedAfterMM: Double = 10
    public var copies = 1

    public init() {}

    /// 0…1 darkness, including the paper correction.
    public var darkness: Double {
        let base = (Double(min(5, max(1, density))) - 1) / 4      // 0, .25, .5, .75, 1
        return min(1, base + (paper == .sticker ? 0.12 : 0))
    }
}

/// Which GATT characteristic a chunk goes to.
public enum CharRole: Equatable {
    case command   // control channel
    case data      // bulk image channel (same as command on most printers)
}

/// A single step of a print job. Drivers describe jobs as scripts; the BLE transport executes them.
public enum JobStep {
    /// Bytes for a characteristic. The transport splits them by MTU and paces them.
    case send(Data, CharRole)
    /// Waits for a notification accepted by `match`, failing after `timeout` seconds.
    case wait(label: String, timeout: TimeInterval, match: (Data) -> Bool)
    /// Like `wait`, but a timeout is not an error (for replies some firmware never sends).
    case maybeWait(label: String, timeout: TimeInterval, match: (Data) -> Bool)
    case delay(TimeInterval)
}

public enum DriverEvent: Equatable {
    case pause                // printer buffer full, stop sending
    case resume
    case status(PrinterStatus)
}

public struct PrinterStatus: Equatable {
    public var battery: Int?          // percent
    public var paperOut = false
    public var overheated = false
    public var coverOpen = false
    public var lowBattery = false
    public var raw = ""

    public init() {}

    public var problems: [String] {
        var p: [String] = []
        if paperOut { p.append("нет бумаги") }
        if coverOpen { p.append("открыта крышка") }
        if overheated { p.append("перегрев") }
        if lowBattery { p.append("разряжена батарея") }
        return p
    }
}

/// GATT layout a driver needs.
public struct GATTProfile {
    public var service: CBUUID
    public var command: CBUUID
    public var data: CBUUID?          // nil = use `command`
    public var notify: CBUUID?
    public init(service: CBUUID, command: CBUUID, data: CBUUID? = nil, notify: CBUUID? = nil) {
        self.service = service; self.command = command; self.data = data; self.notify = notify
    }
}

/// What a peripheral looked like after connecting: used to pick a driver.
public struct DiscoveredGATT {
    public var name: String
    /// service UUID → characteristic UUIDs
    public var services: [CBUUID: [CBUUID]]
    public init(name: String, services: [CBUUID: [CBUUID]]) { self.name = name; self.services = services }

    public func has(service: CBUUID, chars: [CBUUID] = []) -> Bool {
        guard let c = services[service] else { return false }
        return chars.allSatisfy(c.contains)
    }
}

/// A harmless request used to tell protocol families apart when the name is ambiguous.
public struct DriverProbe {
    public var service: CBUUID
    public var write: CBUUID
    public var bytes: Data
    public var timeout: TimeInterval = 0.8
    public var match: (Data) -> Bool
    public init(service: CBUUID, write: CBUUID, bytes: Data, timeout: TimeInterval = 0.8, match: @escaping (Data) -> Bool) {
        self.service = service; self.write = write; self.bytes = bytes; self.timeout = timeout; self.match = match
    }
}

public protocol PrinterDriver: AnyObject {
    static var id: String { get }
    static var displayName: String { get }
    /// Probes run in descending priority when several drivers fit.
    static var probePriority: Int { get }
    static func probe(gatt: DiscoveredGATT) -> DriverProbe?
    /// 0 = not this printer; higher = more confident. Used both on advertised data and on full GATT.
    static func score(name: String, gatt: DiscoveredGATT?) -> Int
    static func make(gatt: DiscoveredGATT) -> PrinterDriver

    var profile: GATTProfile { get }
    var widthDots: Int { get }
    /// Max bytes per BLE write (the transport also caps by the negotiated MTU).
    var maxChunk: Int { get }
    /// Pause between BLE writes; cheap printers drop data without it.
    var chunkDelay: TimeInterval { get }
    var preferWriteWithoutResponse: Bool { get }

    func printSteps(_ bitmap: MonoBitmap, settings: PrintSettings) -> [JobStep]
    func statusSteps() -> [JobStep]
    func handle(notification: Data) -> DriverEvent?
}

public extension PrinterDriver {
    static var probePriority: Int { 0 }
    static func probe(gatt: DiscoveredGATT) -> DriverProbe? { nil }
    var maxChunk: Int { 180 }
    var chunkDelay: TimeInterval { 0.004 }
    var preferWriteWithoutResponse: Bool { true }
    func statusSteps() -> [JobStep] { [] }
    func handle(notification: Data) -> DriverEvent? { nil }
}

/// All drivers we know, most specific first.
public enum DriverRegistry {
    public static let all: [PrinterDriver.Type] = [
        MXW01Driver.self, CatPrinterDriver.self, PhomemoDriver.self, LuckJingleDriver.self, EscPosDriver.self,
    ]

    public static func driver(id: String) -> PrinterDriver.Type? { all.first { $0.id == id } }

    /// Drivers that fit a connected peripheral, best first.
    public static func ranked(for gatt: DiscoveredGATT) -> [(type: PrinterDriver.Type, score: Int)] {
        all.map { (type: $0, score: $0.score(name: gatt.name, gatt: gatt)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }

    /// Quick filter for scan results (name + advertised services only).
    public static func looksLikePrinter(name: String, advertised: [CBUUID]) -> Bool {
        let gatt = advertised.isEmpty ? nil : DiscoveredGATT(name: name, services: Dictionary(uniqueKeysWithValues: advertised.map { ($0, []) }))
        return all.contains { $0.score(name: name, gatt: gatt) > 0 }
    }
}

// MARK: - Helpers shared by drivers

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var chars = hex.filter(\.isHexDigit).makeIterator()
        while let a = chars.next(), let b = chars.next() { bytes.append(UInt8(String([a, b]), radix: 16)!) }
        self.init(bytes)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

/// Matches advertised names like "X6h-1A2B", "MXW01", "GB03": prefixes of 3+ characters match the
/// start of the name, 1–2 character ones ("X1", "D1") must equal the part before "-", "_" or " ".
func nameMatches(_ name: String, prefixes: [String]) -> Bool {
    let n = name.uppercased().trimmingCharacters(in: .whitespaces)
    let token = n.split(whereSeparator: { "-_ ".contains($0) }).first.map(String.init) ?? n
    return prefixes.contains { p in p.count <= 2 ? token == p : n.hasPrefix(p) }
}
