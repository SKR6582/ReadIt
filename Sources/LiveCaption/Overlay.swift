import AppKit
import SwiftUI

struct OverlayBlock: Identifiable {
    let id: Int
    let rect: CGRect
    let sourceText: String
    let sourceLanguage: String
    var translated: String?
    var isMissingPack: Bool = false
    let fontSize: CGFloat
    let lineCount: Int
    let background: NSColor
    let foreground: NSColor
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recognizing
        case translating
        case done
        case failed(String)
    }

    let image: CGImage
    let canvasSize: CGSize
    var scale: CGFloat { CGFloat(image.width) / max(1, canvasSize.width) }

    @Published var phase: Phase = .recognizing
    @Published var blocks: [OverlayBlock] = []
    @Published var showOriginal = false
    @Published var missingLanguages: [Locale.Language] = []
    @Published var notice: String?

    private var noticeTask: Task<Void, Never>?

    init(image: CGImage, canvasSize: CGSize) {
        self.image = image
        self.canvasSize = canvasSize
    }

    var translatedCount: Int { blocks.filter { $0.translated != nil }.count }
    var missingPackCount: Int { blocks.filter { $0.isMissingPack }.count }

    func setBlocks(_ newBlocks: [OverlayBlock]) {
        blocks = newBlocks
        phase = newBlocks.isEmpty ? .done : .translating
        if newBlocks.isEmpty { flash("번역할 외국어 텍스트가 없어요") }
    }

    func apply(translation: String, toBlock id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            blocks[index].translated = translation
            blocks[index].isMissingPack = false
        }
    }

    func markMissingPack(forLanguage code: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            for index in blocks.indices {
                if blocks[index].sourceLanguage == code && blocks[index].translated == nil {
                    blocks[index].isMissingPack = true
                }
            }
        }
    }

    func finish(failures: [String]) {
        // 번역되지 못했고 언어 팩 미설치 하이라이트 대상도 아닌 블록만 제거
        // 언어 팩이 없어 번역하지 못한 블록(isMissingPack == true)은 붉은색 하이라이트로 화면에 유지
        withAnimation(.easeOut(duration: 0.2)) {
            blocks.removeAll { $0.translated == nil && !$0.isMissingPack }
        }
        if let first = failures.first, translatedCount == 0, missingPackCount == 0 {
            phase = .failed(first)
        } else {
            phase = .done
        }
    }

    func copyAll() {
        let text = blocks
            .filter { $0.translated != nil || $0.isMissingPack }
            .sorted { abs($0.rect.minY - $1.rect.minY) < 4 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
            .compactMap { $0.translated ?? $0.sourceText }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("텍스트를 클립보드에 복사했어요")
    }

    func flash(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { notice = message }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.notice = nil }
        }
    }
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    let model: OverlayModel
    var onClose: (() -> Void)?
    private var isClosing = false

    @MainActor
    init(screen: NSScreen, model: OverlayModel, onOpenLanguagePacks: @escaping ([Locale.Language]) -> Void) {
        self.model = model
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = OverlayView(
            model: model,
            onDismiss: { [weak self] in self?.dismiss() },
            onOpenLanguagePacks: onOpenLanguagePacks
        )
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = host
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.onClose?()
        })
    }

    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                MainActor.assumeIsolated { model.copyAll() }
                return true
            case "w":
                dismiss()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let optionDown = event.modifierFlags.contains(.option)
        MainActor.assumeIsolated {
            if model.showOriginal != optionDown {
                withAnimation(.easeOut(duration: 0.15)) { model.showOriginal = optionDown }
            }
        }
        super.flagsChanged(with: event)
    }
}
