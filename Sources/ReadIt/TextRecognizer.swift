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
