import Combine
import CoreBluetooth
import Foundation

public enum PrinterError: LocalizedError {
    case bluetoothOff, bluetoothDenied, notFound, unknownProtocol(String), disconnected, timeout(String), busy, write(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "Bluetooth выключен"
        case .bluetoothDenied: return "Нет доступа к Bluetooth: Системные настройки → Конфиденциальность → Bluetooth"
        case .notFound: return "Принтер не найден. Включите его и отключите от телефона (принтер держит одно подключение)"
        case .unknownProtocol(let s): return "Неизвестный протокол принтера. GATT: \(s)"
        case .disconnected: return "Принтер отключился"
        case .timeout(let s): return "Принтер не ответил: \(s)"
        case .busy: return "Принтер занят другой задачей"
        case .write(let s): return "Ошибка передачи: \(s)"
        }
    }
}

/// CoreBluetooth transport: finds the printer, picks a driver from its GATT layout and runs job scripts.
@MainActor
public final class BLEPrinter: NSObject, ObservableObject {
    public enum State: Equatable {
        case idle, scanning, connecting(String), connected, printing(Double), error(String)
        public var isBusy: Bool {
            switch self { case .scanning, .connecting, .printing: return true; default: return false }
        }
    }

    public struct Candidate: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        public let likelyPrinter: Bool
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var deviceName: String?
    @Published public private(set) var driverName: String?
    @Published public private(set) var status = PrinterStatus()
    @Published public private(set) var candidates: [Candidate] = []
    @Published public private(set) var gattDescription = ""
    @Published public private(set) var log: [String] = []

    public var isConnected: Bool { peripheral?.state == .connected && driver != nil }
    public var widthDots: Int { driver?.widthDots ?? 384 }

    private let defaults = UserDefaults.standard
    public var rememberedID: UUID? {
        get { defaults.string(forKey: "printer.peripheral").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "printer.peripheral") }
    }
    /// Force a driver by id instead of auto-detection ("" = auto).
    public var forcedDriverID: String {
        get { defaults.string(forKey: "printer.driver") ?? "" }
        set { defaults.set(newValue, forKey: "printer.driver") }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var driver: PrinterDriver?
    private var characteristics: [CBUUID: [CBUUID: CBCharacteristic]] = [:]   // service → char
    private var seen: [UUID: (CBPeripheral, Int, String, [CBUUID])] = [:]
    private var jobRunning = false
    private var paused = false
    private var recentNotifications: [Data] = []

    // Pending async operations (all touched on the main actor only).
    private var poweredOn: [Pending<Void>] = []
    private var connectPending: Pending<Void>?
    private var gattPending: Pending<Void>?
    private var gattOutstanding = 0
    private var writeReady: Pending<Void>?
    private var writeResponse: Pending<Void>?
    private var resumeWaiter: Pending<Void>?
    private var notifyWaiters: [(match: (Data) -> Bool, pending: Pending<Data>)] = []

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Public API

    public func connect() async throws {
        try await waitPoweredOn()
        if isConnected { return }
        if let id = rememberedID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            do {
                try await connect(to: p)
                return
            } catch {
                note("Сохранённый принтер не отвечает: \(error.localizedDescription). Ищу заново…")
            }
        }
        let found = try await scan(duration: 6, stopEarly: true)
        guard let best = found.first(where: \.likelyPrinter), let entry = seen[best.id] else {
            state = .error(PrinterError.notFound.localizedDescription)
            throw PrinterError.notFound
        }
        try await connect(to: entry.0)
    }

    /// Connect to a specific device picked by the user in the list.
    public func connect(id: UUID) async throws {
        try await waitPoweredOn()
        disconnect()
        guard let p = seen[id]?.0 ?? central.retrievePeripherals(withIdentifiers: [id]).first else { throw PrinterError.notFound }
        try await connect(to: p)
    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        driver = nil
        driverName = nil
        characteristics = [:]
        if !jobRunning { state = .idle }
    }

    public func forget() {
        rememberedID = nil
        disconnect()
    }

    /// Scans for advertising devices. Results land in `candidates`, likely printers first.
    @discardableResult
    public func scan(duration: TimeInterval = 6, stopEarly: Bool = false) async throws -> [Candidate] {
        try await waitPoweredOn()
        seen = [:]
        candidates = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            // A clearly identified printer: no need to wait the full duration.
            if stopEarly, candidates.contains(where: \.likelyPrinter), Date() > deadline.addingTimeInterval(-duration + 1.5) { break }
        }
        central.stopScan()
        if state == .scanning { state = isConnected ? .connected : .idle }
        return candidates
    }

    public func print(_ bitmap: MonoBitmap, settings: PrintSettings) async throws {
        guard !jobRunning else { throw PrinterError.busy }
        jobRunning = true
        defer { jobRunning = false; if case .printing = state { state = isConnected ? .connected : .idle } }
        try await connect()
        guard let driver else { throw PrinterError.disconnected }
        var steps: [JobStep] = []
        for _ in 0..<max(1, settings.copies) { steps += driver.printSteps(bitmap, settings: settings) }
        note("Печать: \(bitmap.width)×\(bitmap.height) точек (\(String(format: "%.0f", Units.mm(dots: bitmap.height))) мм), копий: \(settings.copies)")
        try await run(steps)
        note("Готово")
    }

    public func refreshStatus() async {
        guard isConnected, !jobRunning, let driver else { return }
        let steps = driver.statusSteps()
        guard !steps.isEmpty else { return }
        jobRunning = true
        defer { jobRunning = false }
        try? await run(steps, progress: false)
    }

    // MARK: - Job execution

    private func run(_ steps: [JobStep], progress: Bool = true) async throws {
        let total = steps.reduce(0) { if case .send(let d, _) = $1 { return $0 + d.count }; return $0 }
        var sent = 0
        recentNotifications.removeAll()
        paused = false
        if progress { state = .printing(0) }
        for step in steps {
            switch step {
            case .send(let data, let role):
                try await write(data, role: role) { n in
                    sent += n
                    if progress, total > 0 { self.state = .printing(Double(sent) / Double(total)) }
                }
            case .delay(let t):
                try await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            case .wait(let label, let timeout, let match):
                _ = try await waitNotification(label: label, timeout: timeout, match: match)
            case .maybeWait(let label, let timeout, let match):
                do { _ = try await waitNotification(label: label, timeout: timeout, match: match) } catch PrinterError.timeout {
                    note("Нет ответа: \(label), продолжаю")
                }
            }
        }
    }

    private func waitNotification(label: String, timeout: TimeInterval, match: @escaping (Data) -> Bool) async throws -> Data {
        if let i = recentNotifications.firstIndex(where: match) { return recentNotifications.remove(at: i) }
        return try await awaitPending(timeout: timeout, label: label) { (p: Pending<Data>) in
            self.notifyWaiters.append((match, p))
        }
    }

    private func characteristic(_ uuid: CBUUID, in service: CBUUID?) -> CBCharacteristic? {
        if let service, let c = characteristics[service]?[uuid] { return c }
        return characteristics.values.lazy.compactMap { $0[uuid] }.first
    }

    private func write(_ data: Data, role: CharRole, sent: (Int) -> Void) async throws {
        guard let driver else { throw PrinterError.disconnected }
        let uuid = role == .data ? (driver.profile.data ?? driver.profile.command) : driver.profile.command
        try await write(data, to: uuid, in: driver.profile.service, maxChunk: driver.maxChunk, delay: driver.chunkDelay,
                        preferNoResponse: driver.preferWriteWithoutResponse, sent: sent)
    }

    private func write(_ data: Data, to uuid: CBUUID, in service: CBUUID?, maxChunk: Int, delay: TimeInterval,
                       preferNoResponse: Bool, sent: (Int) -> Void) async throws {
        guard let p = peripheral, p.state == .connected else { throw PrinterError.disconnected }
        guard let ch = characteristic(uuid, in: service) else { throw PrinterError.write("нет характеристики \(uuid)") }
        let noResp = ch.properties.contains(.writeWithoutResponse) && (preferNoResponse || !ch.properties.contains(.write))
        let type: CBCharacteristicWriteType = noResp ? .withoutResponse : .withResponse
        let chunk = max(20, min(maxChunk, p.maximumWriteValueLength(for: type)))
        var offset = 0
        while offset < data.count {
            if paused {
                _ = try? await awaitPending(timeout: 15, label: "возобновление после паузы") { (w: Pending<Void>) in self.resumeWaiter = w }
                paused = false
            }
            guard p.state == .connected else { throw PrinterError.disconnected }
            let piece = data.subdata(in: offset..<min(offset + chunk, data.count))
            if type == .withoutResponse {
                if !p.canSendWriteWithoutResponse {
                    _ = try await awaitPending(timeout: 5, label: "готовность к записи") { (w: Pending<Void>) in self.writeReady = w }
                }
                p.writeValue(piece, for: ch, type: .withoutResponse)
            } else {
                p.writeValue(piece, for: ch, type: .withResponse)
                _ = try await awaitPending(timeout: 5, label: "подтверждение записи") { (w: Pending<Void>) in self.writeResponse = w }
            }
            offset += piece.count
            sent(piece.count)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }

    // MARK: - Connection

    private func waitPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw PrinterError.bluetoothDenied
        case .poweredOff, .unsupported: throw PrinterError.bluetoothOff
        default:
            try await awaitPending(timeout: 5, label: "Bluetooth") { (p: Pending<Void>) in self.poweredOn.append(p) }
        }
    }

    private func connect(to p: CBPeripheral) async throws {
        let name = p.name ?? seen[p.identifier]?.2 ?? "принтер"
        state = .connecting(name)
        note("Подключаюсь к \(name)…")
        peripheral = p
        p.delegate = self
        do {
            try await awaitPending(timeout: 10, label: "подключение") { (w: Pending<Void>) in
                self.connectPending = w
                self.central.connect(p)
            }
            try await awaitPending(timeout: 10, label: "чтение GATT") { (w: Pending<Void>) in
                self.gattPending = w
                p.discoverServices(nil)
            }
        } catch {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            state = .error(error.localizedDescription)
            throw error
        }
        var services: [CBUUID: [CBUUID]] = [:]
        for s in p.services ?? [] { services[s.uuid] = s.characteristics?.map(\.uuid) ?? [] }
        let gatt = DiscoveredGATT(name: name, services: services)
        gattDescription = describe(p)
        note("GATT:\n" + gattDescription)
        // Subscribe to every notify/indicate characteristic: replies and flow control may come on any of them.
        for c in characteristics.values.flatMap(\.values) where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            p.setNotifyValue(true, for: c)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard let type = await chooseDriver(gatt) else {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            let err = PrinterError.unknownProtocol(services.keys.map(\.uuidString).joined(separator: ", "))
            state = .error(err.localizedDescription)
            throw err
        }
        let d = type.make(gatt: gatt)
        driver = d
        driverName = type.displayName
        deviceName = name
        rememberedID = p.identifier
        state = .connected
        note("Подключено: \(name), драйвер «\(type.displayName)», ширина \(d.widthDots) точек, MTU \(p.maximumWriteValueLength(for: .withoutResponse))")
        try? await Task.sleep(nanoseconds: 200_000_000)
        await refreshStatus()
    }

    /// Picks the protocol: forced by the user, obvious from name/GATT, or decided by harmless probes.
    private func chooseDriver(_ gatt: DiscoveredGATT) async -> PrinterDriver.Type? {
        if !forcedDriverID.isEmpty, let t = DriverRegistry.driver(id: forcedDriverID) { return t }
        let ranked = DriverRegistry.ranked(for: gatt)
        note("Кандидаты: " + ranked.map { "\($0.type.id)=\($0.score)" }.joined(separator: ", "))
        guard let top = ranked.first else { return nil }
        let close = ranked.filter { top.score - $0.score < 30 }
        if close.count < 2 { return top.type }
        for candidate in close.sorted(by: { $0.type.probePriority > $1.type.probePriority }) {
            guard let probe = candidate.type.probe(gatt: gatt) else { continue }
            recentNotifications.removeAll()
            do {
                try await write(probe.bytes, to: probe.write, in: probe.service, maxChunk: 180, delay: 0,
                                preferNoResponse: true) { _ in }
                let reply = try await waitNotification(label: "проба \(candidate.type.id)", timeout: probe.timeout, match: probe.match)
                note("Проба \(candidate.type.id): ответ \(reply.hex)")
                return candidate.type
            } catch {
                note("Проба \(candidate.type.id): нет ответа")
            }
        }
        return top.type
    }

    private func describe(_ p: CBPeripheral) -> String {
        var lines: [String] = []
        for s in p.services ?? [] {
            lines.append("service \(s.uuid.uuidString)")
            for c in s.characteristics ?? [] {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) { props.append("write") }
                if c.properties.contains(.writeWithoutResponse) { props.append("writeNoResp") }
                if c.properties.contains(.notify) { props.append("notify") }
                if c.properties.contains(.indicate) { props.append("indicate") }
                lines.append("  char \(c.uuid.uuidString) [\(props.joined(separator: ","))]")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Async helper

    private func awaitPending<T>(timeout: TimeInterval, label: String, register: @escaping (Pending<T>) -> Void) async throws -> T {
        let pending = Pending<T>()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            pending.continuation = c
            register(pending)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                pending.resume(.failure(PrinterError.timeout(label)))
            }
        }
    }

    private func failAll(_ error: Error) {
        connectPending?.resume(.failure(error)); connectPending = nil
        gattPending?.resume(.failure(error)); gattPending = nil
        writeReady?.resume(.failure(error)); writeReady = nil
        writeResponse?.resume(.failure(error)); writeResponse = nil
        resumeWaiter?.resume(.failure(error)); resumeWaiter = nil
        for w in notifyWaiters { w.pending.resume(.failure(error)) }
        notifyWaiters.removeAll()
    }
}

final class Pending<T> {
    var continuation: CheckedContinuation<T, Error>?
    func resume(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension Pending where T == Void {
    func succeed() { resume(.success(())) }
}

// MARK: - CoreBluetooth delegates

extension BLEPrinter: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                poweredOn.forEach { $0.succeed() }
                poweredOn.removeAll()
            } else if central.state == .unauthorized {
                poweredOn.forEach { $0.resume(.failure(PrinterError.bluetoothDenied)) }
                poweredOn.removeAll()
                state = .error(PrinterError.bluetoothDenied.localizedDescription)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                           advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            guard !name.isEmpty || !services.isEmpty else { return }
            seen[p.identifier] = (p, RSSI.intValue, name, services)
            let likely = DriverRegistry.looksLikePrinter(name: name, advertised: services)
            let c = Candidate(id: p.identifier, name: name.isEmpty ? "(без имени)" : name, rssi: RSSI.intValue, likelyPrinter: likely)
            candidates.removeAll { $0.id == c.id }
            candidates.append(c)
            candidates.sort { ($0.likelyPrinter ? 1 : 0, $0.rssi) > ($1.likelyPrinter ? 1 : 0, $1.rssi) }
            if likely { note("Найден похожий принтер: \(c.name) (\(c.rssi) dBm) \(services.map(\.uuidString))") }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { connectPending?.succeed(); connectPending = nil }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            connectPending?.resume(.failure(error ?? PrinterError.disconnected)); connectPending = nil
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard p.identifier == peripheral?.identifier else { return }
            note("Отключено\(error.map { ": \($0.localizedDescription)" } ?? "")")
            failAll(PrinterError.disconnected)
            peripheral = nil
            driver = nil
            driverName = nil
            characteristics = [:]
            state = .idle
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = p.services ?? []
            gattOutstanding = services.count
            if services.isEmpty { gattPending?.succeed(); gattPending = nil }
            services.forEach { p.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] { characteristics[s.uuid, default: [:]][c.uuid] = c }
            gattOutstanding -= 1
            if gattOutstanding <= 0 { gattPending?.succeed(); gattPending = nil }
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        MainActor.assumeIsolated { writeReady?.succeed(); writeReady = nil }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { writeResponse?.resume(.failure(PrinterError.write(error.localizedDescription))) } else { writeResponse?.succeed() }
            writeResponse = nil
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = c.value, !data.isEmpty else { return }
            if let event = driver?.handle(notification: data) {
                switch event {
                case .pause:
                    if !paused { note("Принтер просит паузу") }
                    paused = true
                case .resume:
                    paused = false
                    resumeWaiter?.succeed(); resumeWaiter = nil
                case .status(let s):
                    status = s
                    if !s.problems.isEmpty { note("Статус: " + s.problems.joined(separator: ", ")) }
                }
            }
            if let i = notifyWaiters.firstIndex(where: { $0.match(data) }) {
                notifyWaiters.remove(at: i).pending.resume(.success(data))
            } else {
                recentNotifications.append(data)
                if recentNotifications.count > 32 { recentNotifications.removeFirst() }
            }
        }
    }
}
