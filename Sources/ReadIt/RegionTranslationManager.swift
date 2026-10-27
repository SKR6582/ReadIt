import AppKit
import CoreGraphics
import Foundation
import NaturalLanguage
import SwiftUI

@MainActor
final class RegionTranslationManager {
    static let shared = RegionTranslationManager()

    private(set) var isRunning: Bool = false
    private var scanTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var boundaryCheckTask: Task<Void, Never>?
    private var overlayPanel: OverlayPanel?
    private var overlayModel: OverlayModel?
    private var currentScreen: NSScreen?

    /// 세션 동안 사용자가 마지막으로 선택한 구역 모드(일반 vs 라이브) 기억
    private var preferredLiveMode: Bool = false

    /// 이벤트 모니터
    private var scrollMonitor: Any?
    private var flagsMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// 라이브 모드 스크롤 및 조작 상태
    private var isInteracting: Bool = false
    private var needsImmediateScan: Bool = false
    private var wasTrackingScroll: Bool = false
    private var scrollGeneration: UInt64 = 0
    private var clampedScrollDirection: Int = 0
    private var cumulativeScrollDelta: CGPoint = .zero
    private let scrollTracker = ScrollTracker()
    private var lastBoundaryCheckTime: ContinuousClock.Instant = .now - .seconds(10)

    /// 구역 내부 가로 4분할 스트립 변화 감지 트래커 및 번역 캐시
    private let bandTracker = HorizontalBandTracker()
    private let scrollVelocityMonitor = ScrollVelocityMonitor()
    private var translationCache: [String: String] = [:]
    private var lastSignature: String = ""

    var onStateChanged: ((Bool) -> Void)?

    func start(preset: RegionPreset? = nil, forceSelection: Bool = false) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }

        if isRunning {
            if forceSelection {
                beginRegionSelection()
            } else if let preset {
                applyPreset(preset)
            }
            return
        }

        let targetPreset = forceSelection ? nil : (preset ?? AppSettings.shared.lastRegionPreset)
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screen: NSScreen
        if let targetPreset,
           targetPreset.displayID != 0,
           let matched = NSScreen.screens.first(where: { $0.readItDisplayID == targetPreset.displayID }) {
            screen = matched
        } else {
            screen = mouseScreen
        }

        let model = OverlayModel(
            image: nil,
            canvasSize: screen.frame.size,
            isLiveMode: false,
            isRegionMode: true
        )

        if let targetPreset {
            preferredLiveMode = targetPreset.isLive
            model.isRegionLive = targetPreset.isLive
            model.isRegionVerticalOnly = targetPreset.isVerticalOnly
            model.overrideLanguages = targetPreset.overrideLanguages
            model.activePresetName = targetPreset.name == "마지막 구역" ? nil : targetPreset.name
            model.regionRect = targetPreset.normalizedRect.toCanvasRect(in: screen.frame.size)
            model.isSelectingRegion = false
            if targetPreset.isLive {
                model.startSessionTimer()
            }
        } else {
            model.isSelectingRegion = true
            model.isRegionLive = preferredLiveMode
            model.isRegionVerticalOnly = false
        }

        let panel = OverlayPanel(screen: screen, model: model) { languages in
            LanguagePackWindowController.shared.show(highlighting: languages)
        }

        bindModelCallbacks(model)

        panel.onClose = { [weak self] in
            self?.stop()
        }

        self.currentScreen = screen
        self.overlayModel = model
        self.overlayPanel = panel
        self.isRunning = true
        self.lastSignature = ""
        self.bandTracker.reset()
        self.scrollVelocityMonitor.reset()
        self.isInteracting = false
        self.needsImmediateScan = true
        self.wasTrackingScroll = false
        self.scrollGeneration = 0
        self.clampedScrollDirection = 0
        self.cumulativeScrollDelta = .zero
        self.scrollTracker.reset()

        setupMonitors()

        panel.ignoresMouseEvents = false
        panel.present()
        onStateChanged?(true)

        if !model.isSelectingRegion, model.regionRect != nil {
            persistCurrentRegionState()
            updateMousePassThrough()
            startCurrentRegionMode()
        }
    }

    private func bindModelCallbacks(_ model: OverlayModel) {
        model.onSelectRegion = { [weak self] rect in
            self?.didSelectRegion(rect)
        }
        model.onUpdateRegionRect = { [weak self] rect in
            self?.didUpdateRegionRect(rect)
        }
        model.onToggleRegionLive = { [weak self] isLive in
            self?.setRegionLiveMode(isLive)
        }
        model.onToggleRegionVertical = { [weak self] isVertical in
            self?.setRegionVerticalOnly(isVertical)
        }
        model.onReselectRegion = { [weak self] in
            self?.beginRegionSelection()
        }
        model.onRefreshRegion = { [weak self] in
            self?.refreshSingleScan()
        }
        model.onApplyPreset = { [weak self] preset in
            self?.applyPreset(preset)
        }
        model.onSavePreset = { [weak self] name in
            self?.saveCurrentRegionAsPreset(name: name)
        }
        model.onDeletePreset = { [weak self] id in
            self?.deletePreset(id: id)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        scanTask?.cancel()
        scanTask = nil
        settleTask?.cancel()
        settleTask = nil
        boundaryCheckTask?.cancel()
        boundaryCheckTask = nil

        removeMonitors()
        NSCursor.arrow.set()

        overlayPanel?.dismiss()
        overlayPanel = nil
        overlayModel = nil
        currentScreen = nil
        lastSignature = ""
        bandTracker.reset()
        scrollVelocityMonitor.reset()
        isInteracting = false
        needsImmediateScan = false
        wasTrackingScroll = false
        clampedScrollDirection = 0
        cumulativeScrollDelta = .zero
        scrollTracker.reset()

        onStateChanged?(false)
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Region Selection & Mode Switching

    /// 구역 드래그 선택을 다시 시작한다.
    private func beginRegionSelection() {
        guard isRunning, let model = overlayModel, let panel = overlayPanel else { return }
        scanTask?.cancel()
        scanTask = nil
        settleTask?.cancel()
        settleTask = nil
        boundaryCheckTask?.cancel()
        boundaryCheckTask = nil
        scrollTracker.reset()
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        lastSignature = ""

        withAnimation(.easeOut(duration: 0.12)) {
            model.setBlocks([])
            model.regionCropImage = nil
            model.regionRect = nil
            model.isSelectingRegion = true
            model.isTrackingScroll = false
        }
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
    }

    /// 사용자가 드래그로 구역 선택을 완료했을 때 호출된다.
    private func didSelectRegion(_ rect: CGRect) {
        guard isRunning, let model = overlayModel else { return }
        NSCursor.arrow.set()

        let clampedRect = rect.intersection(CGRect(origin: .zero, size: model.canvasSize)).integral
        guard clampedRect.width >= 24, clampedRect.height >= 24 else { return }

        model.regionRect = clampedRect
        model.isSelectingRegion = false
        model.activePresetName = nil
        if model.isRegionLive {
            model.startSessionTimer()
        }
        lastSignature = ""
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        scrollTracker.reset()

        persistCurrentRegionState()
        updateMousePassThrough()
        startCurrentRegionMode()
    }

    /// 구역 테두리 드래그 이동 또는 모서리/변 핸들 리사이즈가 완료되었을 때 호출된다.
    private func didUpdateRegionRect(_ rect: CGRect) {
        guard isRunning, let model = overlayModel else { return }
        let clampedRect = rect.intersection(CGRect(origin: .zero, size: model.canvasSize)).integral
        guard clampedRect.width >= 40, clampedRect.height >= 36 else { return }

        model.regionRect = clampedRect
        model.isAdjustingRegion = false
        lastSignature = ""
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        scrollTracker.reset()

        persistCurrentRegionState()
        updateMousePassThrough()
        startCurrentRegionMode()
    }

    /// 선택된 구역에 대해 일반 번역(false)과 라이브 번역(true)을 즉시 전환한다.
    private func setRegionLiveMode(_ isLive: Bool) {
        guard isRunning, let model = overlayModel else { return }
        guard model.isRegionLive != isLive else { return }

        preferredLiveMode = isLive
        if isLive {
            model.startSessionTimer()
        } else {
            model.stopSessionTimer()
        }
        withAnimation(.easeOut(duration: 0.15)) {
            model.isRegionLive = isLive
            model.isTrackingScroll = false
            if isLive {
                model.regionCropImage = nil
            }
        }

        persistCurrentRegionState()
        guard !model.isSelectingRegion, model.regionRect != nil else { return }

        lastSignature = ""
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0

        updateMousePassThrough()
        startCurrentRegionMode()
    }

    /// 구역 번역 내 세로쓰기 전용(true) <-> 가로/일반(false) 모드를 즉시 전환한다.
    private func setRegionVerticalOnly(_ isVertical: Bool) {
        guard isRunning, let model = overlayModel else { return }
        guard model.isRegionVerticalOnly != isVertical else { return }

        withAnimation(.easeOut(duration: 0.15)) {
            model.isRegionVerticalOnly = isVertical
        }
        persistCurrentRegionState()
        guard !model.isSelectingRegion, model.regionRect != nil else { return }

        lastSignature = ""
        bandTracker.reset()
        startCurrentRegionMode()
    }

    /// 프리셋을 즉시 현재 구역에 적용한다.
    func applyPreset(_ preset: RegionPreset) {
        if !isRunning {
            start(preset: preset, forceSelection: false)
            return
        }
        guard let model = overlayModel else { return }

        // 다른 모니터의 프리셋인 경우 재시작하여 해당 디스플레이 패널로 전환
        if preset.displayID != 0,
           let currentScreen,
           currentScreen.readItDisplayID != preset.displayID,
           NSScreen.screens.contains(where: { $0.readItDisplayID == preset.displayID }) {
            stop()
            start(preset: preset, forceSelection: false)
            return
        }

        preferredLiveMode = preset.isLive
        let newRect = preset.normalizedRect.toCanvasRect(in: model.canvasSize)

        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            model.isSelectingRegion = false
            model.regionRect = newRect
            model.isRegionLive = preset.isLive
            model.isRegionVerticalOnly = preset.isVerticalOnly
            model.overrideLanguages = preset.overrideLanguages
            model.activePresetName = preset.name == "마지막 구역" ? nil : preset.name
            if preset.isLive {
                model.regionCropImage = nil
                model.startSessionTimer()
            } else {
                model.stopSessionTimer()
            }
        }

        persistCurrentRegionState(presetName: preset.name)
        lastSignature = ""
        bandTracker.reset()
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        scrollTracker.reset()

        updateMousePassThrough()
        startCurrentRegionMode()
    }

    private func saveCurrentRegionAsPreset(name: String) {
        guard let model = overlayModel, let region = model.regionRect else { return }
        let displayID = currentScreen?.readItDisplayID ?? 0
        let saved = AppSettings.shared.saveRegionPreset(
            name: name,
            rect: region,
            canvasSize: model.canvasSize,
            displayID: displayID,
            isLive: model.isRegionLive,
            isVerticalOnly: model.isRegionVerticalOnly,
            overrideLanguages: model.overrideLanguages
        )
        model.activePresetName = saved.name
        model.flash("'\(saved.name)' 프리셋을 저장했어요")
        onStateChanged?(isRunning)
    }

    private func deletePreset(id: UUID) {
        AppSettings.shared.deleteRegionPreset(id: id)
        onStateChanged?(isRunning)
    }

    private func persistCurrentRegionState(presetName: String? = nil) {
        guard let model = overlayModel, let region = model.regionRect else { return }
        let displayID = currentScreen?.readItDisplayID ?? 0
        AppSettings.shared.saveLastRegion(
            rect: region,
            canvasSize: model.canvasSize,
            displayID: displayID,
            isLive: model.isRegionLive,
            isVerticalOnly: model.isRegionVerticalOnly,
            overrideLanguages: model.overrideLanguages,
            presetName: presetName ?? model.activePresetName ?? "마지막 구역"
        )
    }

    /// 일반 번역 모드에서 현재 구역을 즉시 다시 스캔한다.
    private func refreshSingleScan() {
        guard isRunning, let model = overlayModel, !model.isSelectingRegion else { return }
        lastSignature = ""
        startCurrentRegionMode()
    }

    private func startCurrentRegionMode() {
        guard isRunning, let model = overlayModel, let region = model.regionRect else { return }
        scanTask?.cancel()
        settleTask?.cancel()
        boundaryCheckTask?.cancel()

        if model.isRegionLive {
            overlayPanel?.orderFrontRegardless()
            needsImmediateScan = true
            isInteracting = false
            scanTask = Task { [weak self] in
                await self?.runRegionLiveLoop(region: region)
            }
        } else {
            isInteracting = false
            model.isTrackingScroll = false
            scanTask = Task { [weak self] in
                await self?.runSingleRegionScan(region: region)
            }
        }
    }

    // MARK: - Event Monitors & Dynamic Hit-Testing

    private func setupMonitors() {
        // 1. 마우스 이동 시 컨트롤 바 및 구역 내외부에 맞춰 마우스 이벤트 통과(Pass-through) 여부 동적 갱신
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateMousePassThrough()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateMousePassThrough()
            }
            return event
        }

        // 2. 구역 라이브 모드에서 구역 내부 스크롤 감지
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollEvent(event)
            }
        }

        // 3. Option(⌥) 키 원문 보기 토글
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
    }

    private func removeMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    /// 구역 선택 중에는 전체 클릭을 받고, 선택 완료 후 라이브 모드에서는 상단 컨트롤 바 위에서만 클릭을 받으며,
    /// 일반 모드에서는 컨트롤 바와 지정 구역 내부(블록 복사 등)에서만 클릭을 받고 나머지 게임/배경 화면은 통과시킨다.
    private func updateMousePassThrough() {
        guard isRunning,
              let model = overlayModel,
              let panel = overlayPanel,
              let screen = currentScreen
        else { return }

        if model.isSelectingRegion || model.isAdjustingRegion {
            if panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = false
            }
            return
        }

        guard let region = model.regionRect else { return }
        let mouse = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: mouse.x - screen.frame.minX,
            y: screen.frame.maxY - mouse.y
        )

        let controlBarRect: CGRect
        if AppSettings.shared.hudStyle == .notch {
            controlBarRect = OverlayModel.notchHUDHitRect(
                canvasSize: model.canvasSize,
                notchMetrics: model.notchMetrics,
                isExpanded: model.isNotchExpanded
            ).insetBy(dx: -8, dy: -8)
        } else {
            controlBarRect = OverlayModel.regionControlBarRect(
                for: region,
                canvasSize: model.canvasSize
            ).insetBy(dx: -8, dy: -8)
        }

        let isOnBorderOrHandle = OverlayModel.isPointOnRegionFrame(localPoint, region: region, tolerance: 10)

        let shouldCaptureMouse: Bool
        if model.isRegionLive {
            // 라이브 모드: 컨트롤 바 또는 구역 테두리/모서리 핸들 위에 있을 때만 마우스를 잡고,
            // 구역 안쪽 본문과 나머지 화면은 아래 게임/브라우저로 통과시킨다.
            shouldCaptureMouse = controlBarRect.contains(localPoint) || isOnBorderOrHandle
        } else {
            // 일반 모드: 컨트롤 바, 테두리 핸들, 번역된 구역 내부(개별 블록 호버/복사)에서 클릭 수신
            shouldCaptureMouse = controlBarRect.contains(localPoint)
                || isOnBorderOrHandle
                || region.insetBy(dx: -10, dy: -10).contains(localPoint)
        }

        if panel.ignoresMouseEvents == shouldCaptureMouse {
            panel.ignoresMouseEvents = !shouldCaptureMouse
        }
    }

    // MARK: - Scroll Tracking Inside Region (Live Mode)

    private func handleScrollEvent(_ event: NSEvent) {
        guard isRunning,
              let model = overlayModel,
              !model.isSelectingRegion,
              model.isRegionLive,
              let region = model.regionRect,
              let screen = currentScreen
        else { return }

        // 마우스 커서가 지정된 구역 근처에 있을 때 발생한 스크롤만 해당 구역 스크롤로 처리
        let mouse = NSEvent.mouseLocation
        let localMouse = CGPoint(
            x: mouse.x - screen.frame.minX,
            y: screen.frame.maxY - mouse.y
        )
        guard region.insetBy(dx: -24, dy: -24).contains(localMouse) else { return }

        scrollGeneration &+= 1
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14.0

        if abs(dy) > 0.01 {
            if scrollVelocityMonitor.record(dy: dy, viewportHeight: region.height) {
                model.triggerScrollSpeedWarning()
            }
        }

        guard !model.anchorBlocks.isEmpty else {
            scheduleSettleWait(milliseconds: 200)
            return
        }

        if abs(dy) > 0.01 {
            let scrollDir = dy > 0 ? 1 : -1
            if clampedScrollDirection != 0 {
                if scrollDir == clampedScrollDirection {
                    scheduleSettleWait(milliseconds: 160)
                    return
                } else {
                    clampedScrollDirection = 0
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
                within: region
            )

            if visibleRemaining == 0 && model.blocks.isEmpty && abs(cumulativeScrollDelta.y) > region.height * 0.95 {
                model.triggerScrollSpeedWarning()
                scrollTracker.reset()
                cumulativeScrollDelta = .zero
                clampedScrollDirection = 0
                wasTrackingScroll = false
                model.isTrackingScroll = false
                scheduleSettleWait(milliseconds: 180)
                return
            }

            scheduleRegionBoundaryCheckIfNeeded(region: region, scrollDirection: scrollDir)
        }

        if event.momentumPhase == .ended {
            scheduleSettleWait(milliseconds: 150)
        } else if event.phase == .ended {
            scheduleSettleWait(milliseconds: 240)
        } else {
            scheduleSettleWait(milliseconds: 210)
        }
    }

    private func scheduleRegionBoundaryCheckIfNeeded(region: CGRect, scrollDirection: Int) {
        guard boundaryCheckTask == nil, scrollTracker.hasReference else { return }
        let now = ContinuousClock.now
        guard now - lastBoundaryCheckTime >= .milliseconds(70) else { return }
        lastBoundaryCheckTime = now

        boundaryCheckTask = Task { @MainActor [weak self] in
            defer { self?.boundaryCheckTask = nil }
            guard let self, self.isRunning, let model = self.overlayModel else { return }
            guard model.isRegionLive, !model.anchorBlocks.isEmpty, self.scrollTracker.hasReference else { return }

            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, self.isRunning else { return }

            let dyAtCapture = self.cumulativeScrollDelta.y
            guard abs(dyAtCapture) >= 3.0 else { return }

            do {
                let capture = try await ScreenCapturer.capture(screen: self.currentScreen)
                guard !Task.isCancelled, self.isRunning else { return }

                let regionContext = WindowTabContext(
                    windowID: 0,
                    ownerPID: 0,
                    title: "Region",
                    bounds: region
                )
                let checkResult = self.scrollTracker.checkScrollBoundary(
                    newImage: capture.image,
                    currentTabContext: regionContext,
                    predictedCumulativeDy: dyAtCapture
                )

                if case .hitBoundary(let clampedCumulativeDy) = checkResult.state {
                    self.clampedScrollDirection = scrollDirection
                    self.cumulativeScrollDelta = CGPoint(x: 0, y: clampedCumulativeDy)
                    withAnimation(.easeOut(duration: 0.08)) {
                        _ = model.applyScrollOffset(
                            cumulativeDelta: self.cumulativeScrollDelta,
                            within: region
                        )
                    }
                }
            } catch {
                // 일시적 캡처 오류 무시
            }
        }
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

    // MARK: - Region Standard Pipeline (단발성 정밀 구역 번역)

    private func runSingleRegionScan(region: CGRect) async {
        guard let model = overlayModel else { return }
        model.phase = .recognizing

        do {
            let capture = try await ScreenCapturer.capture(screen: currentScreen)
            if Task.isCancelled || !isRunning { return }

            let scale = CGFloat(capture.image.width) / max(1, model.canvasSize.width)
            model.image = capture.image

            guard let croppedImage = cropImage(capture.image, to: region, scale: scale) else {
                model.setBlocks([])
                return
            }
            model.regionCropImage = croppedImage

            let rawLines = try await TextRecognizer.recognize(image: croppedImage, canvasSize: region.size)
            if Task.isCancelled || !isRunning { return }

            let lines = rawLines.map { line in
                RecognizedLine(
                    text: line.text,
                    rect: line.rect.offsetBy(dx: region.minX, dy: region.minY),
                    isVertical: line.isVertical
                )
            }

            let blocks = BlockBuilder.build(from: lines, verticalOnly: model.isRegionVerticalOnly).filter { block in
                guard let lang = block.language, lang != .korean else { return false }
                guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                return AppSettings.shared.isEnabled(code, overrideLanguages: model.overrideLanguages)
            }

            let fullImage = capture.image
            var overlayBlocks = await Task.detached(priority: .userInitiated) {
                ColorSampler.makeOverlayBlocks(blocks, image: fullImage, scale: scale)
            }.value
            if Task.isCancelled || !isRunning { return }

            for i in overlayBlocks.indices {
                if let cached = cachedTranslation(for: overlayBlocks[i].sourceText) {
                    overlayBlocks[i].translated = cached
                }
            }

            withAnimation(.easeOut(duration: 0.14)) {
                model.setBlocks(overlayBlocks)
            }
            guard !overlayBlocks.isEmpty else { return }

            let needsTranslation = model.blocks.contains { $0.translated == nil && !$0.isMissingPack }
            if needsTranslation {
                await TranslationCoordinator().translate(into: model)
                if Task.isCancelled || !isRunning { return }
                for block in model.anchorBlocks {
                    if let translated = block.translated {
                        storeTranslation(translated, for: block.sourceText)
                    }
                }
            } else {
                model.finish(failures: [])
            }
        } catch {
            if !Task.isCancelled {
                model.phase = .failed("구역 인식 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Region Live Loop (게임 채팅 등 지정 구역 전용 가로 4분할 실시간 번역)

    private func runRegionLiveLoop(region: CGRect) async {
        let coordinator = TranslationCoordinator()
        let regionTabContext = WindowTabContext(
            windowID: 0,
            ownerPID: 0,
            title: "Region",
            bounds: region
        )

        while !Task.isCancelled && isRunning {
            guard let model = overlayModel,
                  overlayPanel != nil,
                  model.isRegionLive,
                  !model.isSelectingRegion
            else { break }

            if isInteracting {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            needsImmediateScan = false

            do {
                let captureGen = scrollGeneration
                let capture = try await ScreenCapturer.capture(screen: currentScreen)
                if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                if isInteracting || scrollGeneration != captureGen { continue }

                currentScreen = capture.screen
                let scale = CGFloat(capture.image.width) / max(1, model.canvasSize.width)
                model.image = capture.image

                guard let croppedImage = cropImage(capture.image, to: region, scale: scale) else {
                    await waitNextCycle(milliseconds: 350)
                    continue
                }

                // 지정 구역 내부를 가로 4개 밴드로 분리하여 바뀐 줄(예: 하단 신규 채팅)만 감지
                let bandDetection = bandTracker.detectChanges(
                    in: croppedImage,
                    targetRect: region,
                    threshold: 2.2,
                    overlapMargin: 20.0
                )

                let isRegionVisuallyChanged: Bool
                if case .none = bandDetection {
                    isRegionVisuallyChanged = false
                } else {
                    isRegionVisuallyChanged = true
                    clampedScrollDirection = 0
                }

                var forceFullScan = model.blocks.isEmpty || wasTrackingScroll
                if !model.blocks.isEmpty {
                    if wasTrackingScroll {
                        if scrollTracker.hasReference {
                            let boundaryResult = scrollTracker.checkScrollBoundary(
                                newImage: capture.image,
                                currentTabContext: regionTabContext,
                                predictedCumulativeDy: cumulativeScrollDelta.y
                            )
                            if case .hitBoundary(let clampedDy) = boundaryResult.state {
                                cumulativeScrollDelta = CGPoint(x: 0, y: clampedDy)
                                withAnimation(.easeOut(duration: 0.08)) {
                                    _ = model.applyScrollOffset(
                                        cumulativeDelta: cumulativeScrollDelta,
                                        within: region
                                    )
                                }
                            }
                        }
                        wasTrackingScroll = false
                        forceFullScan = true
                    } else if !isRegionVisuallyChanged {
                        // 4개 가로 밴드 모두 변화가 없으면 OCR 생략 (CPU 절약 및 번역 고정 유지)
                        await waitNextCycle(milliseconds: 320)
                        continue
                    } else if scrollTracker.hasReference {
                        // 새로운 채팅 줄이 올라오며 기존 텍스트가 위로 밀려 올라간 경우 위치 추적 반영
                        let trackResult = scrollTracker.verifyAndTrack(
                            newImage: capture.image,
                            currentTabContext: regionTabContext,
                            predictedCumulativeDelta: .zero
                        )
                        if case .tracked(let trackedBlocks, let actualDelta) = trackResult.status {
                            if abs(actualDelta.y) >= 3.0 {
                                forceFullScan = true
                                withAnimation(.easeOut(duration: 0.08)) {
                                    model.blocks = trackedBlocks
                                }
                            }
                        }
                    }
                }

                // 가로 4분할 부분 밴드 OCR vs 구역 전체 OCR 분기 실행
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
                        if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                        if isInteracting || scrollGeneration != captureGen { break }

                        let offsetLines = rawLines.map { line in
                            RecognizedLine(
                                text: line.text,
                                rect: line.rect.offsetBy(dx: range.expandedRect.minX, dy: range.expandedRect.minY),
                                isVertical: line.isVertical
                            )
                        }

                        let rangeBlocks = BlockBuilder.build(from: offsetLines, verticalOnly: model.isRegionVerticalOnly).filter { block in
                            guard block.rect.midY >= range.coreRect.minY - 4,
                                  block.rect.midY <= range.coreRect.maxY + 4
                            else { return false }
                            guard let lang = block.language, lang != .korean else { return false }
                            guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                            return AppSettings.shared.isEnabled(code, overrideLanguages: model.overrideLanguages)
                        }
                        partialTextBlocks.append(contentsOf: rangeBlocks)
                    }

                    if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                    if isInteracting || scrollGeneration != captureGen { continue }

                    let fullImage = capture.image
                    var partialOverlayBlocks = await Task.detached(priority: .userInitiated) {
                        ColorSampler.makeOverlayBlocks(partialTextBlocks, image: fullImage, scale: scale)
                    }.value
                    if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                    if isInteracting || scrollGeneration != captureGen { continue }

                    for i in partialOverlayBlocks.indices {
                        if let cached = cachedTranslation(for: partialOverlayBlocks[i].sourceText) {
                            partialOverlayBlocks[i].translated = cached
                        }
                    }

                    if !isInteracting && scrollGeneration == captureGen {
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.mergePartialBands(newBandBlocks: partialOverlayBlocks, dirtyRanges: dirtyRanges)
                        }
                        lastSignature = model.blocks.map { "\($0.sourceText)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                        cumulativeScrollDelta = .zero
                        scrollTracker.captureReference(
                            image: capture.image,
                            blocks: model.anchorBlocks,
                            canvasSize: model.canvasSize,
                            tabContext: regionTabContext
                        )
                    }
                } else {
                    // 구역 전체 OCR 수행
                    let rawLines = try await TextRecognizer.recognize(image: croppedImage, canvasSize: region.size)
                    if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                    if isInteracting || scrollGeneration != captureGen { continue }

                    let lines = rawLines.map { line in
                        RecognizedLine(
                            text: line.text,
                            rect: line.rect.offsetBy(dx: region.minX, dy: region.minY),
                            isVertical: line.isVertical
                        )
                    }

                    let blocks = BlockBuilder.build(from: lines, verticalOnly: model.isRegionVerticalOnly).filter { block in
                        guard let lang = block.language, lang != .korean else { return false }
                        guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                        return AppSettings.shared.isEnabled(code, overrideLanguages: model.overrideLanguages)
                    }

                    let currentSignature = blocks.map { "\($0.text)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                    if currentSignature == lastSignature && !blocks.isEmpty && !model.blocks.isEmpty {
                        if abs(cumulativeScrollDelta.y) > 0.5 {
                            cumulativeScrollDelta = .zero
                            withAnimation(.easeOut(duration: 0.08)) {
                                _ = model.applyScrollOffset(cumulativeDelta: .zero, within: region)
                            }
                        }
                        await waitNextCycle(milliseconds: 350)
                        continue
                    }
                    lastSignature = currentSignature

                    if blocks.isEmpty {
                        scrollTracker.reset()
                        cumulativeScrollDelta = .zero
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.setBlocks([])
                        }
                        await waitNextCycle(milliseconds: 350)
                        continue
                    }

                    let fullImage = capture.image
                    var overlayBlocks = await Task.detached(priority: .userInitiated) {
                        ColorSampler.makeOverlayBlocks(blocks, image: fullImage, scale: scale)
                    }.value
                    if Task.isCancelled || !isRunning || !model.isRegionLive { break }
                    if isInteracting || scrollGeneration != captureGen { continue }

                    for i in overlayBlocks.indices {
                        if let cached = cachedTranslation(for: overlayBlocks[i].sourceText) {
                            overlayBlocks[i].translated = cached
                        }
                    }

                    if !isInteracting && scrollGeneration == captureGen {
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.mergeBlocks(overlayBlocks)
                        }
                        cumulativeScrollDelta = .zero
                        scrollTracker.captureReference(
                            image: capture.image,
                            blocks: model.anchorBlocks,
                            canvasSize: model.canvasSize,
                            tabContext: regionTabContext
                        )
                    }
                }

                let needsTranslation = model.blocks.contains { $0.translated == nil && !$0.isMissingPack }
                if needsTranslation && !isInteracting && scrollGeneration == captureGen {
                    await coordinator.translate(into: model)
                    if Task.isCancelled || !isRunning || !model.isRegionLive { break }

                    for block in model.anchorBlocks {
                        if let translated = block.translated {
                            storeTranslation(translated, for: block.sourceText)
                        }
                    }

                    if !isInteracting && scrollGeneration == captureGen {
                        scrollTracker.updateReferenceBlocks(model.anchorBlocks)
                    }
                }
            } catch {
                // 캡처 오류 시 다음 주기에 재시도
            }

            await waitNextCycle(milliseconds: 350)
        }
    }

    // MARK: - Helpers

    private func cropImage(_ image: CGImage, to region: CGRect, scale: CGFloat) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: region.minX * scale,
            y: region.minY * scale,
            width: region.width * scale,
            height: region.height * scale
        ).intersection(imageBounds).integral

        guard pixelRect.width >= 8, pixelRect.height >= 8 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private func cachedTranslation(for sourceText: String) -> String? {
        if let sharedCached = TranslationCacheStore.shared.lookup(sourceText) {
            return sharedCached
        }
        if let exact = translationCache[sourceText] {
            return exact
        }
        let key = ColorSampler.normalizedTextKey(sourceText)
        return translationCache[key]
    }

    private func storeTranslation(_ translated: String, for sourceText: String) {
        TranslationCacheStore.shared.store(translated, for: sourceText)
        if translationCache.count > 2000 {
            translationCache.removeAll(keepingCapacity: true)
        }
        translationCache[sourceText] = translated
        translationCache[ColorSampler.normalizedTextKey(sourceText)] = translated
    }

    private func waitNextCycle(milliseconds: Int) async {
        let step = 40
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
}
