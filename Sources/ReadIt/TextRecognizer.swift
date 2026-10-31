import CoreGraphics
import CoreText
import Foundation
import Vision

/// OCR 로 인식한 한 줄. `rect` 는 화면 포인트 좌표(좌상단 원점).
struct RecognizedLine {
    let text: String
    let rect: CGRect
    /// 세로쓰기 열(위에서 아래로 읽는 줄)인지 여부
    let isVertical: Bool
}

/// macOS 26 의 Swift Vision `RecognizeTextRequest` 로 화면 텍스트를 인식한다.
/// 이 API 는 가로쓰기와 일본어/중국어 세로쓰기를 한 번에 인식하므로 별도 OCR 엔진이 필요 없다.
/// (구형 `VNRecognizeTextRequest` revision 3 은 세로쓰기 영역을 검출하지 못한다.)
enum TextRecognizer {
    /// 인식 우선순위. Vision 이 지원하는 언어 중 이 순서로 고른다.
    private static let preferredLanguageCodes = [
        "en", "ko", "ja", "zh", "fr", "de", "es", "it", "pt",
        "ru", "uk", "vi", "th", "nl", "pl", "tr", "id", "ar",
    ]

    private static func makeRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeightFraction = 0.006
        let supported = request.supportedRecognitionLanguages
        let languages = preferredLanguageCodes.flatMap { code in
            supported.filter { $0.languageCode?.identifier == code }
        }
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        return request
    }

    /// 화면 이미지 안의 텍스트 줄을 인식한다.
    /// - Parameter canvasSize: 결과 좌표를 맞출 화면 크기(포인트)
    static func recognize(image: CGImage, canvasSize: CGSize) async throws -> [RecognizedLine] {
        let observations = try await makeRequest().perform(on: image)
        let width = canvasSize.width
        let height = canvasSize.height

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.3
            else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let box = observation.boundingBox.cgRect // 정규화, 좌하단 원점
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            return RecognizedLine(text: text, rect: rect, isVertical: isVerticalLine(text: text, rect: rect))
        }
    }

    /// 세로로 긴 상자이면서 한중일 문자가 절반 이상이면 세로쓰기 열로 본다.
    /// (회전된 영문 라벨 등은 세로 조판 대상이 아니므로 제외)
    static func isVerticalLine(text: String, rect: CGRect) -> Bool {
        guard text.count >= 2, rect.height > rect.width * 1.4 else { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cjk = letters.filter { isCJKScalar($0) }
        return Double(cjk.count) / Double(letters.count) >= 0.5
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, // 히라가나, 가타카나
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // 한자
             0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, // 한글
             0xFF66...0xFF9F: // 반각 가타카나
            return true
        default:
            return false
        }
    }

    /// 첫 인식 시 모델 로딩으로 수 초가 걸리므로 앱 시작 직후 작은 이미지로 미리 불러 둔다.
    static func warmUp() {
        Task.detached(priority: .utility) {
            guard let image = makeWarmUpImage() else { return }
            _ = try? await makeRequest().perform(on: image)
        }
    }

    private static func makeWarmUpImage() -> CGImage? {
        let width = 360, height = 80
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 28, nil)
        let attributed = NSAttributedString(string: "Live 字幕 テスト", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 12, y: 28)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }
}

struct ScreenTile: Sendable {
    let index: Int
    /// 타일의 고유 영역 (포인트 좌표, 좌상단 원점)
    let coreRect: CGRect
    /// 경계 문단 보호를 위해 여유 마진을 포함한 OCR 크롭 영역 (포인트 좌표, 좌상단 원점)
    let expandedRect: CGRect
    /// 앞쪽(위쪽 또는 왼쪽) 경계가 내부 분할선인지 여부
    let hasLeadingCut: Bool
    /// 뒤쪽(아래쪽 또는 오른쪽) 경계가 내부 분할선인지 여부
    let hasTrailingCut: Bool
}

struct InternalTileCut: Sendable {
    let position: CGFloat
    let leadingTileIndex: Int
    let trailingTileIndex: Int
}

struct TilePlan: Sendable {
    let axis: SmartTileSlicer.Axis
    let tiles: [ScreenTile]
    let internalCuts: [InternalTileCut]
}

enum SmartTileSlicer {
    enum Axis: Sendable {
        case horizontal // ⌥1: 가로 밴드 (위 -> 아래)
        case vertical   // ⌥2: 세로 슬라이스 (오른쪽 -> 왼쪽)
    }

    static func makePlan(
        image: CGImage,
        canvasSize: CGSize,
        axis: Axis,
        tileCount: Int = 4,
        topInset: CGFloat = 0,
        cursorPoint: CGPoint? = nil,
        overlapMargin: CGFloat = 36
    ) -> TilePlan {
        let validRect = CGRect(
            x: 0,
            y: topInset,
            width: canvasSize.width,
            height: max(1, canvasSize.height - topInset)
        )
        guard tileCount > 1, validRect.width > 160, validRect.height > 160 else {
            let single = ScreenTile(
                index: 0,
                coreRect: validRect,
                expandedRect: validRect,
                hasLeadingCut: false,
                hasTrailingCut: false
            )
            return TilePlan(axis: axis, tiles: [single], internalCuts: [])
        }

        let cuts = findGutterCuts(
            image: image,
            canvasSize: canvasSize,
            validRect: validRect,
            axis: axis,
            tileCount: tileCount
        )

        var rawTiles: [ScreenTile] = []
        rawTiles.reserveCapacity(cuts.count - 1)

        for i in 0..<(cuts.count - 1) {
            let start = cuts[i]
            let end = cuts[i + 1]
            guard end - start > 1 else { continue }

            let hasLeading = (i > 0)
            let hasTrailing = (i < cuts.count - 2)
            let tileIndex = rawTiles.count

            let coreRect: CGRect
            let expandedRect: CGRect

            switch axis {
            case .horizontal:
                coreRect = CGRect(x: validRect.minX, y: start, width: validRect.width, height: end - start)
                let expMinY = max(validRect.minY, start - (hasLeading ? overlapMargin : 0))
                let expMaxY = min(validRect.maxY, end + (hasTrailing ? overlapMargin : 0))
                expandedRect = CGRect(x: validRect.minX, y: expMinY, width: validRect.width, height: expMaxY - expMinY)

            case .vertical:
                coreRect = CGRect(x: start, y: validRect.minY, width: end - start, height: validRect.height)
                let expMinX = max(validRect.minX, start - (hasLeading ? overlapMargin : 0))
                let expMaxX = min(validRect.maxX, end + (hasTrailing ? overlapMargin : 0))
                expandedRect = CGRect(x: expMinX, y: validRect.minY, width: expMaxX - expMinX, height: validRect.height)
            }

            rawTiles.append(
                ScreenTile(
                    index: tileIndex,
                    coreRect: coreRect,
                    expandedRect: expandedRect,
                    hasLeadingCut: hasLeading,
                    hasTrailingCut: hasTrailing
                )
            )
        }

        var internalCuts: [InternalTileCut] = []
        if rawTiles.count > 1 {
            for i in 0..<(rawTiles.count - 1) {
                let pos: CGFloat
                switch axis {
                case .horizontal:
                    pos = rawTiles[i].coreRect.maxY
                case .vertical:
                    pos = rawTiles[i].coreRect.maxX
                }
                internalCuts.append(
                    InternalTileCut(
                        position: pos,
                        leadingTileIndex: rawTiles[i].index,
                        trailingTileIndex: rawTiles[i + 1].index
                    )
                )
            }
        }

        let readingOrdered: [ScreenTile]
        switch axis {
        case .horizontal:
            readingOrdered = rawTiles.sorted { $0.coreRect.minY < $1.coreRect.minY }
        case .vertical:
            readingOrdered = rawTiles.sorted { $0.coreRect.maxX > $1.coreRect.maxX }
        }

        guard let cursor = cursorPoint else {
            return TilePlan(axis: axis, tiles: readingOrdered, internalCuts: internalCuts)
        }

        let orderedTiles = readingOrdered.enumerated().sorted { lhs, rhs in
            let lContains = lhs.element.coreRect.contains(cursor)
            let rContains = rhs.element.coreRect.contains(cursor)
            if lContains != rContains { return lContains }

            let lDist: CGFloat
            let rDist: CGFloat
            switch axis {
            case .horizontal:
                lDist = abs(lhs.element.coreRect.midY - cursor.y)
                rDist = abs(rhs.element.coreRect.midY - cursor.y)
            case .vertical:
                lDist = abs(lhs.element.coreRect.midX - cursor.x)
                rDist = abs(rhs.element.coreRect.midX - cursor.x)
            }
            if abs(lDist - rDist) > 1 {
                return lDist < rDist
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return TilePlan(axis: axis, tiles: orderedTiles, internalCuts: internalCuts)
    }

    /// 두 인식 줄이 화면상 동일한 물리적 텍스트 줄(또는 한쪽이 잘린 부분 줄)인지 판별한다.
    static func isSamePhysicalLine(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        guard a.isVertical == b.isVertical else { return false }
        let inter = a.rect.intersection(b.rect)
        guard !inter.isNull else { return false }
        let minW = max(1, min(a.rect.width, b.rect.width))
        let minH = max(1, min(a.rect.height, b.rect.height))
        let wRatio = inter.width / minW
        let hRatio = inter.height / minH
        if a.isVertical {
            return wRatio >= 0.45 && hRatio >= 0.35
        } else {
            return hRatio >= 0.45 && wRatio >= 0.35
        }
    }

    /// 새로 인식된 줄들을 기존 대기 줄 배열에 병합한다.
    /// 이미 출력 완료된 줄(`emittedLines`)과 겹치면 건너뛰고, 대기 중인 줄과 겹치면 더 긴(온전한) 줄을 유지한다.
    static func mergeRecognizedLines(
        into pendingLines: inout [RecognizedLine],
        newLines: [RecognizedLine],
        emittedLines: [RecognizedLine]
    ) {
        for candidate in newLines {
            let alreadyEmitted = emittedLines.contains { isSamePhysicalLine($0, candidate) }
            if alreadyEmitted { continue }

            var matchedIndices: [Int] = []
            for (idx, existing) in pendingLines.enumerated() {
                if isSamePhysicalLine(existing, candidate) {
                    matchedIndices.append(idx)
                }
            }

            if matchedIndices.isEmpty {
                pendingLines.append(candidate)
            } else {
                let maxExistingCount = matchedIndices.map { pendingLines[$0].text.count }.max() ?? 0
                if candidate.text.count > maxExistingCount {
                    for idx in matchedIndices.reversed() {
                        pendingLines.remove(at: idx)
                    }
                    pendingLines.append(candidate)
                }
            }
        }
    }

    /// 블록이 아직 양쪽 타일이 모두 스캔되지 않은 미봉합 분할선(`unsealedCuts`) 근처에 걸쳐 있는지 판별한다.
    static func touchesUnsealedCut(
        block: TextBlock,
        axis: Axis,
        unsealedCuts: [CGFloat]
    ) -> Bool {
        guard !unsealedCuts.isEmpty else { return false }
        switch axis {
        case .horizontal:
            let maxLineHeight = block.lines.map(\.rect.height).max() ?? 20
            let holdRadius = max(42, maxLineHeight * 1.8)
            for cut in unsealedCuts {
                if block.rect.maxY >= cut - holdRadius && block.rect.minY <= cut + holdRadius {
                    return true
                }
            }
            return false

        case .vertical:
            let maxLineWidth = block.lines.map(\.rect.width).max() ?? 20
            let holdRadius = max(42, maxLineWidth * 2.0)
            for cut in unsealedCuts {
                if block.rect.maxX >= cut - holdRadius && block.rect.minX <= cut + holdRadius {
                    return true
                }
            }
            return false
        }
    }

    private static func findGutterCuts(
        image: CGImage,
        canvasSize: CGSize,
        validRect: CGRect,
        axis: Axis,
        tileCount: Int
    ) -> [CGFloat] {
        let sampleW = 240
        let sampleH = 240
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return uniformCuts(validRect: validRect, axis: axis, tileCount: tileCount)
        }

        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let drawn = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: sampleW,
                height: sampleH,
                bitsPerComponent: 8,
                bytesPerRow: sampleW * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard drawn else {
            return uniformCuts(validRect: validRect, axis: axis, tileCount: tileCount)
        }

        func luma(_ x: Int, _ y: Int) -> Int {
            let idx = (y * sampleW + x) * 4
            return (Int(pixels[idx]) * 77 + Int(pixels[idx + 1]) * 150 + Int(pixels[idx + 2]) * 29) >> 8
        }

        switch axis {
        case .horizontal:
            var rowEnergy = [Int](repeating: 0, count: sampleH)
            for y in 0..<sampleH {
                var e = 0
                let yNext = min(sampleH - 1, y + 1)
                for x in 0..<(sampleW - 1) {
                    let c = luma(x, y)
                    let diff = abs(c - luma(x + 1, y)) + abs(c - luma(x, yNext))
                    if diff > 8 { e += diff }
                }
                rowEnergy[y] = e
            }

            // 문단 내부의 줄간격(4~10pt)을 여백으로 오인하지 않도록 세로 방향 Max-Pooling(팽창) 후 평활화
            let poolRadius = 3
            var dilated = [Int](repeating: 0, count: sampleH)
            for y in 0..<sampleH {
                let lo = max(0, y - poolRadius)
                let hi = min(sampleH - 1, y + poolRadius)
                var maxVal = 0
                for k in lo...hi where rowEnergy[k] > maxVal {
                    maxVal = rowEnergy[k]
                }
                dilated[y] = maxVal
            }

            var smoothed = dilated
            for y in 1..<(sampleH - 1) {
                smoothed[y] = (dilated[y - 1] + dilated[y] * 2 + dilated[y + 1]) / 4
            }

            var cuts: [CGFloat] = [validRect.minY]
            let searchRadius = max(6, sampleH / (tileCount * 2))
            for k in 1..<tileCount {
                let targetY = validRect.minY + validRect.height * CGFloat(k) / CGFloat(tileCount)
                let centerIdx = Int((targetY / max(1, canvasSize.height)) * CGFloat(sampleH))
                let lo = max(2, centerIdx - searchRadius)
                let hi = min(sampleH - 3, centerIdx + searchRadius)
                var bestIdx = centerIdx
                var bestScore = Int.max
                for idx in lo...hi {
                    let distPenalty = abs(idx - centerIdx) * 8
                    let score = smoothed[idx] + distPenalty
                    if score < bestScore {
                        bestScore = score
                        bestIdx = idx
                    }
                }
                let cutY = (CGFloat(bestIdx) / CGFloat(sampleH)) * canvasSize.height
                cuts.append(min(max(cutY, cuts.last! + 40), validRect.maxY - 40))
            }
            cuts.append(validRect.maxY)
            return cuts

        case .vertical:
            var colEnergy = [Int](repeating: 0, count: sampleW)
            for x in 0..<sampleW {
                var e = 0
                let xNext = min(sampleW - 1, x + 1)
                for y in 0..<(sampleH - 1) {
                    let c = luma(x, y)
                    let diff = abs(c - luma(x, y + 1)) + abs(c - luma(xNext, y))
                    if diff > 8 { e += diff }
                }
                colEnergy[x] = e
            }

            let poolRadius = 3
            var dilated = [Int](repeating: 0, count: sampleW)
            for x in 0..<sampleW {
                let lo = max(0, x - poolRadius)
                let hi = min(sampleW - 1, x + poolRadius)
                var maxVal = 0
                for k in lo...hi where colEnergy[k] > maxVal {
                    maxVal = colEnergy[k]
                }
                dilated[x] = maxVal
            }

            var smoothed = dilated
            for x in 1..<(sampleW - 1) {
                smoothed[x] = (dilated[x - 1] + dilated[x] * 2 + dilated[x + 1]) / 4
            }

            var cuts: [CGFloat] = [validRect.minX]
            let searchRadius = max(6, sampleW / (tileCount * 2))
            for k in 1..<tileCount {
                let targetX = validRect.minX + validRect.width * CGFloat(k) / CGFloat(tileCount)
                let centerIdx = Int((targetX / max(1, canvasSize.width)) * CGFloat(sampleW))
                let lo = max(2, centerIdx - searchRadius)
                let hi = min(sampleW - 3, centerIdx + searchRadius)
                var bestIdx = centerIdx
                var bestScore = Int.max
                for idx in lo...hi {
                    let distPenalty = abs(idx - centerIdx) * 8
                    let score = smoothed[idx] + distPenalty
                    if score < bestScore {
                        bestScore = score
                        bestIdx = idx
                    }
                }
                let cutX = (CGFloat(bestIdx) / CGFloat(sampleW)) * canvasSize.width
                cuts.append(min(max(cutX, cuts.last! + 40), validRect.maxX - 40))
            }
            cuts.append(validRect.maxX)
            return cuts
        }
    }

    private static func uniformCuts(validRect: CGRect, axis: Axis, tileCount: Int) -> [CGFloat] {
        switch axis {
        case .horizontal:
            return (0...tileCount).map { validRect.minY + validRect.height * CGFloat($0) / CGFloat(tileCount) }
        case .vertical:
            return (0...tileCount).map { validRect.minX + validRect.width * CGFloat($0) / CGFloat(tileCount) }
        }
    }

    static func cropImage(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).intersection(bounds).integral
        guard !pixelRect.isEmpty, pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
