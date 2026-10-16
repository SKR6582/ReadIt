import CoreGraphics
import Foundation
import Vision

/// OCR 로 인식한 한 줄. `rect` 는 화면 포인트 좌표(좌상단 원점).
struct RecognizedLine {
    let text: String
    let rect: CGRect
}

enum TextRecognizer {
    private static let preferredLanguages = [
        "en-US", "ko-KR", "ja-JP", "zh-Hans", "zh-Hant",
        "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR",
        "ru-RU", "uk-UA", "vi-VT", "th-TH", "nl-NL",
        "pl-PL", "tr-TR", "id-ID", "ar-SA",
    ]

    /// Vision 으로 이미지 안의 텍스트 줄을 인식한다.
    /// - Parameter canvasSize: 결과 좌표를 맞출 화면 크기(포인트)
    static func recognize(image: CGImage, canvasSize: CGSize) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.minimumTextHeight = 0.006
                if let supported = try? request.supportedRecognitionLanguages() {
                    let langs = preferredLanguages.filter { supported.contains($0) }
                    if !langs.isEmpty { request.recognitionLanguages = langs }
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let width = canvasSize.width
                let height = canvasSize.height
                let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.3
                    else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let box = observation.boundingBox // 정규화, 좌하단 원점
                    let rect = CGRect(
                        x: box.minX * width,
                        y: (1 - box.maxY) * height,
                        width: box.width * width,
                        height: box.height * height
                    )
                    return RecognizedLine(text: text, rect: rect)
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
