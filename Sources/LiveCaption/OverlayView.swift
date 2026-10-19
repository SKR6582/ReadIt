import AppKit
import SwiftUI

/// macOS 순정 Apple Intelligence 및 Live Text 스타일에 맞춘 세련된 디자인 토큰
private enum AppleTheme {
    static let accent = Color.accentColor
    static let systemGlass = Material.regularMaterial
    static let thinGlass = Material.ultraThinMaterial

    // 은은한 인디고-바이올렛 시머 그라데이션
    static let intelligenceGradient = LinearGradient(
        colors: [
            Color(red: 0.38, green: 0.44, blue: 0.98),
            Color(red: 0.62, green: 0.36, blue: 0.96),
            Color(red: 0.90, green: 0.42, blue: 0.75)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var onDismiss: () -> Void
    var onOpenLanguagePacks: ([Locale.Language]) -> Void

    @State private var hoverStack: [Int] = []
    @State private var blockZIndex: [Int: Double] = [:]
    @State private var topZIndex: Double = 1
    @State private var copiedBlockFeedbackId: Int?

    private var hoveredBlockId: Int? { hoverStack.last }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. 캡처된 배경 화면
            Image(decorative: model.image, scale: model.scale)
                .resizable()
                .interpolation(.high)
                .frame(width: model.canvasSize.width, height: model.canvasSize.height)

            // 2. macOS 순정 캡처 포커스 딤 레이어
            Color.black.opacity(0.14)
                .animation(.easeInOut(duration: 0.25), value: model.phase)

            // 3. 스캔 중일 때의 세련된 웨이브 애니메이션
            if model.phase == .recognizing {
                AppleScanWave(size: model.canvasSize)
            }

            // 4. 번역된 텍스트 블록들 (정상 번역은 원문색 덮기, 언어팩 없는 블록은 붉은색 하이라이트)
            if !model.showOriginal {
                ForEach(model.blocks) { block in
                    let isHovered = hoveredBlockId == block.id
                    let isCopied = copiedBlockFeedbackId == block.id
                    let baseZ = blockZIndex[block.id] ?? 0
                    let effectiveZ = isHovered ? (topZIndex + 1000) : (isCopied ? (topZIndex + 500) : baseZ)

                    NativeBlockView(
                        block: block,
                        isHovered: isHovered,
                        isCopied: isCopied,
                        onHover: { hovering in
                            updateHover(blockId: block.id, hovering: hovering)
                        },
                        onCopy: {
                            copySingleBlock(block)
                        },
                        onRequestLanguagePack: {
                            onOpenLanguagePacks([Locale.Language(identifier: block.sourceLanguage)])
                        }
                    )
                    .zIndex(effectiveZ)
                }
            }

            // 5. 상단 플로팅 컨트롤 바 (HUD)
            floatingControlBar
                .frame(width: model.canvasSize.width)
                .padding(.top, 40)
                .zIndex(1_000_000)
        }
        .frame(width: model.canvasSize.width, height: model.canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .ignoresSafeArea()
    }

    private func updateHover(blockId: Int, hovering: Bool) {
        if hovering {
            hoverStack.removeAll { $0 == blockId }
            hoverStack.append(blockId)
            topZIndex += 1
            blockZIndex[blockId] = topZIndex
        } else {
            hoverStack.removeAll { $0 == blockId }
            if let currentId = hoverStack.last {
                topZIndex += 1
                blockZIndex[currentId] = topZIndex
            }
        }
    }

    // MARK: - Floating Control Bar (macOS Native Capsule HUD)

    private var floatingControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // 브랜드 & 상태 영역
                HStack(spacing: 8) {
                    statusSymbol
                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(.primary)
                        Text(statusSubtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                // 동작 컨트롤 및 키보드 단축키 배지
                HStack(spacing: 8) {
                    // 원문 토글 버튼
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            model.showOriginal.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            AppleKeyCap(text: "⌥")
                            Text("원문")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.showOriginal ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("원문 보기 (Option 누르고 있기)")

                    // 전체 복사 버튼
                    Button {
                        model.copyAll()
                    } label: {
                        HStack(spacing: 5) {
                            AppleKeyCap(text: "⌘C")
                            Text("전체 복사")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help("번역 및 텍스트 전체 복사 (Command + C)")

                    // 닫기 버튼
                    Button(action: onDismiss) {
                        HStack(spacing: 4) {
                            AppleKeyCap(text: "⎋ esc")
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help("닫기 (Esc)")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(AppleTheme.systemGlass)
                    .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                    )
            )

            // 알림 토스트 (클립보드 복사 등)
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppleTheme.thinGlass)
                        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 언어 팩 미설치 안내 배너
            if !model.missingLanguages.isEmpty {
                missingLanguageBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.missingLanguages)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.showOriginal)
    }

    // MARK: - Status Helpers (간결하고 직관적인 문구)

    @ViewBuilder
    private var statusSymbol: some View {
        switch model.phase {
        case .recognizing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        case .translating:
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppleTheme.intelligenceGradient)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 22, height: 22)
        case .done:
            if model.missingPackCount > 0 && model.translatedCount == 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(width: 22, height: 22)
            } else if model.missingPackCount > 0 {
                Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 22, height: 22)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 22, height: 22)
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .recognizing:
            return "스캔 중…"
        case .translating:
            return "번역 중…"
        case .done:
            if model.blocks.isEmpty {
                return "번역할 텍스트 없음"
            } else if model.missingPackCount > 0 && model.translatedCount == 0 {
                return "언어 팩 필요 (붉은색)"
            } else if model.missingPackCount > 0 {
                return "번역 완료 (일부 언어 팩 미설치)"
            } else {
                return "번역 완료"
            }
        case .failed:
            return "번역 실패"
        }
    }

    private var statusSubtitle: String {
        switch model.phase {
        case .recognizing:
            return "화면 텍스트 스캔 중"
        case .translating:
            return "\(model.translatedCount) / \(model.blocks.count)"
        case .done:
            if model.missingPackCount > 0 {
                return "\(model.translatedCount)개 번역됨 · \(model.missingPackCount)개 미설치"
            } else {
                return "\(model.translatedCount)개 영역 번역됨"
            }
        case .failed(let message):
            return message
        }
    }

    private var missingLanguageBanner: some View {
        let names = model.missingLanguages.map(TranslationCoordinator.displayName(of:)).joined(separator: ", ")
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(names) → 한국어 언어 팩이 없어 붉은색으로 표시됩니다")
                    .font(.system(size: 12, weight: .semibold))
                Text("기기 내 오프라인 번역을 위해 언어 팩을 내려받으세요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                onOpenLanguagePacks(model.missingLanguages)
            } label: {
                Text("언어 팩 받기")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppleTheme.systemGlass)
                .shadow(color: Color.black.opacity(0.14), radius: 12, y: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 1.0)
                )
        )
    }

    private func copySingleBlock(_ block: OverlayBlock) {
        let text = block.translated ?? block.sourceText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation {
            copiedBlockFeedbackId = block.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation {
                if copiedBlockFeedbackId == block.id { copiedBlockFeedbackId = nil }
            }
        }
    }
}

// MARK: - Native Live Text Block View

private struct NativeBlockView: View {
    let block: OverlayBlock
    let isHovered: Bool
    let isCopied: Bool
    let onHover: (Bool) -> Void
    let onCopy: () -> Void
    let onRequestLanguagePack: () -> Void

    var body: some View {
        let pad = max(2.5, block.fontSize * 0.16)
        let width = block.rect.width + pad * 2
        let height = block.rect.height + pad * 2

        Group {
            if let translated = block.translated {
                // 1) 정상 번역 완료된 블록
                ZStack(alignment: .topTrailing) {
                    Group {
                        if block.isVertical {
                            VerticalTextView(
                                text: translated,
                                maxFontSize: block.fontSize,
                                color: Color(nsColor: block.foreground),
                                size: CGSize(width: block.rect.width, height: block.rect.height)
                            )
                            .padding(.horizontal, pad)
                            .padding(.vertical, pad)
                        } else {
                            Text(translated)
                                .font(.system(size: block.fontSize, weight: .medium, design: .default))
                                .foregroundStyle(Color(nsColor: block.foreground))
                                .lineLimit(block.lineCount == 1 ? 1 : nil)
                                .minimumScaleFactor(0.35)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, pad)
                        }
                    }
                    .frame(width: width, height: height, alignment: block.isVertical ? .topTrailing : .leading)
                    .background(
                            RoundedRectangle(cornerRadius: min(5, pad * 1.5), style: .continuous)
                                .fill(Color(nsColor: block.background))
                                .shadow(
                                    color: Color.black.opacity(isHovered ? 0.22 : 0.08),
                                    radius: isHovered ? 6 : 2,
                                    y: isHovered ? 3 : 1
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: min(5, pad * 1.5), style: .continuous)
                                .strokeBorder(
                                    isHovered ? Color.accentColor.opacity(0.8) : Color.clear,
                                    lineWidth: 1.2
                                )
                        )

                    // 호버 시 복사 액션 배지
                    if isHovered || isCopied {
                        HStack(spacing: 3) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .bold))
                            Text(isCopied ? "복사됨" : "복사")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(isCopied ? Color.green : Color.black.opacity(0.75)))
                        .offset(y: -16)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .onTapGesture(perform: onCopy)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onCopy)
                .help("원문: \(block.sourceText)")
                .onHover(perform: onHover)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if block.isMissingPack {
                // 2) 언어 팩이 없어서 번역하지 못한 블록 -> 붉은 색으로 하이라이트!
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: min(5, pad * 1.5), style: .continuous)
                        .fill(Color.red.opacity(0.18))
                        .frame(width: width, height: height)
                        .overlay(
                            RoundedRectangle(cornerRadius: min(5, pad * 1.5), style: .continuous)
                                .strokeBorder(Color.red.opacity(0.85), lineWidth: 1.5)
                        )
                        .shadow(color: Color.red.opacity(0.2), radius: 4, y: 1)

                    // 호버 시 언어 팩 필요 알림 배지 (클릭 시 언어 팩 다운로드 창 열기)
                    if isHovered {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("언어 팩 필요")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.red))
                        .offset(y: -18)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .onTapGesture(perform: onRequestLanguagePack)
                    }
                }
                .help("언어 팩 미설치 (\(block.sourceLanguage)): 클릭하여 언어 팩 다운로드")
                .onHover(perform: onHover)
                .onTapGesture(perform: onRequestLanguagePack)
                .transition(.opacity)
            } else {
                // 3) 번역 대기 중 스켈레톤 펄스
                PendingBlockBox(width: width, height: height)
                    .transition(.opacity)
            }
        }
        .position(x: block.rect.midX, y: block.rect.midY)
    }
}

// MARK: - Skeleton Pending Box

private struct PendingBlockBox: View {
    let width: CGFloat
    let height: CGFloat
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(shimmer ? 0.12 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(shimmer ? 0.5 : 0.15), lineWidth: 1.0)
            )
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Apple Intelligence Scanning Wave

private struct AppleScanWave: View {
    let size: CGSize
    @State private var position: CGFloat = -0.2

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.04)

            LinearGradient(
                colors: [
                    Color.clear,
                    Color(red: 0.38, green: 0.44, blue: 0.98).opacity(0.15),
                    Color(red: 0.62, green: 0.36, blue: 0.96).opacity(0.25),
                    Color(red: 0.90, green: 0.42, blue: 0.75).opacity(0.15),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: size.width, height: 220)
            .offset(y: position * (size.height + 220))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                position = 1.0
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Apple Keycap Component (macOS 순정 키보드 키 모양)

struct AppleKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 0.5, y: 0.8)
            )
    }
}
