import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Picture generation for cards and stickers through the user's own API key:
// OpenAI (GPT Image) or Google (Gemini "Nano Banana" / Imagen).

public enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI, google
    public var id: String { rawValue }
    public var title: String { self == .openAI ? "OpenAI (GPT Image)" : "Google (Gemini / Imagen)" }
    public var shortTitle: String { self == .openAI ? "OpenAI" : "Google" }
    public var defaultModel: String { self == .openAI ? "gpt-image-2" : "gemini-3.1-flash-image" }
    /// Shown until the real list is loaded from the provider.
    public var knownModels: [String] {
        switch self {
        case .openAI: return ["gpt-image-2", "gpt-image-1.5", "gpt-image-1", "gpt-image-1-mini"]
        case .google: return ["gemini-3.1-flash-image", "gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview",
                              "gemini-2.5-flash-image", "imagen-4.0-generate-001", "imagen-4.0-fast-generate-001"]
        }
    }
    public var keyPage: URL {
        URL(string: self == .openAI ? "https://platform.openai.com/api-keys" : "https://aistudio.google.com/apikey")!
    }
    public var host: String { self == .openAI ? "api.openai.com" : "generativelanguage.googleapis.com" }
    /// Where the exact spend is shown.
    public var usagePage: URL {
        URL(string: self == .openAI ? "https://platform.openai.com/usage" : "https://aistudio.google.com/usage")!
    }
}

// MARK: - Usage and cost

/// Tokens billed for one request, as reported by the provider.
public struct AIUsage: Codable, Equatable {
    public var inputTextTokens = 0
    public var inputImageTokens = 0
    public var outputImageTokens = 0
    public var outputTextTokens = 0
    public var images = 1

    public init(inputTextTokens: Int = 0, inputImageTokens: Int = 0, outputImageTokens: Int = 0,
                outputTextTokens: Int = 0, images: Int = 1) {
        self.inputTextTokens = inputTextTokens
        self.inputImageTokens = inputImageTokens
        self.outputImageTokens = outputImageTokens
        self.outputTextTokens = outputTextTokens
        self.images = images
    }

    public var totalTokens: Int { inputTextTokens + inputImageTokens + outputImageTokens + outputTextTokens }
}

/// Approximate list prices (USD) — a local estimate, the provider's usage page has the exact figure.
public enum AIPricing {
    struct Price {
        var textIn = 0.0, imageIn = 0.0, imageOut = 0.0, textOut = 0.0   // per 1M tokens
        var perImage: Double?                                              // flat-priced models (Imagen)
    }

    /// Longest matching prefix wins, so dated and suffixed names ("…-2026-09-08", "-sunburst") are covered.
    static let table: [(prefix: String, price: Price)] = [
        ("gpt-image-2", Price(textIn: 5, imageIn: 8, imageOut: 30, textOut: 10)),        // 2, 2.5, 2.6 (flare/sunburst)
        ("gpt-image-1.5", Price(textIn: 5, imageIn: 8, imageOut: 32, textOut: 10)),
        ("gpt-image-1-mini", Price(textIn: 2, imageIn: 2.5, imageOut: 8)),
        ("gpt-image-1", Price(textIn: 5, imageIn: 10, imageOut: 40)),
        ("gemini-2.5-flash-image", Price(textIn: 0.3, imageIn: 0.3, imageOut: 30, textOut: 2.5)),
        ("gemini-3.1-flash-image", Price(textIn: 0.5, imageIn: 0.5, imageOut: 60, textOut: 3)),
        ("gemini-3-pro-image", Price(textIn: 2, imageIn: 2, imageOut: 120, textOut: 12)),
        ("imagen-4.0-ultra", Price(perImage: 0.06)),
        ("imagen-4.0-fast", Price(perImage: 0.02)),
        ("imagen-4.0", Price(perImage: 0.04)),
        ("imagen-3", Price(perImage: 0.03)),
    ]

    static func price(for model: String) -> Price? {
        let m = model.lowercased().replacingOccurrences(of: "models/", with: "")
        return table.filter { m.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
    }

    /// Estimated cost in USD, or nil for models without a known price.
    public static func cost(model: String, usage: AIUsage) -> Double? {
        guard let p = price(for: model) else { return nil }
        if let flat = p.perImage { return flat * Double(max(1, usage.images)) }
        let perM = 1_000_000.0
        return (Double(usage.inputTextTokens) * p.textIn + Double(usage.inputImageTokens) * p.imageIn
            + Double(usage.outputImageTokens) * p.imageOut + Double(usage.outputTextTokens) * p.textOut) / perM
    }

    /// "$0.025" for small sums, "$1.23" otherwise.
    public static func format(_ usd: Double) -> String {
        String(format: usd < 0.995 ? "$%.3f" : "$%.2f", usd)
    }
}

public struct AIImageResult {
    /// The encoded image exactly as received.
    public let data: Data
    public let image: CGImage
    /// nil when the response carried no usage (and the model is not flat-priced).
    public let usage: AIUsage?
    public let model: String
    public var cost: Double? { usage.flatMap { AIPricing.cost(model: model, usage: $0) } }
}

public enum AIAspect: String, Codable, CaseIterable, Identifiable {
    case square, portrait, landscape
    public var id: String { rawValue }
    public var title: String {
        switch self { case .square: return String(localized: "Квадрат", bundle: .tinyPrinter); case .portrait: return String(localized: "Вертикально", bundle: .tinyPrinter); case .landscape: return String(localized: "Горизонтально", bundle: .tinyPrinter) }
    }
    var openAISize: String {
        switch self { case .square: return "1024x1024"; case .portrait: return "1024x1536"; case .landscape: return "1536x1024" }
    }
    var googleRatio: String {
        switch self { case .square: return "1:1"; case .portrait: return "3:4"; case .landscape: return "4:3" }
    }
}

public enum AIQuality: String, Codable, CaseIterable, Identifiable {
    case low, medium, high
    public var id: String { rawValue }
    public var title: String {
        switch self { case .low: return String(localized: "Быстро и дёшево", bundle: .tinyPrinter); case .medium: return String(localized: "Средне", bundle: .tinyPrinter); case .high: return String(localized: "Максимум", bundle: .tinyPrinter) }
    }
}

/// Drawing styles that survive a 1-bit, 203 dpi thermal print.
public enum AIStyle: String, Codable, CaseIterable, Identifiable {
    case lineArt, cute, doodle, woodcut, silhouette, tattoo, pixel, photo
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lineArt: return String(localized: "Контурный рисунок", bundle: .tinyPrinter)
        case .cute: return String(localized: "Милый стикер", bundle: .tinyPrinter)
        case .doodle: return String(localized: "Дудл от руки", bundle: .tinyPrinter)
        case .woodcut: return String(localized: "Гравюра", bundle: .tinyPrinter)
        case .silhouette: return String(localized: "Силуэт", bundle: .tinyPrinter)
        case .tattoo: return String(localized: "Тату-флеш", bundle: .tinyPrinter)
        case .pixel: return String(localized: "Пиксель-арт", bundle: .tinyPrinter)
        case .photo: return String(localized: "Как есть (фото, растр)", bundle: .tinyPrinter)
        }
    }
    var prompt: String {
        switch self {
        case .lineArt: return "Clean coloring-book line art with bold, uniform black outlines and no fills."
        case .cute: return "Cute kawaii sticker illustration: bold black outlines, simple shapes, a few solid black accents."
        case .doodle: return "Playful hand-drawn doodle made with a thick black marker."
        case .woodcut: return "Woodcut / linocut print: bold carved black shapes and simple hatching."
        case .silhouette: return "Solid black silhouette with minimal inner detail."
        case .tattoo: return "Old-school tattoo flash style: thick bold outlines and solid black areas."
        case .pixel: return "1-bit pixel art with large, clearly visible square pixels."
        case .photo: return ""
        }
    }
}

public struct AISettings: Codable, Equatable {
    public var provider: AIProvider = .openAI
    public var openAIModel = AIProvider.openAI.defaultModel
    public var googleModel = AIProvider.google.defaultModel
    public var quality: AIQuality = .low
    public var aspect: AIAspect = .square
    public var style: AIStyle = .lineArt
    /// Ask the model not to draw any lettering: card text is set by the app, in proper fonts.
    public var noText = true

    public init() {}

    public func model(for p: AIProvider) -> String {
        let m = (p == .openAI ? openAIModel : googleModel).trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? p.defaultModel : m
    }
}

public enum AIPrompt {
    /// Wraps the user's idea with instructions that make the picture printable on thermal paper.
    public static func build(_ idea: String, style: AIStyle, noText: Bool, hasReference: Bool) -> String {
        var parts: [String] = []
        let idea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasReference {
            parts.append("Redraw the attached picture as a printable illustration." + (idea.isEmpty ? "" : " \(idea)"))
        } else {
            parts.append(idea)
        }
        if style != .photo {
            parts.append(style.prompt)
            parts.append("Pure black ink on a plain pure white background. No gray, no color, no gradients, no shading, no shadows. "
                + "High contrast, simple composition, single subject centered with white space around it, nothing touching the edges. "
                + "It will be printed on a tiny 2-inch black-and-white thermal sticker printer.")
        } else {
            parts.append("Plain white background, subject centered, good contrast.")
        }
        if noText { parts.append("Do not add any text, letters or numbers.") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum AIImageError: LocalizedError, Equatable {
    case noKey(AIProvider)
    case emptyPrompt
    case http(Int, String)
    case noImage(String)
    case badResponse
    case referenceUnsupported

    public var errorDescription: String? {
        switch self {
        case .noKey(let p): return String(localized: "Нет ключа API \(p.shortTitle). Добавьте его в настройках (⌘,).", bundle: .tinyPrinter)
        case .emptyPrompt: return String(localized: "Опишите, что нарисовать.", bundle: .tinyPrinter)
        case .http(let code, let msg):
            switch code {
            case 401, 403: return String(localized: "Ключ не подошёл (\(code)): \(msg)", bundle: .tinyPrinter)
            case 404: return String(localized: "Модель не найдена (\(code)): \(msg). Обновите список моделей в настройках.", bundle: .tinyPrinter)
            case 429: return String(localized: "Лимит запросов или закончились средства на счёте (\(code)): \(msg)", bundle: .tinyPrinter)
            default: return String(localized: "Ошибка сервиса (\(code)): \(msg)", bundle: .tinyPrinter)
            }
        case .noImage(let text): return String(localized: "Модель не вернула картинку", bundle: .tinyPrinter) + (text.isEmpty ? "." : ": \(text)")
        case .badResponse: return String(localized: "Непонятный ответ сервиса.", bundle: .tinyPrinter)
        case .referenceUnsupported: return String(localized: "Модели Imagen не умеют перерисовывать картинку — выберите модель Gemini.", bundle: .tinyPrinter)
        }
    }
}

public struct AIImageClient {
    public var provider: AIProvider
    public var apiKey: String
    public var model: String
    public var quality: AIQuality
    public var aspect: AIAspect
    public var session: URLSession = .shared

    public init(provider: AIProvider, apiKey: String, model: String, quality: AIQuality = .low, aspect: AIAspect = .square) {
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.quality = quality
        self.aspect = aspect
    }

    static let openAIBase = URL(string: "https://api.openai.com/v1/")!
    static let googleBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    var isImagen: Bool { model.lowercased().hasPrefix("imagen") }

    public func generate(prompt: String, reference: CGImage? = nil) async throws -> AIImageResult {
        guard !apiKey.isEmpty else { throw AIImageError.noKey(provider) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIImageError.emptyPrompt }
        let refPNG = reference.flatMap { Self.png($0, maxSide: 1024) }
        let request = try makeRequest(prompt: prompt, referencePNG: refPNG)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let usage = Self.parseUsage(provider: provider, data: data) ?? (isImagen ? AIUsage() : nil)
        var imageData = try Self.parseImage(provider: provider, data: data)
        if case .url(let url) = imageData {
            let (d, r) = try await session.data(from: url)
            try Self.check(r, d)
            imageData = .bytes(d)
        }
        guard case .bytes(let bytes) = imageData, let img = ImageLoader.load(data: bytes, maxPixelSize: 2048) else {
            throw AIImageError.badResponse
        }
        return AIImageResult(data: bytes, image: img, usage: usage, model: model)
    }

    /// Image models available to this key (also a cheap way to check the key).
    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIImageError.noKey(provider) }
        var req: URLRequest
        switch provider {
        case .openAI:
            req = URLRequest(url: Self.openAIBase.appendingPathComponent("models"))
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .google:
            var c = URLComponents(url: Self.googleBase.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            req = URLRequest(url: c.url!)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        return Self.parseModels(provider: provider, data: data)
    }

    // MARK: Requests

    func makeRequest(prompt: String, referencePNG: Data?) throws -> URLRequest {
        switch provider {
        case .openAI:
            if let referencePNG { return openAIEdit(prompt: prompt, png: referencePNG) }
            var req = URLRequest(url: Self.openAIBase.appendingPathComponent("images/generations"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["model": model, "prompt": prompt, "n": 1, "size": aspect.openAISize]
            if model.hasPrefix("dall-e") {
                body["response_format"] = "b64_json"
                if model == "dall-e-3" && aspect != .square { body["size"] = aspect == .portrait ? "1024x1792" : "1792x1024" }
            } else {
                body["quality"] = quality.rawValue
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 240
            return req

        case .google:
            if isImagen {
                guard referencePNG == nil else { throw AIImageError.referenceUnsupported }
                var req = googleRequest(method: "predict")
                let body: [String: Any] = [
                    "instances": [["prompt": prompt]],
                    "parameters": ["sampleCount": 1, "aspectRatio": aspect.googleRatio],
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                return req
            }
            var req = googleRequest(method: "generateContent")
            var parts: [[String: Any]] = [["text": prompt]]
            if let referencePNG {
                parts.append(["inlineData": ["mimeType": "image/png", "data": referencePNG.base64EncodedString()]])
            }
            let body: [String: Any] = [
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": [
                    "responseModalities": ["TEXT", "IMAGE"],
                    "imageConfig": ["aspectRatio": aspect.googleRatio],
                ],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return req
        }
    }

    private func googleRequest(method: String) -> URLRequest {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? name
        var req = URLRequest(url: URL(string: Self.googleBase.absoluteString + "models/\(safe):\(method)")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 240
        return req
    }

    private func openAIEdit(prompt: String, png: Data) -> URLRequest {
        let boundary = "TinyPrinter-\(UUID().uuidString)"
        var req = URLRequest(url: Self.openAIBase.appendingPathComponent("images/edits"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", prompt)
        field("n", "1")
        field("size", aspect.openAISize)
        if !model.hasPrefix("dall-e") { field("quality", quality.rawValue) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        req.timeoutInterval = 240
        return req
    }

    // MARK: Responses

    enum ImageData: Equatable { case bytes(Data), url(URL) }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIImageError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIImageError.http(http.statusCode, errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    /// `{"error": {"message": …}}` — the same shape for OpenAI and Google.
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let s = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let msg = obj["error"] as? String { return msg }
        return nil
    }

    static func parseImage(provider: AIProvider, data: Data) throws -> ImageData {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIImageError.badResponse }
        switch provider {
        case .openAI:
            guard let first = (obj["data"] as? [[String: Any]])?.first else { throw AIImageError.noImage(errorMessage(data) ?? "") }
            if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) { return .bytes(d) }
            if let s = first["url"] as? String, let u = URL(string: s) { return .url(u) }
            throw AIImageError.noImage(first["revised_prompt"] as? String ?? "")
        case .google:
            // Imagen (predict)
            if let preds = obj["predictions"] as? [[String: Any]] {
                for p in preds {
                    if let b64 = p["bytesBase64Encoded"] as? String, let d = Data(base64Encoded: b64) { return .bytes(d) }
                }
                throw AIImageError.noImage("")
            }
            // Gemini (generateContent)
            var texts: [String] = []
            for cand in obj["candidates"] as? [[String: Any]] ?? [] {
                let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts {
                    let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
                    if let b64 = inline?["data"] as? String, let d = Data(base64Encoded: b64) { return .bytes(d) }
                    if let t = part["text"] as? String { texts.append(t) }
                }
                if texts.isEmpty, let reason = cand["finishReason"] as? String, reason != "STOP" { texts.append(reason) }
            }
            if let fb = obj["promptFeedback"] as? [String: Any], let reason = fb["blockReason"] as? String {
                texts.append(String(localized: "запрос заблокирован (\(reason))", bundle: .tinyPrinter))
            }
            throw AIImageError.noImage(texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// OpenAI `usage` or Gemini `usageMetadata`. Imagen reports none (it is priced per image).
    static func parseUsage(provider: AIProvider, data: Data) -> AIUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let int = { (v: Any?) in (v as? NSNumber)?.intValue ?? 0 }
        switch provider {
        case .openAI:
            guard let u = obj["usage"] as? [String: Any] else { return nil }
            let inDetails = u["input_tokens_details"] as? [String: Any]
            let outDetails = u["output_tokens_details"] as? [String: Any]
            let input = int(u["input_tokens"]), output = int(u["output_tokens"])
            var usage = AIUsage(images: max(1, (obj["data"] as? [Any])?.count ?? 1))
            if let inDetails {
                usage.inputTextTokens = int(inDetails["text_tokens"])
                usage.inputImageTokens = int(inDetails["image_tokens"])
            } else {
                usage.inputTextTokens = input
            }
            if let outDetails, outDetails["image_tokens"] != nil {
                usage.outputImageTokens = int(outDetails["image_tokens"])
                usage.outputTextTokens = int(outDetails["text_tokens"])
            } else {
                usage.outputImageTokens = output
            }
            return usage
        case .google:
            guard let u = obj["usageMetadata"] as? [String: Any] else { return nil }
            func byModality(_ key: String) -> (text: Int, image: Int)? {
                guard let list = u[key] as? [[String: Any]] else { return nil }
                var t = 0, i = 0
                for d in list {
                    if (d["modality"] as? String) == "IMAGE" { i += int(d["tokenCount"]) } else { t += int(d["tokenCount"]) }
                }
                return (t, i)
            }
            var usage = AIUsage()
            if let p = byModality("promptTokensDetails") {
                usage.inputTextTokens = p.text; usage.inputImageTokens = p.image
            } else {
                usage.inputTextTokens = int(u["promptTokenCount"])
            }
            let candidates = int(u["candidatesTokenCount"])
            if let c = byModality("candidatesTokensDetails") {
                usage.outputImageTokens = c.image
                usage.outputTextTokens = max(c.text, candidates - c.image)
            } else {
                usage.outputImageTokens = candidates
            }
            usage.outputTextTokens += int(u["thoughtsTokenCount"])   // thinking is billed as text output
            return usage
        }
    }

    static func parseModels(provider: AIProvider, data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let ids: [String]
        switch provider {
        case .openAI:
            ids = (obj["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { $0.contains("image") || $0.hasPrefix("dall-e") }
        case .google:
            ids = (obj["models"] as? [[String: Any]] ?? []).compactMap { m -> String? in
                guard let name = m["name"] as? String else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                guard id.contains("image"), !id.contains("embedding") else { return nil }
                return id
            }
        }
        return Array(Set(ids)).sorted { a, b in
            // Newest-looking names first: higher version numbers sort later alphabetically, so reverse.
            a.localizedStandardCompare(b) == .orderedDescending
        }
    }

    /// PNG of the picture scaled to fit `maxSide` (keeps uploads small).
    static func png(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
