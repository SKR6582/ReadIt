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
    @ObservedObject private var settings = AppSettings.shared
    var onDismiss: () -> Void
    var onOpenLanguagePacks: ([Locale.Language]) -> Void

    @State private var hoverStack: [Int] = []
    @State private var blockZIndex: [Int: Double] = [:]
    @State private var topZIndex: Double = 1
    @State private var copiedBlockFeedbackId: Int?
    @State private var pulseGlow = false

    private var hoveredBlockId: Int? { hoverStack.last }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.isRegionMode {
                regionModeContent
            } else {
                fullScreenModeContent
            }
        }
        .frame(width: model.canvasSize.width, height: model.canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.isLiveMode && !model.isRegionMode {
                onDismiss()
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Full Screen Mode Content (⌥1, ⌥2, ⌥3)

    @ViewBuilder
    private var fullScreenModeContent: some View {
        // 1. 캡처된 배경 화면 (일반 모드에서만 표시, 라이브 모드에서는 투명 처리하여 아래 창 노출)
        if !model.isLiveMode, let image = model.image {
            Image(decorative: image, scale: model.scale)
                .resizable()
                .interpolation(.high)
                .frame(width: model.canvasSize.width, height: model.canvasSize.height)
        }

        // 2. macOS 순정 캡처 포커스 딤 레이어 (일반 모드 전용)
        if !model.isLiveMode {
            Color.black.opacity(0.14)
                .animation(.easeInOut(duration: 0.25), value: model.phase)
        }

        // 3. 스캔 중일 때의 웨이브 애니메이션 (일반 모드 전용)
        if !model.isLiveMode && model.phase == .recognizing {
            AppleScanWave(size: model.canvasSize)
        }

        // 4. 화면 테두리 효과 (실시간 라이브 번역 작동 알림 - 단색 미니멀 라인)
        if model.isLiveMode {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(pulseGlow ? 0.35 : 0.15), lineWidth: 2.0)
                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 0)
                .padding(3)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                        pulseGlow = true
                    }
                }
        }

        // 5. 번역된 텍스트 블록들
        if !model.showOriginal {
            blocksLayer(allowInteraction: !model.isLiveMode)
        }

        // 6. 상단 컨트롤 UI (노치 통합 HUD vs 플로팅 캡슐 바)
        if settings.hudStyle == .notch {
            NotchHUDView(
                model: model,
                pulseGlow: pulseGlow,
                onDismiss: onDismiss,
                onOpenLanguagePacks: onOpenLanguagePacks
            )
            .frame(width: model.canvasSize.width, alignment: .top)
            .zIndex(1_000_000)
        } else if model.isLiveMode {
            liveIndicatorBadge
                .frame(width: model.canvasSize.width)
                .padding(.top, 24)
                .zIndex(1_000_000)
        } else {
            floatingControlBar
                .frame(width: model.canvasSize.width)
                .padding(.top, 40)
                .zIndex(1_000_000)
        }
    }

    // MARK: - Region Mode Content (⌥4 구역 지정 번역)

    @ViewBuilder
    private var regionModeContent: some View {
        if model.isSelectingRegion {
            RegionSelectionOverlay(
                canvasSize: model.canvasSize,
                isRegionLive: model.isRegionLive,
                useNotchHUD: settings.hudStyle == .notch,
                notchMetrics: model.notchMetrics,
                onToggleLive: { isLive in model.onToggleRegionLive?(isLive) },
                onComplete: { rect in model.onSelectRegion?(rect) },
                onCancel: onDismiss
            )
        } else if let region = model.regionRect {
            // 1. 일반 번역 모드일 때 지정된 구역의 정적 캡처 이미지 배경 표시
            if !model.isRegionLive, let crop = model.regionCropImage {
                Image(decorative: crop, scale: model.scale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: region.width, height: region.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .position(x: region.midX, y: region.midY)
                    .allowsHitTesting(false)
            }

            // 2. 일반 번역 스캔 중 웨이브 효과 (구역 내부 한정)
            if !model.isRegionLive && model.phase == .recognizing {
                AppleScanWave(size: region.size)
                    .frame(width: region.width, height: region.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .position(x: region.midX, y: region.midY)
            }

            // 3. 구역 내부 번역 블록 레이어 (구역 경계로 클리핑)
            if !model.showOriginal {
                blocksLayer(allowInteraction: !model.isRegionLive)
                    .mask(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .frame(width: region.width + 8, height: region.height + 8)
                            .position(x: region.midX, y: region.midY)
                    )
            }

            // 4. 지정 구역 테두리 프레임 (라이브 모드는 솔리드 펄스 테두리, 일반 모드는 깔끔한 가이드 테두리)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    model.isRegionLive
                        ? Color.white.opacity(pulseGlow ? 0.95 : 0.60)
                        : Color.white.opacity(0.65),
                    lineWidth: model.isRegionLive ? 2.0 : 1.5
                )
                .shadow(
                    color: model.isRegionLive
                        ? Color.white.opacity(pulseGlow ? 0.35 : 0.12)
                        : Color.black.opacity(0.25),
                    radius: model.isRegionLive ? 8 : 4
                )
                .frame(width: region.width + 4, height: region.height + 4)
                .position(x: region.midX, y: region.midY)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        pulseGlow = true
                    }
                }

            // 5. 구역 전용 컨트롤 UI (노치 통합 HUD vs 구역 인접 플로팅 바)
            if settings.hudStyle == .notch {
                NotchHUDView(
                    model: model,
                    pulseGlow: pulseGlow,
                    onDismiss: onDismiss,
                    onOpenLanguagePacks: onOpenLanguagePacks
                )
                .frame(width: model.canvasSize.width, alignment: .top)
                .zIndex(1_000_000)
            } else {
                let barRect = OverlayModel.regionControlBarRect(for: region, canvasSize: model.canvasSize)
                regionControlBar
                    .position(x: barRect.midX, y: barRect.midY)
                    .zIndex(1_000_000)
            }
        }
    }

    @ViewBuilder
    private func blocksLayer(allowInteraction: Bool) -> some View {
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
                    if allowInteraction {
                        updateHover(blockId: block.id, hovering: hovering)
                    }
                },
                onCopy: {
                    copySingleBlock(block)
                },
                onRequestLanguagePack: {
                    onOpenLanguagePacks([Locale.Language(identifier: block.sourceLanguage)])
                }
            )
            .allowsHitTesting(allowInteraction)
            .zIndex(effectiveZ)
        }
    }

    // MARK: - Region Floating Control Bar (일반 <-> 라이브 전환 바)

    private var regionControlBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 1. 일반 번역 <-> 라이브 번역 전환 세그먼트 토글
                HStack(spacing: 2) {
                    Button {
                        model.onToggleRegionLive?(false)
                    } label: {
                        Text("일반")
                            .font(.system(size: 11, weight: !model.isRegionLive ? .semibold : .medium))
                            .foregroundStyle(!model.isRegionLive ? .white : .primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(!model.isRegionLive ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("정적 일반 번역 모드로 전환")

                    Button {
                        model.onToggleRegionLive?(true)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.isRegionLive ? Color.black : Color.primary)
                                .frame(width: 6, height: 6)
                            Text("라이브")
                                .font(.system(size: 11, weight: model.isRegionLive ? .bold : .medium))
                                .foregroundStyle(model.isRegionLive ? Color.black : .primary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(model.isRegionLive ? Color.white : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("실시간 라이브 번역 모드로 전환")
                }
                .padding(2)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                )

                if model.isRegionLive {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(model.formattedSessionTime)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                // 2. 일반 모드일 때 수동 재스캔 버튼
                if !model.isRegionLive {
                    Button {
                        model.onRefreshRegion?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("스캔")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help("현재 구역 다시 번역")
                }

                Divider()
                    .frame(height: 14)

                // 3. 원문 보기 토글
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        model.showOriginal.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        AppleKeyCap(text: "⌥")
                        Text("원문")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(model.showOriginal ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help("원문 보기 (Option)")

                // 4. 복사 버튼
                Button {
                    model.copyAll()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("복사")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("구역 내 번역 전체 복사 (⌘C)")

                // 5. 구역 다시 지정 버튼
                Button {
                    model.onReselectRegion?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 10, weight: .semibold))
                        Text("구역")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("번역 구역 다시 드래그하여 지정")

                // 6. 닫기 버튼
                Button(action: onDismiss) {
                    HStack(spacing: 3) {
                        AppleKeyCap(text: "⌥4")
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("구역 번역 종료 (⌥4)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(AppleTheme.systemGlass)
                    .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 5)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                    )
            )

            if let warning = model.scrollSpeedWarning {
                scrollSpeedWarningBanner(warning)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppleTheme.thinGlass))
                    .transition(.opacity)
            }
        }
    }

    private func scrollSpeedWarningBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.yellow)
            Text(message)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(red: 0.16, green: 0.12, blue: 0.06).opacity(0.90))
                .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.orange.opacity(0.85), lineWidth: 1.0)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .allowsHitTesting(false)
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

    // MARK: - Live Mode Indicator Badge (경량화된 상단 플로팅 배지)

    private var liveIndicatorBadge: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        model.scrollSpeedWarning != nil
                            ? Color.orange
                            : (model.isTrackingScroll ? Color.cyan : Color(red: 0.38, green: 0.44, blue: 0.98))
                    )
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                            .scaleEffect(pulseGlow ? 1.8 : 1.0)
                            .opacity(pulseGlow ? 0.0 : 0.8)
                    )

                Text(liveBadgeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if model.translatedCount > 0 && !model.showOriginal {
                    Text("\(model.translatedCount)개 번역됨")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 12)

                HStack(spacing: 4) {
                    AppleKeyCap(text: "⌥")
                    Text("원문")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.showOriginal ? Color.accentColor : .secondary)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 12)

                HStack(spacing: 4) {
                    AppleKeyCap(text: "⌥3")
                    Text("종료")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(AppleTheme.systemGlass)
                    .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 6)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                model.scrollSpeedWarning != nil
                                    ? Color.orange.opacity(0.65)
                                    : Color.primary.opacity(0.08),
                                lineWidth: model.scrollSpeedWarning != nil ? 1.1 : 0.8
                            )
                    )
            )

            if let warning = model.scrollSpeedWarning {
                scrollSpeedWarningBanner(warning)
            }
        }
        .allowsHitTesting(false)
    }

    private var liveBadgeTitle: String {
        if model.showOriginal {
            return "원문 표시 중"
        } else if model.scrollSpeedWarning != nil {
            return "과속 스크롤 감지됨"
        } else if model.isTrackingScroll {
            return "스크롤 추적 중"
        } else {
            return "실시간 라이브 번역 중"
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
                            AdaptiveTextView(
                                text: translated,
                                baseFontSize: block.fontSize,
                                foreground: Color(nsColor: block.foreground),
                                width: block.rect.width,
                                height: block.rect.height
                            )
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

// MARK: - Adaptive Text View (번역문 길이에 맞춰 폰트 크기 자동 축소)

private struct AdaptiveTextView: View {
    let text: String
    let baseFontSize: CGFloat
    let foreground: Color
    let width: CGFloat
    let height: CGFloat

    private var calculatedFontSize: CGFloat {
        let minFontSize: CGFloat = 6.0
        guard width > 2, height > 2 else { return minFontSize }

        let targetWidth = max(4, width)
        let targetHeight = max(4, height)

        func fits(at size: CGFloat) -> Bool {
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            let attrString = NSAttributedString(
                string: text,
                attributes: [.font: font]
            )
            let constraintSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            let bounding = attrString.boundingRect(
                with: constraintSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return bounding.height <= targetHeight + 1.0
        }

        if fits(at: baseFontSize) {
            return baseFontSize
        }

        var lo = minFontSize
        var hi = baseFontSize
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if fits(at: mid) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    var body: some View {
        let fontSize = calculatedFontSize
        Text(text)
            .font(.system(size: fontSize, weight: .medium, design: .default))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: width, maxHeight: height, alignment: .topLeading)
            .clipped()
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

// MARK: - Precision Notch Shape & Native Integrated HUD (전문가 조언 기반 macOS 순정 노치 일체형 UI)

private struct PrecisionNotchShape: Shape {
    var bottomCornerRadius: CGFloat = 16

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let br = min(bottomCornerRadius, rect.width * 0.45, rect.height * 0.45)
        var path = Path()
        // 상단 모서리는 직각(radius 0)으로 화면 최상단 베젤에 완전 밀착
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: max(0, rect.height - br)))
        path.addQuadCurve(
            to: CGPoint(x: max(0, rect.width - br), y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )
        path.addLine(to: CGPoint(x: br, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: max(0, rect.height - br)),
            control: CGPoint(x: 0, y: rect.height)
        )
        path.closeSubpath()
        return path
    }
}

private struct NotchKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    )
            )
    }
}

private struct NotchActionButton: View {
    var keyCap: String? = nil
    var icon: String? = nil
    let title: String
    var isActive: Bool = false
    var isCompact: Bool = false
    var helpText: String = ""
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCompact ? 3.5 : 4.5) {
                if let keyCap {
                    NotchKeyCap(text: keyCap)
                }
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: isCompact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.90))
                }
                Text(title)
                    .font(.system(size: isCompact ? 11 : 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(Color.white.opacity(isActive || isHovered ? 1.0 : 0.85))
            }
            .padding(.horizontal, isCompact ? 6.5 : 8.5)
            .padding(.vertical, isCompact ? 4 : 4.5)
            .background(
                RoundedRectangle(cornerRadius: isCompact ? 5.5 : 6.5, style: .continuous)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: isCompact ? 5.5 : 6.5, style: .continuous)
                            .strokeBorder(borderFill, lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: isCompact ? 5.5 : 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .help(helpText)
    }

    private var backgroundFill: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.55 : 0.42)
        } else if isHovered {
            return Color.white.opacity(0.14)
        } else {
            return Color.white.opacity(isCompact ? 0.04 : 0.07)
        }
    }

    private var borderFill: Color {
        if isActive {
            return Color.white.opacity(0.28)
        } else if isHovered {
            return Color.white.opacity(0.18)
        } else {
            return Color.white.opacity(0.06)
        }
    }
}

private struct NotchHUDView: View {
    @ObservedObject var model: OverlayModel
    let pulseGlow: Bool
    var onDismiss: () -> Void
    var onOpenLanguagePacks: ([Locale.Language]) -> Void

    @Namespace private var notchNamespace
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var hasHardwareNotch: Bool {
        model.notchMetrics.hasHardwareNotch
    }

    private var notchHeight: CGFloat {
        hasHardwareNotch ? max(30, model.notchMetrics.notchHeight) : 32
    }

    private var hardwareNotchWidth: CGFloat {
        hasHardwareNotch ? max(160, model.notchMetrics.hardwareNotchWidth) : 130
    }

    private var centerNotchClearanceWidth: CGFloat {
        hasHardwareNotch ? (hardwareNotchWidth + 14) : 36
    }

    private var collapsedWingWidth: CGFloat {
        model.scrollSpeedWarning != nil ? 98 : 56
    }

    private var collapsedWidth: CGFloat {
        centerNotchClearanceWidth + (collapsedWingWidth * 2)
    }

    private var bottomCornerRadius: CGFloat {
        model.isNotchExpanded ? 20 : 13
    }

    var body: some View {
        ZStack(alignment: .top) {
            if model.isNotchExpanded {
                expandedNotchBody
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
            } else {
                collapsedNotchBody
                    .transition(.opacity)
            }
        }
        .frame(minWidth: collapsedWidth, alignment: .top)
        .background(
            PrecisionNotchShape(bottomCornerRadius: bottomCornerRadius)
                .fill(Color.black)
                .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
                .overlay(
                    PrecisionNotchShape(bottomCornerRadius: bottomCornerRadius)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
        )
        .onHover { hovering in
            handleHoverChange(hovering)
        }
        .onAppear {
            model.isNotchExpanded = !model.isLiveMode
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.isNotchExpanded)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: model.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.translatedCount)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: model.showOriginal)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: model.isTrackingScroll)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.scrollSpeedWarning)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.notice)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: model.missingLanguages)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: model.isRegionLive)
        .allowsHitTesting(!model.isLiveMode || model.isNotchExpanded || isHovering)
    }

    // MARK: - 160ms 지연 호버 & 220ms 복귀 처리 (단일 연속 스프링)

    private func handleHoverChange(_ hovering: Bool) {
        hoverTask?.cancel()
        isHovering = hovering
        model.isHoveringNotch = hovering

        if hovering {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, self.isHovering else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    self.model.isNotchExpanded = true
                }
            }
        } else {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, !self.isHovering else { return }
                if self.model.scrollSpeedWarning != nil {
                    return
                }
                if !self.model.isLiveMode && (self.model.phase == .recognizing || self.model.phase == .translating) {
                    return
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    self.model.isNotchExpanded = false
                }
            }
        }
    }

    // MARK: - 접힌 상태 (Collapsed State: 좌우 대칭 고정 폭으로 물리 노치 침범 원천 차단)

    private var collapsedNotchBody: some View {
        HStack(spacing: 0) {
            // 왼쪽 날개: 오른쪽 날개와 정확히 동일한 collapsedWingWidth를 가져 중앙 노치 스페이서가 절대 밀리지 않음
            HStack(spacing: 5) {
                unifiedStatusIcon
                    .matchedGeometryEffect(id: "notchIcon", in: notchNamespace)

                if model.scrollSpeedWarning != nil {
                    Text("스크롤 빠름")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(width: collapsedWingWidth, height: notchHeight, alignment: .center)

            // 중앙 카메라 하우징 (물리 노치 폭 + 좌우 7pt씩 총 14pt 안전 여백 확보)
            Spacer()
                .frame(width: centerNotchClearanceWidth)

            // 오른쪽 날개: 왼쪽 날개와 정확히 동일한 collapsedWingWidth 유지
            HStack(spacing: 4) {
                if model.scrollSpeedWarning != nil {
                    Text("천천히 스크롤")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    collapsedWingCounter
                }
            }
            .frame(width: collapsedWingWidth, height: notchHeight, alignment: .center)
        }
        .frame(height: notchHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var collapsedWingCounter: some View {
        if model.isLiveMode || (model.isRegionMode && model.isRegionLive) {
            Text(model.formattedSessionTime)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.white)
        } else if model.translatedCount > 0 && !model.showOriginal {
            Text("\(model.translatedCount)")
                .font(.system(size: 11.5, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.white.opacity(0.85))
        } else if model.phase == .recognizing || model.phase == .translating {
            ProgressView()
                .controlSize(.mini)
                .colorScheme(.dark)
        }
    }

    // MARK: - 펼친 상태 (Expanded State: 메인 컨트롤 + 보조 피드백 영역 통합)

    private var expandedNotchBody: some View {
        VStack(spacing: 0) {
            // 카메라 하우징 아래로 자연스럽게 브릿지 연결
            Spacer()
                .frame(height: hasHardwareNotch ? max(30, notchHeight + 2) : 10)

            Group {
                if model.isRegionMode {
                    regionNotchControls
                } else if model.isLiveMode {
                    liveNotchControls
                } else {
                    standardNotchControls
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, hasAuxiliaryContent ? 8 : 14)

            if hasAuxiliaryContent {
                notchAuxiliarySection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
            }
        }
    }

    private var hasAuxiliaryContent: Bool {
        model.phase == .recognizing
            || model.phase == .translating
            || model.scrollSpeedWarning != nil
            || model.notice != nil
            || !model.missingLanguages.isEmpty
    }

    // MARK: - 하단 보조 피드백 영역 (진행바 · 스크롤 경고 · 복사 토스트 · 언어 팩 안내)

    @ViewBuilder
    private var notchAuxiliarySection: some View {
        VStack(spacing: 6) {
            if model.phase == .recognizing || model.phase == .translating {
                thinProgressBar
            }

            if let warning = model.scrollSpeedWarning {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.bottom.100percent")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text(warning)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.16))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.5)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }

            if let notice = model.notice {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                    Text(notice)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }

            if !model.missingLanguages.isEmpty {
                let names = model.missingLanguages
                    .map(TranslationCoordinator.displayName(of:))
                    .joined(separator: " · ")

                HStack(spacing: 8) {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)

                    Text("\(names) → 한국어 언어 팩이 없어 붉은색으로 표시됩니다")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Button {
                        onOpenLanguagePacks(model.missingLanguages)
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10.5))
                            Text("언어 팩 받기")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.orange.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("macOS 번역 언어 팩 다운로드 창 열기")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
    }

    // MARK: - 2px 초슬림 진행바

    @ViewBuilder
    private var thinProgressBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.14))
            Capsule()
                .fill(Color.white)
                .frame(width: 180 * progressFraction)
                .animation(.spring(response: 0.30, dampingFraction: 0.85), value: progressFraction)
        }
        .frame(width: 180, height: 2)
        .transition(.opacity)
    }

    private var progressFraction: CGFloat {
        if model.phase == .recognizing { return 0.35 }
        if model.phase == .translating {
            let total = max(1, model.blocks.count)
            let done = model.translatedCount
            return min(1.0, max(0.45, CGFloat(done) / CGFloat(total)))
        }
        return 1.0
    }

    // MARK: - 1) ⌥1 / ⌥2 일반·세로 번역 노치 컨트롤

    private var standardNotchControls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                unifiedStatusIcon
                    .matchedGeometryEffect(id: "notchIcon", in: notchNamespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 18)

            HStack(spacing: 7) {
                NotchActionButton(
                    keyCap: "⌥",
                    title: "원문",
                    isActive: model.showOriginal,
                    helpText: "Option 키를 누르고 있는 동안에도 원문이 표시됩니다"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        model.showOriginal.toggle()
                    }
                }

                NotchActionButton(
                    keyCap: "⌘C",
                    title: "전체 복사",
                    helpText: "인식된 모든 번역문을 클립보드에 복사합니다 (⌘C)"
                ) {
                    model.copyAll()
                }

                NotchActionButton(
                    keyCap: "⎋",
                    title: "닫기",
                    helpText: "오버레이 닫기 (Esc 또는 ⌥1)"
                ) {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - 2) ⌥3 실시간 라이브 번역 노치 컨트롤

    private var liveNotchControls: some View {
        HStack(spacing: 10) {
            unifiedStatusIcon
                .matchedGeometryEffect(id: "notchIcon", in: notchNamespace)

            // Pomodoro 세션 타이머 배지 (단색 미니멀, 경고 시에도 레이아웃 유지)
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(model.formattedSessionTime)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.12)))

            Text(liveNotchTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(model.isTrackingScroll ? Color.cyan : Color.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if model.translatedCount > 0 && !model.showOriginal {
                HStack(spacing: 2) {
                    Text("\(model.translatedCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("개 번역됨")
                        .font(.system(size: 11.5, weight: .regular))
                }
                .foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 16)

            NotchActionButton(
                keyCap: "⌥",
                title: "원문",
                isActive: model.showOriginal,
                isCompact: true,
                helpText: "번역문 대신 원문 보기 (⌥ 길게 누르기)"
            ) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                    model.showOriginal.toggle()
                }
            }

            NotchActionButton(
                keyCap: "⌥3",
                title: "종료",
                isCompact: true,
                helpText: "실시간 라이브 번역 종료 (⌥3 또는 Esc)"
            ) {
                onDismiss()
            }
        }
    }

    private var liveNotchTitle: String {
        if model.showOriginal {
            return "원문 표시 중"
        } else if model.isTrackingScroll {
            return "스크롤 추적 중"
        } else {
            return "실시간 라이브 번역 중"
        }
    }

    // MARK: - 3) ⌥4 구역 지정 번역 노치 컨트롤

    private var regionNotchControls: some View {
        HStack(spacing: 8) {
            unifiedStatusIcon
                .matchedGeometryEffect(id: "notchIcon", in: notchNamespace)

            // 일반 / 라이브 모드 세그먼트 피커
            HStack(spacing: 2) {
                Button {
                    model.onToggleRegionLive?(false)
                } label: {
                    Text("일반")
                        .font(.system(size: 11, weight: !model.isRegionLive ? .semibold : .medium))
                        .foregroundStyle(!model.isRegionLive ? Color.white : Color.white.opacity(0.65))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(!model.isRegionLive ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("수동 구역 스캔 모드")

                Button {
                    model.onToggleRegionLive?(true)
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.isRegionLive ? Color.black : Color.white.opacity(0.85))
                            .frame(width: 6, height: 6)
                        Text("라이브")
                            .font(.system(size: 11, weight: model.isRegionLive ? .bold : .medium))
                            .foregroundStyle(model.isRegionLive ? Color.black : Color.white.opacity(0.65))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(model.isRegionLive ? Color.white : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help("구역 내 화면 변화를 실시간으로 감지해 자동 번역")
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.12)))

            if model.isRegionLive {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text(model.formattedSessionTime)
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 6.5)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            // 구역 번역 진행 상태 및 카운트 표시 (기존 플로팅 regionControlBar 복원)
            Text(regionStatusText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(regionStatusColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 15)

            if !model.isRegionLive {
                NotchActionButton(
                    icon: "arrow.clockwise",
                    title: "스캔",
                    isCompact: true,
                    helpText: "지정한 구역 다시 스캔"
                ) {
                    model.onRefreshRegion?()
                }
            }

            NotchActionButton(
                keyCap: "⌥",
                title: "원문",
                isActive: model.showOriginal,
                isCompact: true,
                helpText: "번역문 대신 원문 보기 (⌥ 길게 누르기)"
            ) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                    model.showOriginal.toggle()
                }
            }

            NotchActionButton(
                icon: "doc.on.doc",
                title: "복사",
                isCompact: true,
                helpText: "구역 내 번역문 전체 복사 (⌘C)"
            ) {
                model.copyAll()
            }

            NotchActionButton(
                icon: "viewfinder",
                title: "구역",
                isCompact: true,
                helpText: "번역할 화면 구역 다시 드래그하여 지정"
            ) {
                model.onReselectRegion?()
            }

            NotchActionButton(
                keyCap: "⌥4",
                title: "종료",
                isCompact: true,
                helpText: "구역 번역 종료 (⌥4 또는 Esc)"
            ) {
                onDismiss()
            }
        }
    }

    private var regionStatusText: String {
        if model.showOriginal {
            return "원문 표시 중"
        }
        if model.isTrackingScroll {
            return "스크롤 추적 중"
        }
        switch model.phase {
        case .recognizing:
            return "스캔 중…"
        case .translating:
            return "\(model.translatedCount)/\(model.blocks.count) 번역 중"
        case .done:
            if model.blocks.isEmpty {
                return model.isRegionLive ? "변화 대기 중" : "텍스트 없음"
            } else if model.missingPackCount > 0 && model.translatedCount == 0 {
                return "언어 팩 필요"
            } else {
                return "\(model.translatedCount)개 번역됨"
            }
        case .failed:
            return "번역 실패"
        }
    }

    private var regionStatusColor: Color {
        if model.isTrackingScroll {
            return Color.cyan
        }
        if case .done = model.phase, model.missingPackCount > 0 && model.translatedCount == 0 {
            return Color.red
        }
        if case .failed = model.phase {
            return Color.orange
        }
        return Color.white.opacity(0.80)
    }

    // MARK: - 단일 통합 상태 아이콘 (고정 컨테이너 + 내부 심볼 스케일/페이드 전환)

    private var statusIconKey: String {
        if model.scrollSpeedWarning != nil { return "warning" }
        if model.isTrackingScroll { return "live-scroll" }
        if model.isLiveMode || (model.isRegionMode && model.isRegionLive) {
            return "live"
        }
        switch model.phase {
        case .recognizing: return "recognizing"
        case .translating: return "translating"
        case .done:
            if model.blocks.isEmpty { return "done-empty" }
            if model.missingPackCount > 0 && model.translatedCount == 0 { return "done-missing-all" }
            if model.missingPackCount > 0 { return "done-missing-partial" }
            return "done-ok"
        case .failed: return "failed"
        }
    }

    private var unifiedStatusIcon: some View {
        ZStack {
            statusIconContent
                .id(statusIconKey)
                .transition(.scale(scale: 0.75).combined(with: .opacity))
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private var statusIconContent: some View {
        if model.scrollSpeedWarning != nil {
            Image(systemName: "gauge.with.dots.needle.bottom.100percent")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.orange)
        } else if model.isTrackingScroll || model.isLiveMode || (model.isRegionMode && model.isRegionLive) {
            let dotColor = model.isTrackingScroll ? Color.cyan : Color.white
            Circle()
                .fill(dotColor)
                .frame(width: 6.5, height: 6.5)
                .overlay(
                    Circle()
                        .stroke(dotColor.opacity(0.75), lineWidth: 1.2)
                        .scaleEffect(pulseGlow ? 1.7 : 1.0)
                        .opacity(pulseGlow ? 0.0 : 0.75)
                )
        } else {
            switch model.phase {
            case .recognizing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            case .translating:
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                if model.blocks.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                } else if model.missingPackCount > 0 && model.translatedCount == 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.red)
                } else if model.missingPackCount > 0 {
                    Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }
        }
    }

    // MARK: - ⌥1 / ⌥2 번역 상태 타이틀 & 서브타이틀 (토스트에 덮어쓰이지 않고 번역 정보 유지)

    private var statusTitle: String {
        if model.showOriginal {
            return "원문 표시 중"
        }
        switch model.phase {
        case .recognizing: return "스캔 중…"
        case .translating: return "번역 중…"
        case .done:
            if model.blocks.isEmpty {
                return "번역할 텍스트 없음"
            } else if model.missingPackCount > 0 && model.translatedCount == 0 {
                return "언어 팩 필요"
            } else if model.missingPackCount > 0 {
                return "번역 완료 (일부 미설치)"
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
            if model.blocks.isEmpty {
                return "인식 가능한 외국어 텍스트가 없습니다"
            } else if model.missingPackCount > 0 {
                let names = model.missingLanguages.map(TranslationCoordinator.displayName(of:)).joined(separator: ", ")
                return "\(model.translatedCount)개 번역됨 · \(names) 언어 팩 필요"
            } else {
                return "\(model.translatedCount)개 영역 번역됨"
            }
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        if model.missingPackCount > 0 && model.translatedCount == 0 { return Color.red }
        return Color.white
    }
}

// MARK: - Region Selection Overlay (⌥4 구역 드래그 지정 화면)

private struct RegionSelectionOverlay: View {
    let canvasSize: CGSize
    let isRegionLive: Bool
    let useNotchHUD: Bool
    let notchMetrics: NotchMetrics
    var onToggleLive: (Bool) -> Void
    var onComplete: (CGRect) -> Void
    var onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. 반투명 어두운 배경 + 드래그 영역 투명 컷아웃
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.28)
                if let rect = selectionRect, rect.width > 2, rect.height > 2 {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        let start = dragStart ?? value.startLocation
                        let end = value.location
                        let rect = CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: abs(end.x - start.x),
                            height: abs(end.y - start.y)
                        )
                        dragStart = nil
                        dragCurrent = nil
                        if rect.width >= 24 && rect.height >= 24 {
                            onComplete(rect)
                        }
                    }
            )

            // 2. 드래그 중인 선택 사각형 테두리 및 크기 배지
            if let rect = selectionRect, rect.width > 4, rect.height > 4 {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1.8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.0)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                Text("\(Int(rect.width)) × \(Int(rect.height))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .position(
                        x: rect.midX,
                        y: rect.maxY + 18 <= canvasSize.height ? rect.maxY + 18 : max(18, rect.minY - 18)
                    )
                    .allowsHitTesting(false)
            }

            // 3. 상단 안내 및 초기 모드(일반/라이브) 선택 바 (노치 통합 HUD vs 플로팅 캡슐)
            if useNotchHUD {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: notchMetrics.hasHardwareNotch ? max(30, notchMetrics.notchHeight) : 6)

                    HStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.cyan)

                        Text("번역할 구역을 드래그하세요")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.white)

                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 1, height: 14)

                        HStack(spacing: 2) {
                            Button {
                                onToggleLive(false)
                            } label: {
                                Text("일반 번역")
                                    .font(.system(size: 11, weight: !isRegionLive ? .semibold : .medium))
                                    .foregroundStyle(!isRegionLive ? Color.white : Color.white.opacity(0.68))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(!isRegionLive ? Color.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                onToggleLive(true)
                            } label: {
                                Text("라이브 번역")
                                    .font(.system(size: 11, weight: isRegionLive ? .bold : .medium))
                                    .foregroundStyle(isRegionLive ? Color.black : Color.white.opacity(0.68))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(isRegionLive ? Color.white : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))

                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 1, height: 14)

                        Button(action: onCancel) {
                            HStack(spacing: 4) {
                                NotchKeyCap(text: "⎋ esc")
                                Text("취소")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.75))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    PrecisionNotchShape(bottomCornerRadius: 18)
                        .fill(Color.black)
                        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
                        .overlay(
                            PrecisionNotchShape(bottomCornerRadius: 18)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                        )
                )
                .frame(width: canvasSize.width, alignment: .top)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text("번역할 구역을 드래그하세요")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Divider()
                        .frame(height: 16)

                    HStack(spacing: 2) {
                        Button {
                            onToggleLive(false)
                        } label: {
                            Text("일반 번역")
                                .font(.system(size: 11, weight: !isRegionLive ? .semibold : .medium))
                                .foregroundStyle(!isRegionLive ? .white : .primary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(!isRegionLive ? Color.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            onToggleLive(true)
                        } label: {
                            Text("라이브 번역")
                                .font(.system(size: 11, weight: isRegionLive ? .bold : .medium))
                                .foregroundStyle(isRegionLive ? .white : .primary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(isRegionLive ? Color.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))

                    Divider()
                        .frame(height: 16)

                    Button(action: onCancel) {
                        HStack(spacing: 4) {
                            AppleKeyCap(text: "⎋ esc")
                            Text("취소")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(AppleTheme.systemGlass)
                        .shadow(color: Color.black.opacity(0.2), radius: 14, x: 0, y: 6)
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                        )
                )
                .frame(width: canvasSize.width)
                .padding(.top, 36)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .onAppear {
            NSCursor.crosshair.set()
        }
        .onDisappear {
            NSCursor.arrow.set()
        }
    }
}
