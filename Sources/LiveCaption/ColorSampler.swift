import AppKit
import CoreGraphics

/// 원문 텍스트 영역의 배경색/글자색을 스크린샷에서 추출한다.
/// 번역문을 원래 UI 처럼 자연스럽게 덮어씌우기 위함.
enum ColorSampler {
    private struct RGB {
        var r: Double, g: Double, b: Double
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        func distance(to o: RGB) -> Double {
            let dr = r - o.r, dg = g - o.g, db = b - o.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    static func normalizedTextKey(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(trimmed.unicodeScalars.count)
        var lastWasSpace = false
        for s in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(s) {
                if !lastWasSpace {
                    scalars.append(" ")
                    lastWasSpace = true
                }
            } else {
                scalars.append(s)
                lastWasSpace = false
            }
        }
        return String(scalars).lowercased()
    }

    private static func stableBlockId(for key: String, occurrence: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(occurrence)
        let hash = hasher.finalize()
        return hash == Int.min ? 0 : abs(hash)
    }

    static func makeOverlayBlocks(_ blocks: [TextBlock], image: CGImage, scale: CGFloat) -> [OverlayBlock] {
        var occurrenceCounts: [String: Int] = [:]

        return blocks.compactMap { block in
            guard let language = block.language else { return nil }
            let key = normalizedTextKey(block.text)
            let count = occurrenceCounts[key, default: 0]
            occurrenceCounts[key] = count + 1
            let stableId = stableBlockId(for: key, occurrence: count)

            let pixelRect = CGRect(
                x: block.rect.minX * scale,
                y: block.rect.minY * scale,
                width: block.rect.width * scale,
                height: block.rect.height * scale
            )
            let (background, foreground) = colors(for: pixelRect, in: image)
            let baseSize: CGFloat
            if block.isVertical {
                let colWidth = block.lines.map(\.rect.width).reduce(0, +) / CGFloat(max(1, block.lines.count))
                baseSize = max(9, colWidth * 0.95)
            } else {
                let lineHeight = block.lines.map(\.rect.height).reduce(0, +) / CGFloat(max(1, block.lines.count))
                baseSize = max(9, lineHeight * 0.8)
            }
            return OverlayBlock(
                id: stableId,
                rect: block.rect,
                sourceText: block.text,
                sourceLanguage: language.rawValue,
                translated: nil,
                fontSize: baseSize,
                lineCount: block.lines.count,
                background: background,
                foreground: foreground,
                isVertical: block.isVertical
            )
        }
    }

    static func colors(for pixelRect: CGRect, in image: CGImage) -> (NSColor, NSColor) {
        let fallback = (NSColor.white, NSColor.black)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let expanded = pixelRect.insetBy(dx: -3, dy: -3).intersection(bounds).integral
        guard !expanded.isEmpty, expanded.width >= 2, expanded.height >= 2,
              let crop = image.cropping(to: expanded),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return fallback }

        let height = 24
        let width = max(8, min(256, Int(CGFloat(height) * expanded.width / expanded.height)))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return fallback }

        func pixel(_ x: Int, _ y: Int) -> RGB {
            let i = (y * width + x) * 4
            return RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255)
        }

        // 1) 테두리 픽셀의 최빈 색 = 배경색
        var border: [RGB] = []
        for x in 0..<width {
            border.append(pixel(x, 0))
            border.append(pixel(x, height - 1))
        }
        for y in 1..<(height - 1) {
            border.append(pixel(0, y))
            border.append(pixel(width - 1, y))
        }
        var buckets: [Int: [RGB]] = [:]
        for c in border {
            let key = (Int(c.r * 15) << 8) | (Int(c.g * 15) << 4) | Int(c.b * 15)
            buckets[key, default: []].append(c)
        }
        guard let dominant = buckets.values.max(by: { $0.count < $1.count }), !dominant.isEmpty else {
            return fallback
        }
        let background = RGB(
            r: dominant.map(\.r).reduce(0, +) / Double(dominant.count),
            g: dominant.map(\.g).reduce(0, +) / Double(dominant.count),
            b: dominant.map(\.b).reduce(0, +) / Double(dominant.count)
        )

        // 2) 배경과 가장 다른 내부 픽셀들 = 글자색
        var interior: [(RGB, Double)] = []
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let c = pixel(x, y)
                let d = c.distance(to: background)
                if d > 0.25 { interior.append((c, d)) }
            }
        }
        var foreground: RGB
        if interior.isEmpty {
            foreground = background.luminance > 0.55 ? RGB(r: 0.08, g: 0.08, b: 0.1) : RGB(r: 1, g: 1, b: 1)
        } else {
            interior.sort { $0.1 > $1.1 }
            let top = interior.prefix(max(1, interior.count / 6))
            foreground = RGB(
                r: top.map(\.0.r).reduce(0, +) / Double(top.count),
                g: top.map(\.0.g).reduce(0, +) / Double(top.count),
                b: top.map(\.0.b).reduce(0, +) / Double(top.count)
            )
        }

        // 3) 대비가 부족하면 흑/백으로 보정
        if abs(foreground.luminance - background.luminance) < 0.35 {
            foreground = background.luminance > 0.55 ? RGB(r: 0.08, g: 0.08, b: 0.1) : RGB(r: 1, g: 1, b: 1)
        }
        return (background.nsColor, foreground.nsColor)
    }
}
