import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A 1-bit image ready for a thermal head. `pixels[y * width + x] == 1` means a black (burned) dot.
public struct MonoBitmap: Equatable {
    public private(set) var width: Int
    public private(set) var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        precondition(width > 0 && height >= 0, "bad bitmap size \(width)x\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
        precondition(self.pixels.count == width * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { pixels[y * width + x] != 0 }
        set { pixels[y * width + x] = newValue ? 1 : 0 }
    }

    public var bytesPerRow: Int { (width + 7) / 8 }

    /// Packs one row into bytes.
    /// - Parameter msbFirst: leftmost pixel goes to bit 7 (ESC/POS style). `false` puts it in bit 0 (cat printers).
    public func packedRow(_ y: Int, msbFirst: Bool = true) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytesPerRow)
        let base = y * width
        for x in 0..<width where pixels[base + x] != 0 {
            let bit = msbFirst ? 7 - (x & 7) : (x & 7)
            out[x >> 3] |= UInt8(1 << bit)
        }
        return out
    }

    public func packed(msbFirst: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytesPerRow * height)
        for y in 0..<height { out += packedRow(y, msbFirst: msbFirst) }
        return out
    }

    public func isRowBlank(_ y: Int) -> Bool {
        let base = y * width
        for x in 0..<width where pixels[base + x] != 0 { return false }
        return true
    }

    public var blackRatio: Double {
        guard !pixels.isEmpty else { return 0 }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// Removes blank rows at the top and bottom, keeping `margin` blank rows on each side.
    public func trimmedVertically(margin: Int = 0) -> MonoBitmap {
        var top = 0
        while top < height && isRowBlank(top) { top += 1 }
        if top == height { return MonoBitmap(width: width, height: 0) }
        var bottom = height - 1
        while bottom > top && isRowBlank(bottom) { bottom -= 1 }
        let from = max(0, top - margin)
        let to = min(height - 1, bottom + margin)
        return MonoBitmap(width: width, height: to - from + 1,
                          pixels: Array(pixels[(from * width)..<((to + 1) * width)]))
    }

    /// Removes blank rows at the bottom only (handy for receipts).
    public func trimmedBottom(margin: Int = 0) -> MonoBitmap {
        var bottom = height - 1
        while bottom >= 0 && isRowBlank(bottom) { bottom -= 1 }
        let to = min(height - 1, bottom + margin)
        guard to >= 0 else { return MonoBitmap(width: width, height: 0) }
        return MonoBitmap(width: width, height: to + 1, pixels: Array(pixels[0..<((to + 1) * width)]))
    }

    public func padded(top: Int = 0, bottom: Int = 0) -> MonoBitmap {
        MonoBitmap(width: width, height: height + top + bottom,
                   pixels: [UInt8](repeating: 0, count: top * width) + pixels + [UInt8](repeating: 0, count: bottom * width))
    }

    /// Centers the image in `targetWidth`, cropping or padding equally on both sides.
    public func fitted(toWidth targetWidth: Int) -> MonoBitmap {
        if targetWidth == width { return self }
        var out = MonoBitmap(width: targetWidth, height: height)
        let offset = (targetWidth - width) / 2   // negative = crop
        for y in 0..<height {
            for x in 0..<targetWidth {
                let sx = x - offset
                if sx >= 0 && sx < width { out.pixels[y * targetWidth + x] = pixels[y * width + sx] }
            }
        }
        return out
    }

    /// Rotates 90° clockwise: the old left edge becomes the top.
    public func rotatedClockwise() -> MonoBitmap {
        var out = MonoBitmap(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] != 0 {
                // (x, y) -> (height - 1 - y, x)
                out.pixels[x * height + (height - 1 - y)] = 1
            }
        }
        return out
    }

    public func inverted() -> MonoBitmap {
        MonoBitmap(width: width, height: height, pixels: pixels.map { $0 == 0 ? 1 : 0 })
    }

    /// Stacks bitmaps of equal width on top of each other.
    public static func vstack(_ parts: [MonoBitmap], spacing: Int = 0) -> MonoBitmap {
        guard let w = parts.first?.width else { return MonoBitmap(width: 1, height: 0) }
        var pixels: [UInt8] = []
        for (i, p) in parts.enumerated() {
            let p = p.width == w ? p : p.fitted(toWidth: w)
            if i > 0 && spacing > 0 { pixels += [UInt8](repeating: 0, count: spacing * w) }
            pixels += p.pixels
        }
        return MonoBitmap(width: w, height: pixels.count / w, pixels: pixels)
    }

    /// A dashed horizontal line, useful as a cut mark between labels on continuous tape.
    public static func cutLine(width: Int, dash: Int = 6, gap: Int = 6, thickness: Int = 1, padding: Int = 4) -> MonoBitmap {
        var bm = MonoBitmap(width: width, height: thickness + padding * 2)
        for y in padding..<(padding + thickness) {
            for x in 0..<width where x % (dash + gap) < dash { bm[x, y] = true }
        }
        return bm
    }

    // MARK: - Export

    /// 8-bit grayscale image, black dots rendered black on white.
    public func cgImage() -> CGImage? {
        guard height > 0 else { return nil }
        let bytes = pixels.map { $0 != 0 ? UInt8(0) : UInt8(255) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
