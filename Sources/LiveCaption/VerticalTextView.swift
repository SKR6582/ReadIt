import AppKit
import SwiftUI

/// 세로쓰기 조판 엔진.
/// 글자를 위에서 아래로 쌓고 열은 오른쪽에서 왼쪽으로 진행한다.
/// 괄호/장음/대시는 90도 회전, 구두점(、。)은 칸의 오른쪽 위로 옮기고,
/// 짧은 영숫자(2자 이하)는 한 칸에 가로로(縦中横), 긴 영숫자는 회전해 배치한다.
struct VerticalLayout {
    struct Glyph {
        let text: String
        let center: CGPoint
        let rotated: Bool
        let scale: CGFloat
    }

    let fontSize: CGFloat
    let glyphs: [Glyph]
    let fits: Bool

    private enum Kind {
        case upright
        case rotated
        case punctuation
        case halfPunctuation
        case tateChuYoko
        case space
    }

    private struct Token {
        let text: String
        let kind: Kind
        /// 세로 진행 길이 (em 단위, fontSize 를 곱해 사용)
        let advance: CGFloat
        /// 열 맨 앞에 오면 안 되는 문자 (앞 열 끝에 매달기)
        let noLineStart: Bool
    }

    static let rotatedCharacters: Set<Character> = [
        "ー", "－", "—", "―", "–", "-", "~", "〜", "～", "…", "‥",
        "(", ")", "（", "）", "[", "]", "［", "］", "{", "}", "｛", "｝",
        "「", "」", "『", "』", "【", "】", "〈", "〉", "《", "》", "<", ">", "＜", "＞",
        ":", "：", ";", "；", "=", "＝", "→", "←", "↑", "↓", "\"", "“", "”", "'", "‘", "’",
    ]

    static let punctuationCharacters: Set<Character> = ["、", "。", "，", "．"]
    static let halfPunctuationCharacters: Set<Character> = [",", "."]

    static let noLineStartCharacters: Set<Character> = [
        "、", "。", "，", "．", ",", ".", "」", "』", "）", ")", "】", "〉", "》", "］", "]",
        "！", "？", "!", "?", "ー", "ゃ", "ゅ", "ょ", "っ", "ャ", "ュ", "ョ", "ッ", "”", "’",
    ]

    private static let letterSpacing: CGFloat = 0.04
    private static let columnSpacing: CGFloat = 1.32

    private static func font(_ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    private static func measureWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font(size)]).width
    }

    private static func isASCIIAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c.isNewline {
                // 연속 공백은 하나로
                if tokens.last?.kind != .space {
                    tokens.append(Token(text: " ", kind: .space, advance: 0.38, noLineStart: false))
                }
                i += 1
                continue
            }
            if isASCIIAlnum(c) {
                var j = i
                while j < chars.count, isASCIIAlnum(chars[j]) || (j > i && (chars[j] == "." || chars[j] == ",") && j + 1 < chars.count && chars[j + 1].isNumber) {
                    j += 1
                }
                let run = String(chars[i..<j])
                if run.count <= 2 {
                    tokens.append(Token(text: run, kind: .tateChuYoko, advance: 1.0, noLineStart: false))
                } else {
                    // 길이는 실제 폰트 폭으로 계산 (em 단위로 환산)
                    let em = measureWidth(run, size: 100) / 100
                    tokens.append(Token(text: run, kind: .rotated, advance: max(1.0, em + 0.1), noLineStart: false))
                }
                i = j
                continue
            }
            let noStart = noLineStartCharacters.contains(c)
            if punctuationCharacters.contains(c) {
                tokens.append(Token(text: String(c), kind: .punctuation, advance: 1.0, noLineStart: true))
            } else if halfPunctuationCharacters.contains(c) {
                tokens.append(Token(text: String(c), kind: .halfPunctuation, advance: 0.6, noLineStart: true))
            } else if rotatedCharacters.contains(c) {
                tokens.append(Token(text: String(c), kind: .rotated, advance: 1.0, noLineStart: noStart))
            } else {
                tokens.append(Token(text: String(c), kind: .upright, advance: 1.0, noLineStart: noStart))
            }
            i += 1
        }
        while tokens.last?.kind == .space { tokens.removeLast() }
        while tokens.first?.kind == .space { tokens.removeFirst() }
        return tokens
    }

    /// 주어진 글자 크기로 열을 흘려 넣는다. 반환값: 열마다의 (토큰, 시작 y)
    private static func flow(_ tokens: [Token], fontSize s: CGFloat, height: CGFloat) -> [[(Token, CGFloat)]] {
        var columns: [[(Token, CGFloat)]] = [[]]
        var y: CGFloat = 0
        let cellGap = s * letterSpacing

        for token in tokens {
            let adv = token.advance * s
            if token.kind == .space {
                // 열의 시작 공백은 버린다
                if columns[columns.count - 1].isEmpty { continue }
                if y + adv > height { columns.append([]); y = 0; continue }
                y += adv
                continue
            }
            let overflow = y + adv > height + 0.5
            let canHang = token.noLineStart && !columns[columns.count - 1].isEmpty && y + adv <= height + s * 1.05
            if overflow && !canHang && !columns[columns.count - 1].isEmpty {
                columns.append([])
                y = 0
            }
            columns[columns.count - 1].append((token, y))
            y += adv + cellGap
        }
        return columns.filter { !$0.isEmpty }
    }

    private static func requiredWidth(columns: Int, fontSize s: CGFloat) -> CGFloat {
        guard columns > 0 else { return 0 }
        return CGFloat(columns - 1) * s * columnSpacing + s
    }

    /// 영역에 맞는 가장 큰 글자 크기를 이분 탐색으로 찾아 배치한다.
    static func fit(text: String, in size: CGSize, maxFontSize: CGFloat, minFontSize: CGFloat = 7) -> VerticalLayout {
        let tokens = tokenize(text)
        guard !tokens.isEmpty, size.width > 1, size.height > 1 else {
            return VerticalLayout(fontSize: minFontSize, glyphs: [], fits: true)
        }

        let upper = max(minFontSize, min(maxFontSize, size.width))
        func fits(_ s: CGFloat) -> Bool {
            let cols = flow(tokens, fontSize: s, height: size.height)
            // 회전 영숫자 묶음이 열 높이를 넘으면 실패
            for col in cols {
                for (token, y) in col where y + token.advance * s > size.height + s * 1.05 {
                    return false
                }
            }
            return requiredWidth(columns: cols.count, fontSize: s) <= size.width + 0.5
        }

        var chosen = minFontSize
        var didFit = false
        if fits(upper) {
            chosen = upper
            didFit = true
        } else if fits(minFontSize) {
            var lo = minFontSize, hi = upper
            for _ in 0..<14 {
                let mid = (lo + hi) / 2
                if fits(mid) { lo = mid } else { hi = mid }
            }
            chosen = lo
            didFit = true
        }

        let s = chosen
        let columns = flow(tokens, fontSize: s, height: size.height)
        var glyphs: [Glyph] = []
        for (ci, column) in columns.enumerated() {
            // 첫 열은 오른쪽 끝에서 시작
            let cx = size.width - s / 2 - CGFloat(ci) * s * columnSpacing
            for (token, y) in column {
                let adv = token.advance * s
                let cy = y + adv / 2
                switch token.kind {
                case .space:
                    continue
                case .upright:
                    glyphs.append(Glyph(text: token.text, center: CGPoint(x: cx, y: cy), rotated: false, scale: 1))
                case .rotated:
                    glyphs.append(Glyph(text: token.text, center: CGPoint(x: cx, y: cy), rotated: true, scale: 1))
                case .punctuation:
                    // 전각 구두점은 em 박스의 왼쪽 아래에 그려지므로 칸의 오른쪽 위로 옮긴다
                    glyphs.append(Glyph(text: token.text, center: CGPoint(x: cx + s * 0.55, y: cy - s * 0.6), rotated: false, scale: 1))
                case .halfPunctuation:
                    // 반각 구두점은 폭이 좁고 기준선 근처에 그려지므로 보정량이 다르다
                    glyphs.append(Glyph(text: token.text, center: CGPoint(x: cx + s * 0.22, y: cy - s * 0.45), rotated: false, scale: 1))
                case .tateChuYoko:
                    let w = measureWidth(token.text, size: s)
                    let scale = w > s * 0.95 ? (s * 0.95) / w : 1
                    glyphs.append(Glyph(text: token.text, center: CGPoint(x: cx, y: cy), rotated: false, scale: scale))
                }
            }
        }
        return VerticalLayout(fontSize: s, glyphs: glyphs, fits: didFit)
    }
}

/// 세로쓰기 텍스트 뷰. 주어진 크기 안에 오른쪽 위부터 세로로 조판한다.
struct VerticalTextView: View {
    let text: String
    let maxFontSize: CGFloat
    let color: Color
    let size: CGSize

    var body: some View {
        let layout = VerticalLayout.fit(text: text, in: size, maxFontSize: maxFontSize)
        Canvas { context, _ in
            for glyph in layout.glyphs {
                let resolved = context.resolve(
                    Text(glyph.text)
                        .font(.system(size: layout.fontSize * glyph.scale, weight: .medium))
                        .foregroundColor(color)
                )
                var ctx = context
                ctx.translateBy(x: glyph.center.x, y: glyph.center.y)
                if glyph.rotated { ctx.rotate(by: .degrees(90)) }
                ctx.draw(resolved, at: .zero, anchor: .center)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
