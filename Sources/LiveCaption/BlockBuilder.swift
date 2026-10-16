import CoreGraphics
import Foundation
import NaturalLanguage

/// 여러 줄을 하나의 문단으로 묶은 단위. 문맥을 살려 번역 품질을 높이기 위함.
struct TextBlock {
    let id: Int
    let lines: [RecognizedLine]
    let rect: CGRect
    let text: String
    var language: NLLanguage?
}

enum BlockBuilder {
    /// Apple Translation 이 지원하는 언어 전체 목록
    static let supportedLanguages: [NLLanguage] = [
        .english, .korean, .japanese, .simplifiedChinese, .traditionalChinese,
        .french, .german, .spanish, .italian, .portuguese, .russian, .ukrainian,
        .vietnamese, .thai, .indonesian, .dutch, .polish, .turkish, .arabic, .hindi,
    ]

    private static let latinScriptLanguages: Set<NLLanguage> = [
        .english, .french, .german, .spanish, .italian, .portuguese,
        .vietnamese, .indonesian, .dutch, .polish, .turkish,
    ]

    // MARK: - Grouping

    @MainActor
    static func build(from lines: [RecognizedLine]) -> [TextBlock] {
        let sorted = lines.sorted {
            abs($0.rect.minY - $1.rect.minY) < 2 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }

        var groups: [[RecognizedLine]] = []
        for line in sorted {
            var mergedIndex: Int?
            // 최근 블록부터 거꾸로 확인 (다단 레이아웃 대응)
            for index in groups.indices.reversed() {
                guard let last = groups[index].last else { continue }
                // 너무 위쪽에 있는 블록은 더 볼 필요 없음
                if line.rect.minY - last.rect.maxY > last.rect.height * 2 { continue }
                let blockWidth = groups[index].map(\.rect.width).max() ?? last.rect.width
                if canMerge(last, line, blockWidth: blockWidth) {
                    mergedIndex = index
                    break
                }
            }
            if let mergedIndex {
                groups[mergedIndex].append(line)
            } else {
                groups.append([line])
            }
        }

        var blocks = groups.enumerated().map { index, lines in
            let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
            return TextBlock(id: index, lines: lines, rect: rect, text: join(lines), language: nil)
        }
        detectLanguages(&blocks)
        return blocks
    }

    private static func canMerge(_ a: RecognizedLine, _ b: RecognizedLine, blockWidth: CGFloat) -> Bool {
        let hMax = max(a.rect.height, b.rect.height)
        let hMin = max(1, min(a.rect.height, b.rect.height))
        guard hMax / hMin < 1.3 else { return false }

        let gap = b.rect.minY - a.rect.maxY
        guard gap > -0.3 * hMax, gap < 0.55 * hMax else { return false }

        // 왼쪽 정렬이 비슷해야 같은 문단
        guard abs(a.rect.minX - b.rect.minX) < 1.2 * hMax else { return false }

        // 이전 줄이 문단 폭을 거의 채웠을 때만 이어지는 문장으로 본다 (목록/메뉴 항목 분리)
        guard a.rect.width >= 0.6 * max(blockWidth, b.rect.width) else { return false }
        return true
    }

    private static func join(_ lines: [RecognizedLine]) -> String {
        var result = ""
        for line in lines {
            let text = line.text
            guard let lastChar = result.last else {
                result = text
                continue
            }
            let firstChar = text.first ?? " "
            if lastChar == "-", firstChar.isLowercase {
                result.removeLast() // 하이픈 줄바꿈 복원
                result += text
            } else if isCJK(lastChar) && isCJK(firstChar) {
                result += text
            } else {
                result += " " + text
            }
        }
        return result
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }

    // MARK: - Language detection (사용자 설정 언어 제약 조건 적용)

    private enum Script: Hashable { case hangul, kana, han, latin, cyrillic, arabic, thai, devanagari }

    private static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let script: Script
            switch v {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: script = .hangul
            case 0x3040...0x30FF: script = .kana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: script = .han
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: script = .latin
            case 0x400...0x4FF: script = .cyrillic
            case 0x600...0x6FF: script = .arabic
            case 0xE00...0xE7F: script = .thai
            case 0x900...0x97F: script = .devanagari
            default: continue
            }
            counts[script, default: 0] += 1
        }
        if counts[.kana, default: 0] > 0 { return .kana }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    @MainActor
    private static func detectLanguages(_ blocks: inout [TextBlock]) {
        let activeLanguages = AppSettings.shared.activeNLLanguages
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = activeLanguages
        recognizer.processString(blocks.map(\.text).joined(separator: "\n"))
        let defaultLang: NLLanguage = activeLanguages.contains(.english) ? .english : activeLanguages.first ?? .english
        let screenLanguage = recognizer.dominantLanguage ?? defaultLang

        for index in blocks.indices {
            blocks[index].language = detect(
                blocks[index].text,
                screenLanguage: screenLanguage,
                activeLanguages: activeLanguages
            )
        }
    }

    private static func detect(
        _ text: String,
        screenLanguage: NLLanguage,
        activeLanguages: [NLLanguage]
    ) -> NLLanguage? {
        guard letterCount(text) >= 2 else { return nil }
        let script = dominantScript(text)
        if script == .hangul { return .korean }
        if script == .kana {
            return activeLanguages.contains(.japanese) ? .japanese : nil
        }
        if script == .thai {
            return activeLanguages.contains(.thai) ? .thai : nil
        }
        if script == .devanagari {
            return activeLanguages.contains(.hindi) ? .hindi : nil
        }
        if script == .arabic {
            return activeLanguages.contains(.arabic) ? .arabic : nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = activeLanguages
        recognizer.processString(text)
        if let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first {
            if probability >= 0.85 || (text.count >= 15 && probability >= 0.5) {
                if activeLanguages.contains(language) {
                    return language
                }
            }
        }

        switch script {
        case .han:
            let hanAllowed = activeLanguages.filter { [.simplifiedChinese, .traditionalChinese, .japanese].contains($0) }
            if hanAllowed.contains(screenLanguage) { return screenLanguage }
            return hanAllowed.first

        case .cyrillic:
            let cyrillicAllowed = activeLanguages.filter { [.russian, .ukrainian].contains($0) }
            if cyrillicAllowed.contains(screenLanguage) { return screenLanguage }
            return cyrillicAllowed.first

        case .latin:
            // 사용자가 활성화한 라틴 계열 언어로만 엄격하게 제한
            let activeLatin = latinScriptLanguages.intersection(activeLanguages)
            if activeLatin.contains(screenLanguage) {
                return screenLanguage
            }
            if activeLatin.contains(.english) {
                return .english
            }
            return activeLatin.first

        default:
            return recognizer.dominantLanguage
        }
    }
}
