import Foundation
import NaturalLanguage
import Translation

/// Apple Translation 프레임워크로 블록들을 한국어로 번역한다 (기기 내 오프라인).
@MainActor
final class TranslationCoordinator {
    static let targetLanguage = Locale.Language(identifier: "ko")

    func translate(into model: OverlayModel) async {
        let target = Self.targetLanguage
        let pending = model.blocks.filter { $0.translated == nil }
        let groups = Dictionary(grouping: pending, by: \.sourceLanguage)
        let availability = LanguageAvailability()
        var missing: [Locale.Language] = []
        var failures: [String] = []

        // 블록이 많은 언어부터 처리
        for (code, blocks) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            if Task.isCancelled { return }
            let source = Locale.Language(identifier: code)
            let status = await availability.status(from: source, to: target)

            switch status {
            case .installed:
                let session = TranslationSession(installedSource: source, target: target)
                let requests = blocks.map {
                    TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: String($0.id))
                }
                do {
                    for try await response in session.translate(batch: requests) {
                        if Task.isCancelled { session.cancel(); return }
                        guard let idString = response.clientIdentifier, let id = Int(idString) else { continue }
                        model.apply(translation: response.targetText, toBlock: id)
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(Self.displayName(of: source)): \(error.localizedDescription)")
                    // 번역 요청 실패 시에도 붉은색 하이라이트 표시
                    model.markMissingPack(forLanguage: code)
                }
            case .supported:
                missing.append(source)
                // 언어 팩이 설치되어 있지 않은 언어 블록들을 붉은색으로 하이라이트
                model.markMissingPack(forLanguage: code)
            case .unsupported:
                // 미지원 언어도 붉은색으로 하이라이트
                model.markMissingPack(forLanguage: code)
            @unknown default:
                model.markMissingPack(forLanguage: code)
            }
        }

        if Task.isCancelled { return }
        model.missingLanguages = missing
        model.finish(failures: failures)
    }

    static func displayName(of language: Locale.Language) -> String {
        Locale(identifier: "ko").localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
