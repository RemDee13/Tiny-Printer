import CoreGraphics
import Foundation

public enum DitherMethod: String, CaseIterable, Codable, Identifiable {
    case threshold, floydSteinberg, atkinson, ordered

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .threshold: return "Порог (текст, QR)"
        case .floydSteinberg: return "Флойд–Стейнберг"
        case .atkinson: return "Аткинсон (фото)"
        case .ordered: return "Растр (Байер)"
        }
    }
}

/// Grayscale working buffer. Values are luminance: 0 = black, 1 = white.
public struct GrayImage {
    public let width: Int
    public let height: Int
    public var data: [Float]

    public init(width: Int, height: Int, fill: Float = 1) {
        self.width = width
        self.height = height
        self.data = [Float](repeating: fill, count: width * height)
    }

    /// Reads an 8-bit DeviceGray bitmap context.
    public init(context: CGContext) {
        width = context.width
        height = context.height
        let bpr = context.bytesPerRow
        let ptr = context.data!.bindMemory(to: UInt8.self, capacity: bpr * height)
        var out = [Float](repeating: 1, count: width * height)
        for y in 0..<height {
            let row = ptr + y * bpr
            for x in 0..<width { out[y * width + x] = Float(row[x]) / 255 }
        }
        data = out
    }

    /// Draws `image` scaled to `width`×`height` on a white background (transparency becomes white).
    public init(cgImage image: CGImage, width: Int, height: Int) {
        let ctx = GrayImage.makeContext(width: width, height: height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.init(context: ctx)
    }

    /// Scales `image` to `targetWidth`, keeping aspect ratio.
    public init(cgImage image: CGImage, targetWidth: Int) {
        let h = max(1, Int((Double(image.height) * Double(targetWidth) / Double(image.width)).rounded()))
        self.init(cgImage: image, width: targetWidth, height: h)
    }

    public static func makeContext(width: Int, height: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// brightness: -1…1 (0 = unchanged), contrast: -1…1 (0 = unchanged), gamma: >0 (1 = unchanged, <1 darker midtones).
    public func adjusted(brightness: Float = 0, contrast: Float = 0, gamma: Float = 1) -> GrayImage {
        if brightness == 0 && contrast == 0 && gamma == 1 { return self }
        var out = self
        let c = max(-0.99, min(0.99, contrast))
        let k = (1 + c) / (1 - c)      // contrast slope around mid-gray
        let invGamma = 1 / max(0.05, gamma)
        for i in 0..<out.data.count {
            var v = out.data[i]
            v = pow(max(0, min(1, v)), invGamma)
            v = (v - 0.5) * k + 0.5 + brightness
            out.data[i] = max(0, min(1, v))
        }
        return out
    }

    /// Simple 3×3 unsharp mask; thermal dots smear a bit, a little sharpening helps photos.
    public func sharpened(amount: Float) -> GrayImage {
        guard amount > 0, width > 2, height > 2 else { return self }
        var out = self
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let blur = (data[i - 1] + data[i + 1] + data[i - width] + data[i + width] + data[i] * 4) / 8
                out.data[i] = max(0, min(1, data[i] + (data[i] - blur) * amount))
            }
        }
        return out
    }

    /// Share of pixels that are clearly neither black nor white. Used to guess "photo" vs "text" pages.
    public var midtoneRatio: Double {
        guard !data.isEmpty else { return 0 }
        var n = 0
        for v in data where v > 0.15 && v < 0.85 { n += 1 }
        return Double(n) / Double(data.count)
    }

    public func threshold(_ t: Float = 0.5) -> MonoBitmap {
        MonoBitmap(width: width, height: height, pixels: data.map { $0 < t ? 1 : 0 })
    }

    public func dithered(_ method: DitherMethod, threshold t: Float = 0.5) -> MonoBitmap {
        switch method {
        case .threshold: return threshold(t)
        case .floydSteinberg: return floydSteinberg()
        case .atkinson: return atkinson()
        case .ordered: return ordered()
        }
    }

    private func floydSteinberg() -> MonoBitmap {
        var buf = data
        var out = [UInt8](repeating: 0, count: data.count)
        let w = width
        for y in 0..<height {
            let ltr = y % 2 == 0          // serpentine scan avoids directional artifacts
            let dx = ltr ? 1 : -1
            for i in 0..<w {
                let x = ltr ? i : w - 1 - i
                let idx = y * w + x
                let old = buf[idx]
                let new: Float = old < 0.5 ? 0 : 1
                if new == 0 { out[idx] = 1 }
                let err = old - new
                let xn = x + dx, xp = x - dx
                if xn >= 0 && xn < w { buf[idx + dx] += err * 7 / 16 }
                if y + 1 < height {
                    if xp >= 0 && xp < w { buf[idx + w - dx] += err * 3 / 16 }
                    buf[idx + w] += err * 5 / 16
                    if xn >= 0 && xn < w { buf[idx + w + dx] += err * 1 / 16 }
                }
            }
        }
        return MonoBitmap(width: width, height: height, pixels: out)
    }

    private func atkinson() -> MonoBitmap {
        var buf = data
        var out = [UInt8](repeating: 0, count: data.count)
        let w = width, h = height
        @inline(__always) func add(_ x: Int, _ y: Int, _ e: Float) {
            if x >= 0 && x < w && y < h { buf[y * w + x] += e }
        }
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let old = buf[idx]
                let new: Float = old < 0.5 ? 0 : 1
                if new == 0 { out[idx] = 1 }
                let e = (old - new) / 8   // only 6/8 of the error is spread: punchier contrast, good for thermal
                add(x + 1, y, e); add(x + 2, y, e)
                add(x - 1, y + 1, e); add(x, y + 1, e); add(x + 1, y + 1, e)
                add(x, y + 2, e)
            }
        }
        return MonoBitmap(width: width, height: height, pixels: out)
    }

    private static let bayer8: [Float] = {
        let m: [Int] = [
            0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
            12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
            3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
            15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
        ]
        return m.map { (Float($0) + 0.5) / 64 }
    }()

    private func ordered() -> MonoBitmap {
        var out = [UInt8](repeating: 0, count: data.count)
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if data[idx] < GrayImage.bayer8[(y & 7) * 8 + (x & 7)] { out[idx] = 1 }
            }
        }
        return MonoBitmap(width: width, height: height, pixels: out)
    }
}
