import CoreGraphics
import Foundation
import TinyPrinterKit

// tinyprint — command line front-end. Renders labels locally and hands them to the running
// Tiny Printer app (which owns the Bluetooth connection) via its local API on 127.0.0.1:8614.

let usage = String(localized: """
tinyprint — печать на Tiny Printer из терминала

  tinyprint status
  tinyprint log                         журнал подключения и GATT-профиль принтера
  tinyprint text "Текст" [--size 24] [--along] [--length 40] [--left|--right] [--regular] [--border] [--invert] [--font Name]
  tinyprint qr "https://…" [--caption "Подпись"] [--side] [--qr-size 30] [--length 40]
  tinyprint image фото.jpg [--dither atkinson|floyd|ordered|threshold] [--rotate] [--width 100] [--max-length 80]
  tinyprint file документ.pdf [--mode auto|text|photo] [--trim]
  tinyprint card [--preset birthday] [--title "…"] [--message "…"] [--signature "…"] [--image файл.png]
                 [--frame scallop] [--ornament stars] [--cut] [--length 80] [--repeat 3]
  tinyprint card --list                 шаблоны, рамки и украшения

Общие опции:
  --preview out.png     не печатать, сохранить PNG того, что напечатается
  --copies N            копий (по умолчанию 1)
  --density 1…5         плотность (по умолчанию — из настроек приложения)
  --paper sticker|receipt
""", bundle: .tinyPrinter)

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        let valueOptions: Set<String> = ["size", "length", "font", "caption", "qr-size", "dither", "width", "max-length",
                                         "mode",
                                         "preview", "copies", "density", "paper",
                                         "preset", "title", "message", "signature", "image", "frame", "ornament", "repeat"]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if valueOptions.contains(key), i + 1 < argv.count { options[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func double(_ k: String) -> Double? { options[k].flatMap(Double.init) }
    func int(_ k: String) -> Int? { options[k].flatMap(Int.init) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let api = URL(string: "http://127.0.0.1:8614")!

func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
             query: [URLQueryItem] = []) -> (Int, Data)? {
    var comps = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { comps.queryItems = query }
    var req = URLRequest(url: comps.url!, timeoutInterval: 600)
    req.httpMethod = method
    req.httpBody = body
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    let sem = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

func printerWidth() -> Int {
    guard let (code, data) = request("status"), code == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let w = obj["widthDots"] as? Int else { return 384 }
    return w
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = args.positional.first else { print(usage); exit(0) }
let rest = Array(args.positional.dropFirst())

var printQuery: [URLQueryItem] = [URLQueryItem(name: "copies", value: String(args.int("copies") ?? 1)),
                                  URLQueryItem(name: "source", value: "CLI: \(command)")]
if let d = args.options["density"] { printQuery.append(URLQueryItem(name: "density", value: d)) }
if let p = args.options["paper"] { printQuery.append(URLQueryItem(name: "paper", value: p)) }

/// Sends a rendered bitmap, or writes it to --preview.
func output(_ bm: MonoBitmap) {
    guard bm.height > 0 else { fail(String(localized: "Пустая этикетка", bundle: .tinyPrinter)) }
    let mm = Int(Units.mm(dots: bm.height).rounded())
    if let path = args.options["preview"] {
        do { try bm.pngData()!.write(to: URL(fileURLWithPath: path)) } catch { fail(String(localized: "Не удалось записать \(path): \(error.localizedDescription)", bundle: .tinyPrinter)) }
        print(String(localized: "Превью: \(path) (\(bm.width)×\(bm.height) точек, \(mm) мм)", bundle: .tinyPrinter))
        return
    }
    guard let (code, data) = request("print/raw", method: "POST", body: bm.pngData(), contentType: "image/png", query: printQuery) else {
        fail(String(localized: "Приложение Tiny Printer не запущено (нет ответа на 127.0.0.1:8614)", bundle: .tinyPrinter))
    }
    if code != 200 { fail(String(localized: "Ошибка: ", bundle: .tinyPrinter) + (String(data: data, encoding: .utf8) ?? "\(code)")) }
    print(String(localized: "Напечатано: \(mm) мм", bundle: .tinyPrinter))
}

switch command {
case "status":
    guard let (_, data) = request("status") else { fail(String(localized: "Приложение Tiny Printer не запущено", bundle: .tinyPrinter)) }
    print(String(data: data, encoding: .utf8) ?? "")

case "log":
    guard let (_, data) = request("log") else { fail(String(localized: "Приложение Tiny Printer не запущено", bundle: .tinyPrinter)) }
    print(String(data: data, encoding: .utf8) ?? "")

case "text":
    guard let text = rest.first else { fail(String(localized: "Укажите текст: tinyprint text \"Привет\"", bundle: .tinyPrinter)) }
    var t = TextLabel()
    t.text = text.replacingOccurrences(of: "\\n", with: "\n")
    t.sizePt = args.double("size") ?? 24
    t.alongTape = args.flags.contains("along")
    t.autoFit = args.options["size"] == nil && t.alongTape
    t.lengthMM = args.double("length") ?? 0
    t.align = args.flags.contains("left") ? .left : args.flags.contains("right") ? .right : .center
    t.bold = !args.flags.contains("regular")
    t.border = args.flags.contains("border")
    t.invert = args.flags.contains("invert")
    t.fontName = args.options["font"] ?? ""
    output(t.render(width: args.options["preview"] == nil ? printerWidth() : 384))

case "qr":
    guard let content = rest.first else { fail(String(localized: "Укажите содержимое: tinyprint qr \"https://…\"", bundle: .tinyPrinter)) }
    var q = QRLabel()
    q.content = content
    q.caption = (args.options["caption"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
    q.layout = args.flags.contains("side") ? .side : .stacked
    q.qrSizeMM = args.double("qr-size") ?? 30
    q.lengthMM = args.double("length") ?? 0
    output(q.render(width: args.options["preview"] == nil ? printerWidth() : 384))

case "image":
    guard let path = rest.first, let img = ImageLoader.load(url: URL(fileURLWithPath: path)) else { fail(String(localized: "Не удалось открыть картинку", bundle: .tinyPrinter)) }
    var p = PhotoSettings()
    switch args.options["dither"] ?? "atkinson" {
    case "floyd": p.dither = .floydSteinberg
    case "ordered", "bayer": p.dither = .ordered
    case "threshold": p.dither = .threshold
    default: p.dither = .atkinson
    }
    p.rotate = args.flags.contains("rotate")
    p.widthPercent = args.double("width") ?? 100
    p.maxLengthMM = args.double("max-length") ?? 0
    output(p.render(img, width: args.options["preview"] == nil ? printerWidth() : 384))

case "file":
    guard let path = rest.first, let data = FileManager.default.contents(atPath: path) else { fail(String(localized: "Не удалось прочитать файл", bundle: .tinyPrinter)) }
    var opts = DocumentRenderOptions()
    if let m = args.options["mode"].flatMap(DocumentRenderOptions.Mode.init(rawValue:)) { opts.mode = m }
    opts.trimBottom = args.flags.contains("trim")
    if args.options["preview"] != nil {
        let pages = DocumentRenderer.render(fileData: data, contentType: nil, width: 384, options: opts)
        output(MonoBitmap.vstack(pages))
    } else {
        var q = printQuery
        if let m = args.options["mode"] { q.append(URLQueryItem(name: "mode", value: m)) }
        if opts.trimBottom { q.append(URLQueryItem(name: "trim", value: "1")) }
        let type = path.lowercased().hasSuffix(".pdf") ? "application/pdf" : "application/octet-stream"
        guard let (code, body) = request("print", method: "POST", body: data, contentType: type, query: q) else {
            fail(String(localized: "Приложение Tiny Printer не запущено", bundle: .tinyPrinter))
        }
        if code != 200 { fail(String(localized: "Ошибка: ", bundle: .tinyPrinter) + (String(data: body, encoding: .utf8) ?? "\(code)")) }
        print(String(data: body, encoding: .utf8) ?? "OK")
    }

case "card":
    if args.flags.contains("list") {
        print(String(localized: "Шаблоны:  ", bundle: .tinyPrinter) + CardPreset.all.map { "\($0.id) (\($0.title))" }.joined(separator: ", "))
        print(String(localized: "Рамки:    ", bundle: .tinyPrinter) + CardFrame.allCases.map(\.rawValue).joined(separator: ", "))
        print(String(localized: "Украшения: ", bundle: .tinyPrinter) + CardOrnament.allCases.map(\.rawValue).joined(separator: ", "))
        exit(0)
    }
    var card = CardDesign()
    if let id = args.options["preset"] {
        guard let p = CardPreset.all.first(where: { $0.id == id }) else { fail(String(localized: "Нет шаблона \(id). tinyprint card --list", bundle: .tinyPrinter)) }
        card = p.design
    }
    let unescape = { (s: String) in s.replacingOccurrences(of: "\\n", with: "\n") }
    if let t = args.options["title"] { card.title = unescape(t) }
    if let m = args.options["message"] { card.message = unescape(m) }
    if let s = args.options["signature"] { card.signature = unescape(s) }
    if let f = args.options["frame"] {
        guard let v = CardFrame(rawValue: f) else { fail(String(localized: "Нет рамки \(f). tinyprint card --list", bundle: .tinyPrinter)) }
        card.frame = v
    }
    if let o = args.options["ornament"] {
        guard let v = CardOrnament(rawValue: o) else { fail(String(localized: "Нет украшения \(o). tinyprint card --list", bundle: .tinyPrinter)) }
        card.ornament = v
    }
    if args.flags.contains("cut") { card.cutOutline = true }
    if let l = args.double("length") { card.lengthMM = l }
    if let r = args.int("repeat") { card.repeatCount = max(1, r) }
    var image: CGImage?
    if let path = args.options["image"] {
        guard let img = ImageLoader.load(url: URL(fileURLWithPath: path)) else { fail(String(localized: "Не удалось открыть картинку \(path)", bundle: .tinyPrinter)) }
        image = img
    }
    output(card.render(width: args.options["preview"] == nil ? printerWidth() : 384, image: image))

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
