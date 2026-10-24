import AppKit
import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// Apple Translation 프레임워크로 블록들을 한국어로 번역한다 (기기 내 오프라인, macOS 15.0+ 및 26.0+ 호환).
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
                let requests = blocks.map {
                    TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: String($0.id))
                }
                do {
                    try await translateBatch(
                        requests: requests,
                        source: source,
                        target: target,
                        into: model
                    )
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(Self.displayName(of: source)): \(error.localizedDescription)")
                    model.markMissingPack(forLanguage: code)
                }
            case .supported:
                missing.append(source)
                model.markMissingPack(forLanguage: code)
            case .unsupported:
                model.markMissingPack(forLanguage: code)
            @unknown default:
                model.markMissingPack(forLanguage: code)
            }
        }

        if Task.isCancelled { return }
        model.missingLanguages = missing
        model.finish(failures: failures)
    }

    private func translateBatch(
        requests: [TranslationSession.Request],
        source: Locale.Language,
        target: Locale.Language,
        into model: OverlayModel
    ) async throws {
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: source, target: target)
            for try await response in session.translate(batch: requests) {
                if Task.isCancelled { session.cancel(); return }
                guard let idString = response.clientIdentifier, let id = Int(idString) else { continue }
                model.apply(translation: response.targetText, toBlock: id)
            }
        } else {
            try await LegacySequoiaTranslationBridge.translateBatch(
                requests: requests,
                source: source,
                target: target,
                into: model
            )
        }
    }

    static func displayName(of language: Locale.Language) -> String {
        Locale(identifier: "ko").localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}

/// macOS 15.0 (Sequoia) 환경을 위한 SwiftUI `.translationTask` 브릿지
@MainActor
private enum LegacySequoiaTranslationBridge {
    private struct BridgeView: View {
        let configuration: TranslationSession.Configuration
        let action: @MainActor @Sendable (TranslationSession) async -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(configuration) { session in
                    await action(session)
                }
        }
    }

    static func translateBatch(
        requests: [TranslationSession.Request],
        source: Locale.Language,
        target: Locale.Language,
        into model: OverlayModel
    ) async throws {
        let config = TranslationSession.Configuration(source: source, target: target)
        let hostPanel = NSPanel(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostPanel.isOpaque = false
        hostPanel.backgroundColor = .clear
        hostPanel.alphaValue = 0
        hostPanel.ignoresMouseEvents = true
        hostPanel.isReleasedWhenClosed = false
        defer { hostPanel.close() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false
            let view = BridgeView(configuration: config) { session in
                guard !hasResumed else { return }
                do {
                    for try await response in session.translate(batch: requests) {
                        if Task.isCancelled {
                            hasResumed = true
                            continuation.resume()
                            return
                        }
                        guard let idString = response.clientIdentifier, let id = Int(idString) else { continue }
                        model.apply(translation: response.targetText, toBlock: id)
                    }
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume()
                    }
                } catch {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
            hostPanel.contentView = NSHostingView(rootView: view)
            hostPanel.orderBack(nil)
        }
    }
}
