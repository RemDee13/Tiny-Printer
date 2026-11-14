import AppKit
import Combine
import Foundation
import ServiceManagement
import TinyPrinterKit

enum EditorTab: String, CaseIterable, Identifiable {
    case cards, text, qr, photo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cards: return "Открытки"
        case .text: return "Надписи"
        case .qr: return "QR-коды"
        case .photo: return "Фото"
        }
    }
    var subtitle: String {
        switch self {
        case .cards: return "Записки, открытки и стикеры"
        case .text: return "Этикетки и длинные наклейки"
        case .qr: return "Ссылки, Wi‑Fi, контакты"
        case .photo: return "Ч/б фото на ленте"
        }
    }
    var icon: String {
        switch self {
        case .cards: return "gift.fill"
        case .text: return "textformat"
        case .qr: return "qrcode"
        case .photo: return "photo.fill"
        }
    }
    var shortcut: Character {
        switch self { case .cards: return "1"; case .text: return "2"; case .qr: return "3"; case .photo: return "4" }
    }
}

enum OutputMode: String, CaseIterable, Identifiable, Codable {
    case bluetooth, virtual
    var id: String { rawValue }
    var title: String { self == .bluetooth ? "Bluetooth-принтер" : "Виртуальный (PNG в папку)" }
}

struct AIHistoryItem: Identifiable {
    let url: URL
    let thumbnail: NSImage
    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// One AI picture and what it cost (estimated from the tokens the provider reported).
struct AICostRecord: Codable {
    let date: Date
    let file: String
    let provider: AIProvider
    let model: String
    let usage: AIUsage?
    let usd: Double?

    var costText: String {
        if let usd { return "≈ " + AIPricing.format(usd) }
        if let usage { return "\(usage.totalTokens) ток., цена модели неизвестна" }
        return "сервис не сообщил расход"
    }
}

struct JobRecord: Identifiable {
    let id = UUID()
    let date = Date()
    let source: String
    let lengthMM: Double
    let ok: Bool
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let printer = BLEPrinter()
    let system = SystemPrinter()
    private var server: LocalServer?
    private var bag = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    @Published var tab: EditorTab { didSet { defaults.set(tab.rawValue, forKey: "editor.tab") } }
    @Published var text: TextLabel { didSet { defaults.save(text, key: "editor.text") } }
    @Published var qr: QRLabel { didSet { defaults.save(qr, key: "editor.qr") } }
    @Published var photo: PhotoSettings { didSet { defaults.save(photo, key: "editor.photo") } }
    @Published var settings: PrintSettings { didSet { defaults.save(settings, key: "print.settings") } }
    @Published var docOptions: DocumentRenderOptions { didSet { defaults.save(docOptions, key: "print.documents") } }
    @Published var output: OutputMode { didSet { defaults.set(output.rawValue, forKey: "print.output") } }
    @Published var card: CardDesign { didSet { defaults.save(card, key: "editor.card") } }
    @Published var ai: AISettings { didSet { defaults.save(ai, key: "ai.settings") } }
    @Published var aiPrompt: String { didSet { defaults.set(aiPrompt, forKey: "ai.prompt") } }

    @Published private(set) var cardImage: CGImage?
    @Published private(set) var cardImageName = ""
    @Published var aiBusy = false
    @Published var aiError: String?
    @Published var aiHistory: [AIHistoryItem] = []
    @Published var aiModels: [AIProvider: [String]] = [:]
    /// Masked keys ("••••abcd") for the providers that have one in the keychain.
    @Published private(set) var keyMasks: [AIProvider: String] = [:]
    @Published private(set) var aiLedger: [AICostRecord] = []

    @Published var photoImage: CGImage?
    @Published var photoName = ""
    @Published var preview: MonoBitmap?
    @Published var copies = 1
    @Published var busy = false
    @Published var toast: String?
    @Published var history: [JobRecord] = []
    @Published var serverError: String?
    @Published var systemPrinterInstalled = false
    @Published var pdfServiceInstalled = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private init() {
        text = defaults.load("editor.text", default: TextLabel())
        qr = defaults.load("editor.qr", default: QRLabel())
        photo = defaults.load("editor.photo", default: PhotoSettings())
        tab = EditorTab(rawValue: defaults.string(forKey: "editor.tab") ?? "") ?? .cards
        settings = defaults.load("print.settings", default: PrintSettings())
        docOptions = defaults.load("print.documents", default: DocumentRenderOptions())
        output = OutputMode(rawValue: defaults.string(forKey: "print.output") ?? "") ?? .bluetooth
        card = defaults.load("editor.card", default: CardDesign())
        ai = defaults.load("ai.settings", default: AISettings())
        aiPrompt = defaults.string(forKey: "ai.prompt") ?? CardPreset.all.first { $0.id == "birthday" }?.prompt ?? ""
        if let img = ImageLoader.load(url: Self.cardImageURL) {
            cardImage = img
            cardImageName = defaults.string(forKey: "card.imageName") ?? "Картинка"
        }
        refreshKeyMasks()
        loadLedger()
        loadAIHistory()

        // Re-render the preview whenever an editor changes (debounced).
        Publishers.MergeMany(
            $text.map { _ in () }.eraseToAnyPublisher(), $qr.map { _ in () }.eraseToAnyPublisher(),
            $photo.map { _ in () }.eraseToAnyPublisher(),
            $tab.map { _ in () }.eraseToAnyPublisher(), $photoImage.map { _ in () }.eraseToAnyPublisher(),
            $card.map { _ in () }.eraseToAnyPublisher(), $cardImage.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
        .sink { [weak self] in self?.refreshPreview() }
        .store(in: &bag)
        printer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: - Startup

    func start() {
        let server = LocalServer(port: SystemPrinter.apiPort) { [weak self] req in
            guard let self else { return .error("app is shutting down", status: 503) }
            return await self.handle(req)
        }
        do { try server.start(); self.server = server } catch {
            serverError = "Локальный API (порт \(SystemPrinter.apiPort)) не запустился: \(error.localizedDescription)"
        }
        system.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.printer.note(line) }
        }
        system.start()
        refreshIntegrationState()
        refreshPreview()
    }

    func refreshIntegrationState() {
        systemPrinterInstalled = system.isInstalled
        pdfServiceInstalled = system.pdfServiceInstalled
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var widthDots: Int { printer.widthDots }

    // MARK: - Preview & printing

    func renderCurrent() -> MonoBitmap? {
        let w = widthDots
        switch tab {
        case .text: return text.render(width: w)
        case .qr: return qr.render(width: w)
        case .photo: return photoImage.map { photo.render($0, width: w) }
        case .cards: return card.render(width: w, image: cardImage)
        }
    }

    func refreshPreview() {
        preview = renderCurrent()
    }

    func printCurrent() {
        guard let bm = renderCurrent(), bm.height > 0, bm.blackRatio > 0 else {
            show("Нечего печатать")
            return
        }
        let source = tab.title
        Task { await printReporting(bm, source: source, copies: copies) }
    }

    /// Prints and records the outcome; returns success.
    @discardableResult
    func printReporting(_ bm: MonoBitmap, source: String, copies: Int = 1, settings override: PrintSettings? = nil) async -> Bool {
        do {
            try await printBitmap(bm, copies: copies, settings: override)
            history.insert(JobRecord(source: source, lengthMM: Units.mm(dots: bm.height) * Double(copies), ok: true, message: "OK"), at: 0)
            show("Напечатано: \(source), \(Int(Units.mm(dots: bm.height))) мм")
            return true
        } catch {
            history.insert(JobRecord(source: source, lengthMM: 0, ok: false, message: error.localizedDescription), at: 0)
            show(error.localizedDescription)
            return false
        }
    }

    func printBitmap(_ bm: MonoBitmap, copies: Int = 1, settings override: PrintSettings? = nil) async throws {
        var s = override ?? settings
        s.copies = max(1, copies)
        busy = true
        defer { busy = false }
        // Feed so the end of the label clears the tear bar.
        let job = bm   // the driver adds the tear-off feed
        switch output {
        case .virtual:
            try saveVirtual(job, copies: s.copies)
        case .bluetooth:
            try await printer.print(job, settings: s)
        }
    }

    static var virtualDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TinyPrinter/Virtual printer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func saveVirtual(_ bm: MonoBitmap, copies: Int) throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let url = Self.virtualDir.appendingPathComponent("\(f.string(from: Date())) x\(copies).png")
        guard let data = bm.pngData() else { throw PrinterError.write("PNG") }
        try data.write(to: url)
        printer.note("Виртуальный принтер: \(url.lastPathComponent)")
    }

    func show(_ message: String) {
        toast = message
        let current = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == current { self?.toast = nil }
        }
    }

    func connectPrinter() {
        Task {
            do { try await printer.connect() } catch { show(error.localizedDescription) }
        }
    }

    /// Short status for the toolbar, the sidebar card and the menu bar.
    var printerTitle: String {
        if output == .virtual { return "Без принтера" }
        switch printer.state {
        case .idle: return printer.rememberedID == nil ? "Принтер не выбран" : "Не подключён"
        case .scanning: return "Поиск…"
        case .connecting(let n): return "Подключение к \(n)…"
        case .connected: return printer.deviceName ?? "Подключён"
        case .printing(let p): return "Печать \(Int(p * 100))%"
        case .error: return "Ошибка"
        }
    }

    var printerDetail: String? {
        if output == .virtual { return "Сохраняю PNG в папку" }
        if case .error(let e) = printer.state { return e }
        if !printer.status.problems.isEmpty { return printer.status.problems.joined(separator: " · ") }
        if printer.isConnected { return printer.driverName }
        return printer.rememberedID == nil ? "Включите принтер и нажмите «Подключить»" : "Подключится сам при печати"
    }

    enum PrinterTone { case ok, busy, problem, off, virtual }
    var printerTone: PrinterTone {
        if output == .virtual { return .virtual }
        switch printer.state {
        case .connected: return printer.status.problems.isEmpty ? .ok : .problem
        case .printing, .connecting, .scanning: return .busy
        case .error: return .problem
        case .idle: return .off
        }
    }

    func testPrint() {
        var t = TextLabel()
        t.text = "Tiny Printer ✓\n\(Date().formatted(date: .abbreviated, time: .shortened))"
        t.sizePt = 16
        let ruler = MonoBitmap.cutLine(width: widthDots, dash: 2, gap: 2, thickness: 2)
        var q = QRLabel(); q.content = "https://github.com"; q.qrSizeMM = 18; q.caption = "QR test"
        let bm = MonoBitmap.vstack([t.render(width: widthDots), ruler, q.render(width: widthDots)])
        Task { await printReporting(bm, source: "Тестовая печать") }
    }

    // MARK: - Files, clipboard

    func loadPhoto(url: URL) {
        guard let img = ImageLoader.load(url: url) else { show("Не удалось открыть \(url.lastPathComponent)"); return }
        photoImage = img
        photoName = url.lastPathComponent
        tab = .photo
    }

    /// Files opened via Finder, Dock, or the "PDF" menu of any print dialog.
    func open(urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "pdf" {
                guard let data = try? Data(contentsOf: url) else { continue }
                let pages = DocumentRenderer.renderPDF(data: data, width: widthDots, options: docOptions)
                Task { for p in pages { await printReporting(p, source: "PDF: \(url.lastPathComponent)") } }
            } else if tab == .cards {
                loadCardImage(url: url)
            } else {
                loadPhoto(url: url)
            }
        }
    }

    func printClipboard() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bm = DocumentRenderer.renderImage(cg, width: widthDots, options: docOptions)
            Task { await printReporting(bm, source: "Буфер: картинка") }
        } else if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if let url = URL(string: s), url.scheme?.hasPrefix("http") == true, !s.contains(" ") {
                var q = QRLabel(); q.content = s; q.caption = url.host ?? ""; q.captionSizePt = 10
                Task { await printReporting(q.render(width: widthDots), source: "Буфер: QR") }
            } else {
                var t = TextLabel(); t.text = s; t.sizePt = 14; t.align = .left; t.bold = false
                Task { await printReporting(t.render(width: widthDots), source: "Буфер: текст") }
            }
        } else {
            show("В буфере нет текста или картинки")
        }
    }

    // MARK: - Cards

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TinyPrinter", isDirectory: true)
    }
    static var cardImageURL: URL { supportDir.appendingPathComponent("Cards/current.png") }
    static var aiDir: URL {
        let dir = supportDir.appendingPathComponent("AI images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sets (and remembers across launches) the picture of the card editor.
    func setCardImage(_ image: CGImage?, name: String) {
        cardImage = image
        cardImageName = image == nil ? "" : name
        defaults.set(cardImageName, forKey: "card.imageName")
        let url = Self.cardImageURL
        if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func loadCardImage(url: URL) {
        guard let img = ImageLoader.load(url: url) else { show("Не удалось открыть \(url.lastPathComponent)"); return }
        setCardImage(img, name: url.lastPathComponent)
        tab = .cards
    }

    func applyPreset(_ preset: CardPreset) {
        card = preset.design
        let suggested = Set(CardPreset.all.map(\.prompt))
        if !preset.prompt.isEmpty && (aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty || suggested.contains(aiPrompt)) {
            aiPrompt = preset.prompt
        }
    }

    // MARK: - AI pictures

    func refreshKeyMasks() {
        var masks: [AIProvider: String] = [:]
        for p in AIProvider.allCases {
            if let k = Keychain.get(p.rawValue), !k.isEmpty { masks[p] = "••••" + k.suffix(4) }
        }
        keyMasks = masks
    }

    func hasKey(_ p: AIProvider) -> Bool { keyMasks[p] != nil }

    func saveKey(_ key: String, for p: AIProvider) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        try Keychain.set(k, for: p.rawValue)
        refreshKeyMasks()
    }

    func deleteKey(_ p: AIProvider) {
        Keychain.delete(p.rawValue)
        aiModels[p] = nil
        refreshKeyMasks()
    }

    private func client(_ p: AIProvider) -> AIImageClient? {
        guard let key = Keychain.get(p.rawValue), !key.isEmpty else { return nil }
        return AIImageClient(provider: p, apiKey: key, model: ai.model(for: p), quality: ai.quality, aspect: ai.aspect)
    }

    /// Loads the image models available to the key; doubles as a key check.
    func refreshModels(_ p: AIProvider) async -> (ok: Bool, message: String) {
        guard let client = client(p) else { return (false, "Сначала сохраните ключ.") }
        do {
            let list = try await client.listModels()
            aiModels[p] = list.isEmpty ? nil : list
            let current = ai.model(for: p)
            if !list.isEmpty && !list.contains(current) {
                // The remembered model is gone (renamed or retired): take the closest known one.
                let pick = p.knownModels.first(where: list.contains) ?? list[0]
                if p == .openAI { ai.openAIModel = pick } else { ai.googleModel = pick }
                return (true, "Ключ работает. Модели \(current) нет, выбрана \(pick).")
            }
            return (true, list.isEmpty ? "Ключ работает, но моделей для картинок не найдено." : "Ключ работает. Моделей для картинок: \(list.count).")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func generateAI(useReference: Bool) {
        let p = ai.provider
        guard let client = client(p) else { aiError = AIImageError.noKey(p).localizedDescription; return }
        let reference = useReference ? cardImage : nil
        let idea = aiPrompt
        let prompt = AIPrompt.build(idea, style: ai.style, noText: ai.noText, hasReference: reference != nil)
        aiBusy = true
        aiError = nil
        Task {
            defer { aiBusy = false }
            do {
                let result = try await client.generate(prompt: prompt, reference: reference)
                let title = idea.trimmingCharacters(in: .whitespacesAndNewlines)
                let file = saveAIImage(result.data, title: title.isEmpty ? "картинка" : title)
                let record = AICostRecord(date: Date(), file: file?.lastPathComponent ?? "", provider: p,
                                          model: result.model, usage: result.usage, usd: result.cost)
                aiLedger.append(record)
                saveLedger()
                setCardImage(result.image, name: "AI: " + (title.isEmpty ? "перерисовка" : String(title.prefix(40))))
                loadAIHistory()
                show("Картинка готова · " + record.costText)
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func saveAIImage(_ data: Data, title: String) -> URL? {
        let ext: String
        if data.starts(with: [0xFF, 0xD8]) { ext = "jpg" } else if data.starts(with: Array("RIFF".utf8)) { ext = "webp" } else { ext = "png" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = String(title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " }.prefix(50))
            .trimmingCharacters(in: .whitespaces)
        let url = Self.aiDir.appendingPathComponent("\(f.string(from: Date())) \(safe).\(ext)")
        do { try data.write(to: url); return url } catch { return nil }
    }

    // MARK: - AI spend

    static var ledgerURL: URL { supportDir.appendingPathComponent("ai-costs.json") }

    private func loadLedger() {
        guard let data = try? Data(contentsOf: Self.ledgerURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        aiLedger = (try? dec.decode([AICostRecord].self, from: data)) ?? []
    }

    private func saveLedger() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try? enc.encode(aiLedger).write(to: Self.ledgerURL)
    }

    var aiSpent: Double { aiLedger.compactMap(\.usd).reduce(0, +) }

    /// "Последняя ≈ $0.025 · всего ≈ $0.075 за 3 шт."
    var aiSpendLine: String? {
        guard let last = aiLedger.last else { return nil }
        let total = aiLedger.count > 1 ? " · всего ≈ \(AIPricing.format(aiSpent)) за \(aiLedger.count) шт." : ""
        return "Последняя: \(last.costText)" + total
    }

    func resetLedger() {
        aiLedger = []
        saveLedger()
    }

    func costRecord(for item: AIHistoryItem) -> AICostRecord? {
        aiLedger.last { $0.file == item.url.lastPathComponent }
    }

    func loadAIHistory() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.aiDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        aiHistory = dated.sorted { $0.1 > $1.1 }.prefix(40).compactMap { url, _ in
            guard let cg = ImageLoader.load(url: url, maxPixelSize: 160) else { return nil }
            return AIHistoryItem(url: url, thumbnail: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    func useAIImage(_ item: AIHistoryItem) {
        guard let img = ImageLoader.load(url: item.url, maxPixelSize: 2048) else { return }
        setCardImage(img, name: "AI: " + item.title.dropFirst(20))
    }

    func trashAIImage(_ item: AIHistoryItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        loadAIHistory()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { show("Автозапуск: \(error.localizedDescription)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Local HTTP API (print system handler + tinyprint CLI)

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json([
                "ok": true, "output": output.rawValue, "connected": printer.isConnected,
                "device": printer.deviceName ?? NSNull(), "driver": printer.driverName ?? NSNull(),
                "battery": printer.status.battery ?? NSNull(), "widthDots": widthDots,
                "problems": printer.status.problems,
            ])

        case ("GET", "/log"):
            let text = printer.log.joined(separator: "\n") + "\n\nGATT:\n" + printer.gattDescription + "\n"
            return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))

        case ("POST", "/print"):
            // Documents: PDF from the print system, or images.
            var opts = docOptions
            if let m = req.query["mode"].flatMap(DocumentRenderOptions.Mode.init(rawValue:)) { opts.mode = m }
            if let t = req.bool("trim") { opts.trimBottom = t }
            let pages = DocumentRenderer.render(fileData: req.body, contentType: req.headers["content-type"],
                                                width: widthDots, options: opts)
            guard !pages.isEmpty else { return .error("не удалось разобрать документ (нужен PDF или картинка)") }
            var s = settings
            if let d = req.int("density") { s.density = d }
            switch req.query["quality"] {   // "Quality" in the macOS print dialog maps to darkness
            case "draft": s.density = max(1, s.density - 1)
            case "high": s.density = min(5, s.density + 1)
            default: break
            }
            if let p = req.query["paper"].flatMap(PrintSettings.Paper.init(rawValue:)) { s.paper = p }
            let copies = max(1, min(99, req.int("copies") ?? 1))
            if req.bool("preview") == true {
                return png(MonoBitmap.vstack(pages, spacing: 0))
            }
            let source = req.query["source"] == "ipp" ? "Системная печать" : "API: документ"
            for page in pages {
                do { try await printBitmap(page, copies: copies, settings: s) } catch {
                    history.insert(JobRecord(source: source, lengthMM: 0, ok: false, message: error.localizedDescription), at: 0)
                    return .error(error.localizedDescription, status: 503)
                }
            }
            let mm = pages.reduce(0) { $0 + Units.mm(dots: $1.height) }
            history.insert(JobRecord(source: source, lengthMM: mm * Double(copies), ok: true, message: "OK"), at: 0)
            return .json(["ok": true, "pages": pages.count, "lengthMM": Int(mm)])

        case ("POST", "/print/raw"):
            // A ready 1-bit PNG at head width (the CLI renders locally).
            guard let img = ImageLoader.load(data: req.body, maxPixelSize: 100_000) else { return .error("нужен PNG") }
            let bm = GrayImage(cgImage: img, width: img.width, height: img.height).threshold().fitted(toWidth: widthDots)
            var s = settings
            if let d = req.int("density") { s.density = d }
            if let p = req.query["paper"].flatMap(PrintSettings.Paper.init(rawValue:)) { s.paper = p }
            do {
                try await printBitmap(bm, copies: req.int("copies") ?? 1, settings: s)
                history.insert(JobRecord(source: req.query["source"] ?? "CLI", lengthMM: Units.mm(dots: bm.height), ok: true, message: "OK"), at: 0)
                return .json(["ok": true, "lengthMM": Int(Units.mm(dots: bm.height))])
            } catch {
                return .error(error.localizedDescription, status: 503)
            }

        default:
            return .error("unknown endpoint \(req.method) \(req.path)", status: 404)
        }
    }

    private func png(_ bm: MonoBitmap) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/png", body: bm.pngData() ?? Data())
    }
}
