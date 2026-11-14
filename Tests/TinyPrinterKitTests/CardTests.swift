import CoreGraphics
import XCTest
@testable import TinyPrinterKit

final class CardTests: XCTestCase {
    /// A black disc on white, like a simple line-art picture.
    private func disc(size: Int = 300) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return ctx.makeImage()!
    }

    func testEveryPresetFrameAndOrnamentRenders() {
        for p in CardPreset.all {
            for image in [nil, disc()] {
                let bm = p.design.render(width: 384, image: image)
                XCTAssertEqual(bm.width, 384, p.id)
                XCTAssertGreaterThanOrEqual(bm.height, Units.dots(mm: 10), p.id)
                if image != nil || p.id != "sticker" { XCTAssertGreaterThan(bm.blackRatio, 0.005, p.id) }
            }
        }
        var d = CardDesign()
        for f in CardFrame.allCases {
            for o in CardOrnament.allCases {
                d.frame = f; d.ornament = o
                let bm = d.render(width: 384)
                XCTAssertEqual(bm.width, 384)
                XCTAssertGreaterThan(bm.height, 0, "\(f) \(o)")
            }
        }
    }

    func testFixedLengthIsHonoured() {
        var d = CardPreset.all.first { $0.id == "birthday" }!.design
        d.lengthMM = 90
        let bm = d.render(width: 384, image: disc(size: 900))
        XCTAssertEqual(bm.height, Units.dots(mm: 90), "a big picture shrinks to fit the fixed length")
    }

    func testRepeatStacksCopies() {
        var d = CardDesign.blank
        d.title = "Hi"
        let one = d.render(width: 384)
        d.repeatCount = 3
        XCTAssertGreaterThan(d.render(width: 384).height, one.height * 3)
    }

    func testStickerCutOutlineSurroundsTheInk() {
        var d = CardDesign.blank.switched(to: .sticker)
        d.imageWidthPercent = 50
        d.cutOutline = false
        let plain = d.render(width: 384, image: disc())
        d.cutOutline = true
        let cut = d.render(width: 384, image: disc())
        XCTAssertEqual(plain.height, cut.height)
        XCTAssertGreaterThan(cut.blackRatio, plain.blackRatio)
        // On the middle row the contour is left of the leftmost ink, separated by white.
        let y = cut.height / 2
        let ink = (0..<plain.width).first { plain[$0, y] }!
        let line = (0..<cut.width).first { cut[$0, y] }!
        XCTAssertLessThan(line, ink - Units.dots(mm: 1))
        XCTAssertTrue((line + 4..<ink).contains { !cut[$0, y] })
    }

    func testOutlineIgnoresHolesAndBridgesGaps() {
        // Two blobs 10 dots apart: the closing must bridge them into one contour (no line between them).
        var bm = MonoBitmap(width: 200, height: 100)
        for y in 40..<60 { for x in 40..<90 { bm[x, y] = true }; for x in 100..<150 { bm[x, y] = true } }
        let o = bm.outline(distance: 8, thickness: 2)
        XCTAssertFalse((38...61).contains { o[95, $0] }, "no contour inside the bridged gap")
        XCTAssertTrue((28..<38).contains { o[95, $0] }, "contour passes just above the gap")
        XCTAssertTrue((28..<34).contains { o[60, $0] }, "8 dots above the ink")
    }

    func testTrimWhiteCropsMargins() {
        let img = disc(size: 400)
        let t = CardArt.trimmedWhite(img)
        XCTAssertLessThan(t.width, 260)
        XCTAssertGreaterThan(t.width, 195)
    }

    // MARK: - AI requests

    func testPromptMentionsThermalConstraints() {
        let p = AIPrompt.build("котик", style: .lineArt, noText: true, hasReference: false)
        XCTAssertTrue(p.hasPrefix("котик"))
        XCTAssertTrue(p.contains("white background"))
        XCTAssertTrue(p.contains("Do not add any text"))
        XCTAssertTrue(AIPrompt.build("", style: .cute, noText: false, hasReference: true).hasPrefix("Redraw the attached picture"))
    }

    private func json(_ req: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    func testOpenAIRequest() throws {
        let c = AIImageClient(provider: .openAI, apiKey: " sk-test ", model: "gpt-image-2", quality: .low, aspect: .portrait)
        let req = try c.makeRequest(prompt: "cat", referencePNG: nil)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = json(req)
        XCTAssertEqual(body["model"] as? String, "gpt-image-2")
        XCTAssertEqual(body["size"] as? String, "1024x1536")
        XCTAssertEqual(body["quality"] as? String, "low")

        let edit = try c.makeRequest(prompt: "cat", referencePNG: Data([0x89, 0x50]))
        XCTAssertEqual(edit.url?.path, "/v1/images/edits")
        XCTAssertTrue(edit.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        let text = String(decoding: edit.httpBody!, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"image\"; filename=\"reference.png\""))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-image-2\r\n"))
    }

    func testGoogleRequests() throws {
        let g = AIImageClient(provider: .google, apiKey: "AIza", model: "gemini-3.1-flash-image", aspect: .square)
        let req = try g.makeRequest(prompt: "cat", referencePNG: Data([1, 2, 3]))
        XCTAssertEqual(req.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "AIza")
        let body = json(req)
        let parts = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(parts.first?["text"] as? String, "cat")
        XCTAssertEqual((parts.last?["inlineData"] as? [String: Any])?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["responseModalities"] as? [String], ["TEXT", "IMAGE"])

        let imagen = AIImageClient(provider: .google, apiKey: "AIza", model: "imagen-4.0-generate-001", aspect: .landscape)
        let ireq = try imagen.makeRequest(prompt: "cat", referencePNG: nil)
        XCTAssertTrue(ireq.url!.absoluteString.hasSuffix("models/imagen-4.0-generate-001:predict"))
        XCTAssertEqual((json(ireq)["parameters"] as? [String: Any])?["aspectRatio"] as? String, "4:3")
        XCTAssertThrowsError(try imagen.makeRequest(prompt: "cat", referencePNG: Data([1])))
    }

    func testParseResponses() throws {
        let png = AIImageClient.png(disc(size: 64), maxSide: 64)!
        let b64 = png.base64EncodedString()

        let openAI = Data(#"{"created":1,"data":[{"b64_json":"\#(b64)"}]}"#.utf8)
        XCTAssertEqual(try AIImageClient.parseImage(provider: .openAI, data: openAI), .bytes(png))

        let gemini = Data(#"{"candidates":[{"content":{"parts":[{"text":"Here you go"},{"inlineData":{"mimeType":"image/png","data":"\#(b64)"}}]}}]}"#.utf8)
        XCTAssertEqual(try AIImageClient.parseImage(provider: .google, data: gemini), .bytes(png))

        let imagen = Data(#"{"predictions":[{"bytesBase64Encoded":"\#(b64)","mimeType":"image/png"}]}"#.utf8)
        XCTAssertEqual(try AIImageClient.parseImage(provider: .google, data: imagen), .bytes(png))

        let refusal = Data(#"{"candidates":[{"content":{"parts":[{"text":"I can't draw that."}]},"finishReason":"STOP"}]}"#.utf8)
        XCTAssertThrowsError(try AIImageClient.parseImage(provider: .google, data: refusal)) { err in
            XCTAssertEqual(err as? AIImageError, .noImage("I can't draw that."))
        }

        let error = Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8)
        XCTAssertEqual(AIImageClient.errorMessage(error), "Incorrect API key provided")
    }

    func testParseModelLists() {
        let openAI = Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-image-2"},{"id":"gpt-image-1"},{"id":"dall-e-3"},{"id":"whisper-1"}]}"#.utf8)
        XCTAssertEqual(Set(AIImageClient.parseModels(provider: .openAI, data: openAI)), ["gpt-image-2", "gpt-image-1", "dall-e-3"])
        let google = Data(#"{"models":[{"name":"models/gemini-3-pro"},{"name":"models/gemini-3.1-flash-image"},{"name":"models/imagen-4.0-generate-001"},{"name":"models/gemini-embedding-001"}]}"#.utf8)
        XCTAssertEqual(Set(AIImageClient.parseModels(provider: .google, data: google)), ["gemini-3.1-flash-image", "imagen-4.0-generate-001"])
    }

    // MARK: - Usage and cost

    func testOpenAIUsageAndCost() {
        let resp = Data(#"{"data":[{"b64_json":"AA=="}],"usage":{"input_tokens":160,"output_tokens":824,"total_tokens":984,"input_tokens_details":{"text_tokens":160,"image_tokens":0}}}"#.utf8)
        let u = AIImageClient.parseUsage(provider: .openAI, data: resp)!
        XCTAssertEqual(u, AIUsage(inputTextTokens: 160, inputImageTokens: 0, outputImageTokens: 824))
        // 160 × $5/M + 824 × $30/M = $0.0008 + $0.02472
        XCTAssertEqual(AIPricing.cost(model: "gpt-image-2.6-sunburst", usage: u)!, 0.02552, accuracy: 1e-9)
        XCTAssertEqual(AIPricing.cost(model: "gpt-image-2.5-flare-2026-09-08", usage: u)!, 0.02552, accuracy: 1e-9)
        XCTAssertEqual(AIPricing.cost(model: "gpt-image-1-mini", usage: u)!, (160 * 2 + 824 * 8) / 1e6, accuracy: 1e-9)
        XCTAssertNil(AIPricing.cost(model: "some-future-model", usage: u))
        XCTAssertEqual(AIPricing.format(0.02552), "$0.026")
        XCTAssertEqual(AIPricing.format(1.234), "$1.23")
    }

    func testGeminiUsageAndImagenFlatPrice() {
        let resp = Data(#"{"candidates":[],"usageMetadata":{"promptTokenCount":120,"candidatesTokenCount":1300,"totalTokenCount":1420,"promptTokensDetails":[{"modality":"TEXT","tokenCount":120}],"candidatesTokensDetails":[{"modality":"IMAGE","tokenCount":1290},{"modality":"TEXT","tokenCount":10}]}}"#.utf8)
        let u = AIImageClient.parseUsage(provider: .google, data: resp)!
        XCTAssertEqual(u, AIUsage(inputTextTokens: 120, inputImageTokens: 0, outputImageTokens: 1290, outputTextTokens: 10))
        XCTAssertEqual(AIPricing.cost(model: "gemini-2.5-flash-image", usage: u)!, (120 * 0.3 + 1290 * 30 + 10 * 2.5) / 1e6, accuracy: 1e-9)
        XCTAssertEqual(AIPricing.cost(model: "imagen-4.0-fast-generate-001", usage: AIUsage())!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(AIPricing.cost(model: "imagen-4.0-generate-001", usage: AIUsage())!, 0.04, accuracy: 1e-9)
    }
}
