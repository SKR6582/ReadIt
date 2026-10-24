import AppKit
import CoreGraphics
import Foundation
import NaturalLanguage
import SwiftUI

@MainActor
final class LiveTranslationManager {
    static let shared = LiveTranslationManager()

    private(set) var isRunning: Bool = false
    private var loopTask: Task<Void, Never>?
    private var overlayPanel: OverlayPanel?
    private var overlayModel: OverlayModel?
    private var currentScreen: NSScreen?

    /// 스크롤, 클릭, 보조키(Option) 감지 모니터
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var flagsMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// 활성 창 전환 감지 옵저버
    private var workspaceObserver: NSObjectProtocol?

    /// 조작 멈춤(안정화) 대기 타이머
    private var settleTask: Task<Void, Never>?
    /// 클릭/앱 전환 직후 탭 변경 점검 태스크
    private var tabCheckTask: Task<Void, Never>?
    /// 스크롤 중 최상단/최하단 경계 도달 감지 태스크
    private var boundaryCheckTask: Task<Void, Never>?

    /// 현재 사용자가 화면을 스크롤/조작 중인지 여부
    private var isInteracting: Bool = false
    /// 조작 종료 직후 즉시 스캔을 깨우기 위한 플래그
    private var needsImmediateScan: Bool = false
    /// 직전 조작이 스크롤 추적이었는지 여부
    private var wasTrackingScroll: Bool = false
    /// 스크롤 이벤트 세대 카운터 (캡처/OCR 도중 추가 스크롤 유입 감지용)
    private var scrollGeneration: UInt64 = 0
    /// 최상단(+1) 또는 최하단(-1) 스크롤 한계에 도달해 잠긴 스크롤 방향 (0 = 잠금 없음)
    private var clampedScrollDirection: Int = 0

    /// 시각적 스크롤 및 탭 추적기
    private let scrollTracker = ScrollTracker()
    /// 가로 4분할 스트립 변화 감지 추적기
    private let bandTracker = HorizontalBandTracker()
    /// 과속 스크롤 감지 모니터
    private let scrollVelocityMonitor = ScrollVelocityMonitor()
    /// 기준 프레임(anchorBlocks) 이후 누적된 스크롤 이동량 (화면 포인트 단위)
    private var cumulativeScrollDelta: CGPoint = .zero
    /// 마우스 커서 아래의 현재 창 및 탭 컨텍스트
    private var currentTabContext: WindowTabContext?
    private var lastWindowCheckTime: ContinuousClock.Instant = .now - .seconds(10)
    private var lastBoundaryCheckTime: ContinuousClock.Instant = .now - .seconds(10)

    /// 동일 문장 재번역 방지를 위한 메모리 캐시 (원문 및 정규화 키 -> 한국어 번역문)
    private var translationCache: [String: String] = [:]
    /// 이전 프레임의 텍스트 시그니처 (불필요한 OCR 및 UI 갱신 방지)
    private var lastSignature: String = ""

    var onStateChanged: ((Bool) -> Void)?

    func start() {
        guard !isRunning else { return }

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]

        let model = OverlayModel(image: nil, canvasSize: screen.frame.size, isLiveMode: true)
        let panel = OverlayPanel(screen: screen, model: model) { languages in
            LanguagePackWindowController.shared.show(highlighting: languages)
        }

        panel.onClose = { [weak self] in
            self?.stop()
        }

        self.currentScreen = screen
        self.overlayModel = model
        self.overlayPanel = panel
        self.isRunning = true
        self.lastSignature = ""
        self.isInteracting = false
        self.needsImmediateScan = true
        self.wasTrackingScroll = false
        self.scrollGeneration = 0
        self.clampedScrollDirection = 0
        self.cumulativeScrollDelta = .zero
        self.currentTabContext = ScrollTracker.windowTabContextUnderMouse(in: screen)
        self.scrollTracker.reset()
        self.bandTracker.reset()
        self.scrollVelocityMonitor.reset()

        // 1. 마우스 휠 / 트랙패드 스크롤 감지: 같은 탭 내에서는 블록이 스크롤을 따라 이동하도록 처리
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollEvent(event)
            }
        }

        // 2. 마우스 클릭 감지: 보고 있는 탭이 바뀌었는지 확인하여 같은 탭이면 유지, 다른 탭이면 기본 라이브 번역으로 복귀
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handlePointerOrAppActivity()
            }
        }

        // 3. Option(⌥) 키 감지: 라이브 모드에서도 원문 보기 토글 지원
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let optionDown = event.modifierFlags.contains(.option)
            Task { @MainActor in
                guard let self, self.isRunning, let model = self.overlayModel else { return }
                if model.showOriginal != optionDown {
                    withAnimation(.easeOut(duration: 0.12)) {
                        model.showOriginal = optionDown
                    }
                }
            }
        }

        // 4. 활성 앱 변경 시 탭/창 컨텍스트 비교 수행
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePointerOrAppActivity()
            }
        }

        // 5. 마우스 이동 감지: 노치 HUD 영역 위에서는 마우스 이벤트를 받아 호버 및 클릭 허용, 그 외 영역은 앱으로 통과
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateLiveMousePassThrough()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateLiveMousePassThrough()
            }
            return event
        }

        panel.present()
        onStateChanged?(true)

        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        settleTask?.cancel()
        settleTask = nil
        tabCheckTask?.cancel()
        tabCheckTask = nil
        boundaryCheckTask?.cancel()
        boundaryCheckTask = nil

        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        overlayPanel?.dismiss()
        overlayPanel = nil
        overlayModel = nil
        currentScreen = nil
        lastSignature = ""
        isInteracting = false
        needsImmediateScan = false
        wasTrackingScroll = false
        clampedScrollDirection = 0
        cumulativeScrollDelta = .zero
        currentTabContext = nil
        scrollTracker.reset()
        bandTracker.reset()
        scrollVelocityMonitor.reset()

        onStateChanged?(false)
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Scroll Tracking, Boundary Clamping & Tab Comparison Handling

    private func handleScrollEvent(_ event: NSEvent) {
        guard isRunning, let model = overlayModel else { return }

        scrollGeneration &+= 1
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14.0
        let viewportHeight = currentTabContext?.bounds.height ?? model.canvasSize.height

        if abs(dy) > 0.01 {
            if scrollVelocityMonitor.record(dy: dy, viewportHeight: viewportHeight) {
                model.triggerScrollSpeedWarning()
            }
        }

        guard !model.anchorBlocks.isEmpty else {
            scheduleSettleWait(milliseconds: 240)
            return
        }

        if abs(dy) > 0.01 {
            let scrollDir = dy > 0 ? 1 : -1

            if clampedScrollDirection != 0 {
                if scrollDir == clampedScrollDirection {
                    scheduleSettleWait(milliseconds: 180)
                    return
                } else {
                    clampedScrollDirection = 0
                }
            }

            let now = ContinuousClock.now
            if now - lastWindowCheckTime > .milliseconds(300), let screen = currentScreen {
                currentTabContext = ScrollTracker.windowTabContextUnderMouse(in: screen)
                lastWindowCheckTime = now

                if let refTab = scrollTracker.referenceTabContext,
                   let curTab = currentTabContext,
                   !curTab.isSameTab(as: refTab) {
                    fallbackToBaseLiveTranslation()
                    return
                }
            }

            cumulativeScrollDelta.x = 0
            cumulativeScrollDelta.y += dy

            isInteracting = true
            wasTrackingScroll = true
            if !model.isTrackingScroll {
                model.isTrackingScroll = true
            }

            let visibleRemaining = model.applyScrollOffset(
                cumulativeDelta: cumulativeScrollDelta,
                within: currentTabContext?.bounds
            )

            let totalScrolled = abs(cumulativeScrollDelta.y)
            if visibleRemaining == 0 && model.blocks.isEmpty && totalScrolled > model.canvasSize.height * 0.98 {
                model.triggerScrollSpeedWarning()
                fallbackToBaseLiveTranslation()
                return
            }

            scheduleBoundaryCheckIfNeeded(scrollDirection: scrollDir)
        }

        if event.momentumPhase == .ended {
            scheduleSettleWait(milliseconds: 180)
        } else if event.phase == .ended {
            scheduleSettleWait(milliseconds: 280)
        } else {
            scheduleSettleWait(milliseconds: 250)
        }
    }

    private func scheduleBoundaryCheckIfNeeded(scrollDirection: Int) {
        guard boundaryCheckTask == nil, scrollTracker.hasReference else { return }
        let now = ContinuousClock.now
        guard now - lastBoundaryCheckTime >= .milliseconds(70) else { return }
        lastBoundaryCheckTime = now

        boundaryCheckTask = Task { @MainActor [weak self] in
            defer { self?.boundaryCheckTask = nil }
            guard let self, self.isRunning, let model = self.overlayModel else { return }
            guard !model.anchorBlocks.isEmpty, self.scrollTracker.hasReference else { return }

            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, self.isRunning else { return }

            let dyAtCapture = self.cumulativeScrollDelta.y
            guard abs(dyAtCapture) >= 3.0 else { return }

            do {
                let capture = try await ScreenCapturer.captureScreenUnderMouse()
                guard !Task.isCancelled, self.isRunning else { return }

                let checkResult = self.scrollTracker.checkScrollBoundary(
                    newImage: capture.image,
                    currentTabContext: self.currentTabContext,
                    predictedCumulativeDy: dyAtCapture
                )

                switch checkResult.state {
                case .movingNormally:
                    break

                case .hitBoundary(let clampedCumulativeDy):
                    self.clampedScrollDirection = scrollDirection
                    self.cumulativeScrollDelta = CGPoint(x: 0, y: clampedCumulativeDy)
                    withAnimation(.easeOut(duration: 0.08)) {
                        _ = model.applyScrollOffset(
                            cumulativeDelta: self.cumulativeScrollDelta,
                            within: self.currentTabContext?.bounds
                        )
                    }

                case .targetLost:
                    self.fallbackToBaseLiveTranslation()
                }
            } catch {
                // 캡처 오류 무시
            }
        }
    }

    private func handlePointerOrAppActivity() {
        guard isRunning else { return }

        tabCheckTask?.cancel()
        tabCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self, self.isRunning, let screen = self.currentScreen else { return }

            let newTab = ScrollTracker.windowTabContextUnderMouse(in: screen)
            self.currentTabContext = newTab
            self.lastWindowCheckTime = .now

            if let refTab = self.scrollTracker.referenceTabContext,
               let newTab,
               !newTab.isSameTab(as: refTab) {
                self.fallbackToBaseLiveTranslation()
            } else {
                self.lastSignature = ""
                self.scheduleSettleWait(milliseconds: 180)
            }
        }
    }

    private func updateLiveMousePassThrough() {
        guard isRunning,
              let model = overlayModel,
              let panel = overlayPanel,
              let screen = currentScreen
        else { return }

        guard AppSettings.shared.hudStyle == .notch else {
            if !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
            return
        }

        let mouse = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: mouse.x - screen.frame.minX,
            y: screen.frame.maxY - mouse.y
        )
        let hitRect = OverlayModel.notchHUDHitRect(
            canvasSize: model.canvasSize,
            notchMetrics: model.notchMetrics,
            isExpanded: model.isNotchExpanded
        ).insetBy(dx: -6, dy: -6)

        let shouldCapture = hitRect.contains(localPoint)
        if panel.ignoresMouseEvents == shouldCapture {
            panel.ignoresMouseEvents = !shouldCapture
        }
    }

    private func fallbackToBaseLiveTranslation() {
        guard isRunning, let model = overlayModel else { return }

        boundaryCheckTask?.cancel()
        boundaryCheckTask = nil
        scrollTracker.reset()
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        wasTrackingScroll = false
        model.isTrackingScroll = false

        if !model.blocks.isEmpty || !model.anchorBlocks.isEmpty {
            withAnimation(.easeOut(duration: 0.12)) {
                model.setBlocks([])
            }
        }

        lastSignature = ""
        scheduleSettleWait(milliseconds: 240)
    }

    private func scheduleSettleWait(milliseconds: Int) {
        isInteracting = true
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, let self else { return }
            self.isInteracting = false
            self.overlayModel?.isTrackingScroll = false
            self.needsImmediateScan = true
        }
    }

    // MARK: - Helpers

    private func cropImage(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).intersection(bounds).integral
        guard pixelRect.width >= 8, pixelRect.height >= 8 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private func cachedTranslation(for sourceText: String) -> String? {
        if let exact = translationCache[sourceText] {
            return exact
        }
        let key = ColorSampler.normalizedTextKey(sourceText)
        return translationCache[key]
    }

    private func storeTranslation(_ translated: String, for sourceText: String) {
        if translationCache.count > 2000 {
            translationCache.removeAll(keepingCapacity: true)
        }
        translationCache[sourceText] = translated
        translationCache[ColorSampler.normalizedTextKey(sourceText)] = translated
    }

    private func waitNextCycle(milliseconds: Int) async {
        let step = 45
        var elapsed = 0
        while elapsed < milliseconds && !Task.isCancelled && isRunning {
            if needsImmediateScan && !isInteracting {
                needsImmediateScan = false
                return
            }
            try? await Task.sleep(for: .milliseconds(step))
            elapsed += step
        }
    }

    // MARK: - Main Live Translation Loop (가로 4분할 스트립 변화 감지 결합)

    private func runLoop() async {
        let coordinator = TranslationCoordinator()

        while !Task.isCancelled && isRunning {
            guard let model = overlayModel, overlayPanel != nil else { break }

            if isInteracting {
                try? await Task.sleep(for: .milliseconds(45))
                continue
            }
            needsImmediateScan = false

            do {
                let captureGeneration = scrollGeneration

                // 1. 화면 캡처 및 현재 보고 있는 탭 컨텍스트 조회
                let capture = try await ScreenCapturer.captureScreenUnderMouse()
                if Task.isCancelled || !isRunning { break }
                if isInteracting || scrollGeneration != captureGeneration { continue }

                currentScreen = capture.screen
                let scale = CGFloat(capture.image.width) / max(1, model.canvasSize.width)
                model.image = capture.image
                let latestTabContext = ScrollTracker.windowTabContextUnderMouse(in: capture.screen)
                currentTabContext = latestTabContext

                // 2. 가로 4분할 스트립 변화 감지 수행
                let screenRect = CGRect(origin: .zero, size: model.canvasSize)
                let bandDetection = bandTracker.detectChanges(
                    in: capture.image,
                    targetRect: screenRect,
                    threshold: 2.8,
                    overlapMargin: 28.0
                )

                let isVisuallyChanged: Bool
                if case .none = bandDetection {
                    isVisuallyChanged = false
                } else {
                    isVisuallyChanged = true
                    clampedScrollDirection = 0
                }

                // 3. 탭 전환 확인 및 스크롤/비전 상태 처리
                var forceFullScan = model.blocks.isEmpty || wasTrackingScroll
                if !model.blocks.isEmpty {
                    if let refTab = scrollTracker.referenceTabContext,
                       let curTab = latestTabContext,
                       !curTab.isSameTab(as: refTab) {
                        scrollTracker.reset()
                        cumulativeScrollDelta = .zero
                        clampedScrollDirection = 0
                        wasTrackingScroll = false
                        forceFullScan = true
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.setBlocks([])
                        }
                    } else if wasTrackingScroll {
                        if scrollTracker.hasReference {
                            let boundaryResult = scrollTracker.checkScrollBoundary(
                                newImage: capture.image,
                                currentTabContext: latestTabContext,
                                predictedCumulativeDy: cumulativeScrollDelta.y
                            )
                            switch boundaryResult.state {
                            case .movingNormally:
                                break
                            case .hitBoundary(let clampedDy):
                                cumulativeScrollDelta = CGPoint(x: 0, y: clampedDy)
                                withAnimation(.easeOut(duration: 0.08)) {
                                    _ = model.applyScrollOffset(
                                        cumulativeDelta: cumulativeScrollDelta,
                                        within: latestTabContext?.bounds
                                    )
                                }
                            case .targetLost:
                                scrollTracker.reset()
                                cumulativeScrollDelta = .zero
                                withAnimation(.easeOut(duration: 0.12)) {
                                    model.setBlocks([])
                                }
                            }
                        }
                        wasTrackingScroll = false
                        forceFullScan = true
                    } else if isVisuallyChanged {
                        if scrollTracker.hasReference {
                            let trackResult = scrollTracker.verifyAndTrack(
                                newImage: capture.image,
                                currentTabContext: latestTabContext,
                                predictedCumulativeDelta: .zero
                            )
                            switch trackResult.status {
                            case .unchanged:
                                break
                            case .tracked(let trackedBlocks, let actualDelta):
                                if abs(actualDelta.y) >= 4.0 {
                                    forceFullScan = true
                                    withAnimation(.easeOut(duration: 0.10)) {
                                        model.blocks = trackedBlocks
                                    }
                                }
                            case .targetLost:
                                scrollTracker.reset()
                                cumulativeScrollDelta = .zero
                                forceFullScan = true
                                withAnimation(.easeOut(duration: 0.12)) {
                                    model.setBlocks([])
                                }
                            }
                        } else {
                            forceFullScan = true
                        }
                    } else {
                        // 4개 가로 밴드 모두 변화가 없고 스크롤도 없었으면 OCR 완전 생략
                        await waitNextCycle(milliseconds: 500)
                        continue
                    }
                }

                let menuBarHeight = AppSettings.shared.includeMenuBar
                    ? 0
                    : max(24, capture.screen.frame.maxY - capture.screen.visibleFrame.maxY)

                // 4. 가로 4분할 부분 OCR vs 전체 OCR 분기 실행
                if !forceFullScan, case .partial(let dirtyRanges) = bandDetection {
                    var partialTextBlocks: [TextBlock] = []

                    for range in dirtyRanges {
                        guard let bandImage = cropImage(capture.image, to: range.expandedRect, scale: scale) else {
                            continue
                        }
                        let rawLines = try await TextRecognizer.recognize(
                            image: bandImage,
                            canvasSize: range.expandedRect.size
                        )
                        if Task.isCancelled || !isRunning { break }
                        if isInteracting || scrollGeneration != captureGeneration { break }

                        var offsetLines = rawLines.map { line in
                            RecognizedLine(
                                text: line.text,
                                rect: line.rect.offsetBy(dx: range.expandedRect.minX, dy: range.expandedRect.minY),
                                isVertical: line.isVertical
                            )
                        }
                        if menuBarHeight > 0 {
                            offsetLines = offsetLines.filter { $0.rect.midY >= menuBarHeight }
                        }

                        let rangeBlocks = BlockBuilder.build(from: offsetLines, verticalOnly: false).filter { block in
                            guard block.rect.midY >= range.coreRect.minY - 4,
                                  block.rect.midY <= range.coreRect.maxY + 4
                            else { return false }
                            guard let lang = block.language, lang != .korean else { return false }
                            guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                            return AppSettings.shared.isEnabled(code)
                        }
                        partialTextBlocks.append(contentsOf: rangeBlocks)
                    }

                    if Task.isCancelled || !isRunning { break }
                    if isInteracting || scrollGeneration != captureGeneration { continue }

                    let fullImage = capture.image
                    var partialOverlayBlocks = await Task.detached(priority: .userInitiated) {
                        ColorSampler.makeOverlayBlocks(partialTextBlocks, image: fullImage, scale: scale)
                    }.value
                    if Task.isCancelled || !isRunning { break }
                    if isInteracting || scrollGeneration != captureGeneration { continue }

                    for i in partialOverlayBlocks.indices {
                        if let cached = cachedTranslation(for: partialOverlayBlocks[i].sourceText) {
                            partialOverlayBlocks[i].translated = cached
                        }
                    }

                    withAnimation(.easeOut(duration: 0.12)) {
                        model.mergePartialBands(newBandBlocks: partialOverlayBlocks, dirtyRanges: dirtyRanges)
                    }
                    lastSignature = model.blocks.map { "\($0.sourceText)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                    cumulativeScrollDelta = .zero
                    scrollTracker.captureReference(
                        image: capture.image,
                        blocks: model.anchorBlocks,
                        canvasSize: model.canvasSize,
                        tabContext: latestTabContext
                    )
                } else {
                    // 전체 화면 OCR 스캔
                    var lines = try await TextRecognizer.recognize(image: capture.image, canvasSize: model.canvasSize)
                    if Task.isCancelled || !isRunning { break }
                    if isInteracting || scrollGeneration != captureGeneration { continue }

                    if menuBarHeight > 0 {
                        lines = lines.filter { $0.rect.midY >= menuBarHeight }
                    }

                    let blocks = BlockBuilder.build(from: lines, verticalOnly: false).filter { block in
                        guard let lang = block.language, lang != .korean else { return false }
                        guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                        return AppSettings.shared.isEnabled(code)
                    }

                    let currentSignature = blocks.map { "\($0.text)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                    if currentSignature == lastSignature && !blocks.isEmpty && !model.blocks.isEmpty {
                        if abs(cumulativeScrollDelta.y) > 0.5 {
                            cumulativeScrollDelta = .zero
                            withAnimation(.easeOut(duration: 0.08)) {
                                _ = model.applyScrollOffset(cumulativeDelta: .zero, within: latestTabContext?.bounds)
                            }
                        }
                        await waitNextCycle(milliseconds: 500)
                        continue
                    }
                    lastSignature = currentSignature

                    if blocks.isEmpty {
                        scrollTracker.reset()
                        cumulativeScrollDelta = .zero
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.setBlocks([])
                        }
                        await waitNextCycle(milliseconds: 500)
                        continue
                    }

                    let fullImage = capture.image
                    var overlayBlocks = await Task.detached(priority: .userInitiated) {
                        ColorSampler.makeOverlayBlocks(blocks, image: fullImage, scale: scale)
                    }.value
                    if Task.isCancelled || !isRunning { break }
                    if isInteracting || scrollGeneration != captureGeneration { continue }

                    for i in overlayBlocks.indices {
                        if let cached = cachedTranslation(for: overlayBlocks[i].sourceText) {
                            overlayBlocks[i].translated = cached
                        }
                    }

                    withAnimation(.easeOut(duration: 0.12)) {
                        model.mergeBlocks(overlayBlocks)
                    }
                    cumulativeScrollDelta = .zero
                    scrollTracker.captureReference(
                        image: capture.image,
                        blocks: model.anchorBlocks,
                        canvasSize: model.canvasSize,
                        tabContext: latestTabContext
                    )
                }

                // 5. 아직 번역되지 않은 신규 노출 블록이 있는 경우에만 기기 내 번역 실행
                let needsTranslation = model.blocks.contains { $0.translated == nil && !$0.isMissingPack }
                if needsTranslation && !isInteracting && scrollGeneration == captureGeneration {
                    await coordinator.translate(into: model)
                    if Task.isCancelled || !isRunning { break }

                    for block in model.anchorBlocks {
                        if let translated = block.translated {
                            storeTranslation(translated, for: block.sourceText)
                        }
                    }

                    if !isInteracting && scrollGeneration == captureGeneration {
                        scrollTracker.updateReferenceBlocks(model.anchorBlocks)
                    }
                }
            } catch {
                // 캡처 오류 시 다음 주기에 재시도
            }

            await waitNextCycle(milliseconds: 500)
        }
    }
}
