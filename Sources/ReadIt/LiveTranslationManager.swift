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

    /// 메인 루프가 캡처~OCR 병합을 진행 중인지 여부 (경계 검사 태스크와 추적 기준이 엇갈리지 않도록 동시 실행 방지)
    private var isScanningFrame: Bool = false
    /// 추적 기준(captureReference)이 갱신될 때마다 증가하는 세대 카운터
    private var referenceGeneration: UInt64 = 0
    /// 번역 요청이 진행 중인 블록 ID와 원문 (중복 요청 방지 및 응답 캐시 저장용)
    private var inFlightTranslationBlockIds = Set<Int>()
    private var inFlightSourceTexts: [Int: String] = [:]
    /// 휠 추정치 또는 부분 OCR로만 위치를 맞춘 블록이 있어 스크롤 정지 후 전체 OCR로 재정렬이 필요한지 여부
    private var needsRealignScan: Bool = false
    private var lastRealignScanTime: ContinuousClock.Instant = .now - .seconds(10)
    /// 마지막 스크롤 휠 이벤트 시각 (스크롤 정지 판정용)
    private var lastScrollEventTime: ContinuousClock.Instant = .now - .seconds(10)
    /// 경계 잠금 상태에서 무시된 같은 방향 휠 이동량 (잠금이 오탐인지 재검증용)
    private var clampedProbeDy: CGFloat = 0
    /// 키보드 스크롤(Space, PageUp/Down, 방향키 등) 감지 모니터와 후속 재스캔 태스크
    private var keyMonitor: Any?
    private var keyScrollTask: Task<Void, Never>?

    private var isScrollSettled: Bool {
        ContinuousClock.now - lastScrollEventTime >= .milliseconds(140)
    }

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
        self.isScanningFrame = false
        self.inFlightTranslationBlockIds.removeAll()
        self.inFlightSourceTexts.removeAll()
        self.needsRealignScan = false
        self.clampedProbeDy = 0

        // 1. 마우스 휠 / 트랙패드 스크롤 감지: 같은 탭 내에서는 블록이 스크롤을 따라 이동하도록 처리
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollEvent(event)
            }
        }

        // 2. 마우스 클릭 감지: 보고 있는 탭이 바뀌었는지 확인하여 같은 탭이면 유지, 다른 탭이면 기본 라이브 번역으로 복귀
        //    버튼을 뗄 때도 확인하여 창 드래그 이동 종료 시점을 놓치지 않는다.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.handlePointerOrAppActivity()
            }
        }

        // 2-1. 키보드 스크롤 감지: 휠 이벤트 없이 화면이 움직이는 경우 즉시 재추적
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            Task { @MainActor in
                self?.handleKeyboardScroll(keyCode: keyCode)
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
        keyScrollTask?.cancel()
        keyScrollTask = nil

        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
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
        isScanningFrame = false
        inFlightTranslationBlockIds.removeAll()
        inFlightSourceTexts.removeAll()
        needsRealignScan = false
        clampedProbeDy = 0

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
            lastScrollEventTime = .now
            if scrollVelocityMonitor.record(dy: dy, viewportHeight: viewportHeight) {
                model.triggerScrollSpeedWarning()
            }
        }

        guard !model.anchorBlocks.isEmpty else {
            isInteracting = false
            needsImmediateScan = true
            return
        }

        if abs(dy) > 0.01 {
            let scrollDir = dy > 0 ? 1 : -1

            if clampedScrollDirection != 0 {
                if scrollDir == clampedScrollDirection {
                    // 경계 잠금 중 같은 방향 휠은 블록을 움직이지 않되, 잠금이 오탐인지 화면 비교로 재검증한다.
                    clampedProbeDy += dy
                    scheduleBoundaryCheckIfNeeded(scrollDirection: scrollDir)
                    scheduleSettleWait(milliseconds: 35)
                    return
                } else {
                    clampedScrollDirection = 0
                    clampedProbeDy = 0
                }
            }

            let now = ContinuousClock.now
            if now - lastWindowCheckTime > .milliseconds(300), let screen = currentScreen {
                currentTabContext = ScrollTracker.windowTabContextUnderMouse(in: screen)
                lastWindowCheckTime = now
                if reconcileTabChange(to: currentTabContext, model: model) {
                    return
                }
            }

            cumulativeScrollDelta.x = 0
            cumulativeScrollDelta.y += dy

            wasTrackingScroll = true
            // 휠 추정치로 블록을 옮겼으므로 스크롤이 멈추면 전체 OCR로 실제 글자 위치에 다시 맞춘다.
            needsRealignScan = true
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

            // 스크롤 내리자마자 새로 노출된 영역이 생기면 대기 없이 즉시 OCR 루프 깨우기
            if totalScrolled >= 14 {
                isInteracting = false
                needsImmediateScan = true
            }
        }

        if event.momentumPhase == .ended || event.phase == .ended {
            scheduleSettleWait(milliseconds: 35)
        } else {
            scheduleSettleWait(milliseconds: 45)
        }
    }

    /// 스크롤 도중 실제 화면 이동량을 측정해 휠 추정치의 오차, 고정 UI, 스크롤 한계, 추적 실패를 보정한다.
    private func scheduleBoundaryCheckIfNeeded(scrollDirection: Int) {
        guard boundaryCheckTask == nil, !isScanningFrame, scrollTracker.hasReference else { return }
        let now = ContinuousClock.now
        guard now - lastBoundaryCheckTime >= .milliseconds(35) else { return }
        lastBoundaryCheckTime = now

        boundaryCheckTask = Task { @MainActor [weak self] in
            defer { self?.boundaryCheckTask = nil }
            guard let self, self.isRunning, let model = self.overlayModel else { return }
            guard !model.anchorBlocks.isEmpty, self.scrollTracker.hasReference else { return }

            let referenceGenAtStart = self.referenceGeneration
            do {
                let capture = try await ScreenCapturer.captureScreenUnderMouse()
                guard !Task.isCancelled, self.isRunning else { return }
                // 캡처 대기 중 메인 루프가 추적 기준을 바꿨다면 이 측정은 이전 기준에 대한 값이므로 폐기
                guard !self.isScanningFrame, self.referenceGeneration == referenceGenAtStart else { return }

                // 캡처 직후의 누적량을 예측값으로 사용 (캡처 대기 중 유입된 휠 이동 포함)
                let isProbingClamp = self.clampedScrollDirection != 0
                let dyAtCapture = self.cumulativeScrollDelta.y
                let predictedDy = dyAtCapture + (isProbingClamp ? self.clampedProbeDy : 0)
                guard abs(predictedDy) >= 3.0 else { return }

                let checkResult = self.scrollTracker.checkScrollBoundary(
                    newImage: capture.image,
                    currentTabContext: self.currentTabContext,
                    predictedCumulativeDy: predictedDy
                )

                switch checkResult.state {
                case .movingNormally(let pinnedIds):
                    if isProbingClamp {
                        // 잠금 방향으로 실제 화면이 계속 움직이고 있음 -> 경계 잠금 오탐 해제
                        self.clampedScrollDirection = 0
                        self.clampedProbeDy = 0
                        self.cumulativeScrollDelta = CGPoint(x: 0, y: predictedDy)
                        self.applyTrackedOffset(model: model, pinnedIds: pinnedIds, animated: true)
                    } else if !pinnedIds.isEmpty {
                        self.applyTrackedOffset(model: model, pinnedIds: pinnedIds, animated: false)
                    }

                case .driftCorrected(let actualCumulativeDy, let pinnedIds):
                    if isProbingClamp {
                        let actualShiftInDir = (actualCumulativeDy - dyAtCapture) * CGFloat(scrollDirection)
                        if actualShiftInDir >= 3.0 {
                            self.clampedScrollDirection = 0
                        }
                        self.clampedProbeDy = 0
                    }
                    self.cumulativeScrollDelta = CGPoint(x: 0, y: actualCumulativeDy)
                    self.applyTrackedOffset(model: model, pinnedIds: pinnedIds, animated: true)

                case .hitBoundary(let clampedCumulativeDy, let pinnedIds):
                    self.clampedScrollDirection = scrollDirection
                    self.clampedProbeDy = 0
                    self.cumulativeScrollDelta = CGPoint(x: 0, y: clampedCumulativeDy)
                    self.applyTrackedOffset(model: model, pinnedIds: pinnedIds, animated: true)

                case .targetLost:
                    self.fallbackToBaseLiveTranslation()
                }
            } catch {
                // 캡처 오류 무시
            }
        }
    }

    private func applyTrackedOffset(model: OverlayModel, pinnedIds: Set<Int>?, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.06)) {
                _ = model.applyScrollOffset(
                    cumulativeDelta: cumulativeScrollDelta,
                    within: currentTabContext?.bounds,
                    pinnedIds: pinnedIds
                )
            }
        } else {
            _ = model.applyScrollOffset(
                cumulativeDelta: cumulativeScrollDelta,
                within: currentTabContext?.bounds,
                pinnedIds: pinnedIds
            )
        }
    }

    /// Space, PageUp/Down, Home/End, 상/하 방향키처럼 휠 이벤트 없이 화면을 움직이는 키 입력 후 즉시 재추적한다.
    private func handleKeyboardScroll(keyCode: UInt16) {
        let scrollKeyCodes: Set<UInt16> = [49, 116, 121, 115, 119, 125, 126]
        guard isRunning, overlayModel != nil, scrollKeyCodes.contains(keyCode) else { return }

        keyScrollTask?.cancel()
        keyScrollTask = Task { @MainActor [weak self] in
            // 부드러운 스크롤 애니메이션 도중과 종료 직후에 각각 재스캔하여 최종 위치에 맞춘다.
            for delayMs in [90, 230] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.lastSignature = ""
                self.isInteracting = false
                self.needsImmediateScan = true
            }
        }
    }

    private func handlePointerOrAppActivity() {
        guard isRunning else { return }

        tabCheckTask?.cancel()
        tabCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let self,
                  self.isRunning,
                  let screen = self.currentScreen,
                  let model = self.overlayModel
            else { return }

            let newTab = ScrollTracker.windowTabContextUnderMouse(in: screen)
            self.currentTabContext = newTab
            self.lastWindowCheckTime = .now

            if !self.reconcileTabChange(to: newTab, model: model) {
                self.lastSignature = ""
                self.scheduleSettleWait(milliseconds: 180)
            }
        }
    }

    /// 추적 기준 창과 현재 창을 비교하여 달라졌으면 추적 기준을 초기화하고 즉시 재스캔을 요청한다.
    /// - 같은 창이 이동만 한 경우: 창 안의 블록을 이동량만큼 즉시 옮긴 뒤 전체 OCR로 재정렬
    /// - 같은 창의 크기가 바뀐 경우: 줄바꿈이 달라져 기존 위치를 신뢰할 수 없으므로 블록을 비우고 재인식
    /// - 다른 창으로 바뀐 경우: 기존 블록은 유지하고 전체 OCR 결과로 교체
    /// - Returns: 기준 창이 바뀌었으면 true
    @discardableResult
    private func reconcileTabChange(to newTab: WindowTabContext?, model: OverlayModel) -> Bool {
        guard let refTab = scrollTracker.referenceTabContext,
              let newTab,
              !newTab.isSameTab(as: refTab)
        else { return false }

        let isSameWindow = newTab.windowID == refTab.windowID && newTab.ownerPID == refTab.ownerPID
        let isSameSize = abs(newTab.bounds.width - refTab.bounds.width) <= 6
            && abs(newTab.bounds.height - refTab.bounds.height) <= 6

        resetTrackingState(model: model)

        if isSameWindow && isSameSize {
            let delta = CGPoint(
                x: newTab.bounds.minX - refTab.bounds.minX,
                y: newTab.bounds.minY - refTab.bounds.minY
            )
            withAnimation(.easeOut(duration: 0.06)) {
                model.shiftAllBlocks(by: delta, within: refTab.bounds)
            }
        } else if isSameWindow {
            withAnimation(.easeOut(duration: 0.10)) {
                model.clearForRealign()
            }
        }

        needsRealignScan = true
        isInteracting = false
        needsImmediateScan = true
        return true
    }

    /// 스크롤 추적 기준을 초기화한다. 현재 화면에 보이는 블록 위치를 새 기준 좌표로 고정하여 이후 오프셋이 엇나가지 않게 한다.
    private func resetTrackingState(model: OverlayModel) {
        boundaryCheckTask?.cancel()
        boundaryCheckTask = nil
        model.updateAnchors(model.blocks)
        scrollTracker.reset()
        bandTracker.reset()
        referenceGeneration &+= 1
        cumulativeScrollDelta = .zero
        clampedScrollDirection = 0
        clampedProbeDy = 0
        wasTrackingScroll = false
        model.isTrackingScroll = false
        lastSignature = ""
    }


    private func fallbackToBaseLiveTranslation() {
        guard isRunning, let model = overlayModel else { return }

        resetTrackingState(model: model)
        needsRealignScan = false

        // 추적 기준을 잃은 블록이 엉뚱한 위치에 남지 않도록 즉시 비우고, 번역 캐시로 다음 전체 스캔에서 바로 복원한다.
        withAnimation(.easeOut(duration: 0.10)) {
            model.clearForRealign()
        }
        isInteracting = false
        needsImmediateScan = true
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

    private func scheduleSettleWait(milliseconds: Int) {
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
        let step = 15
        var elapsed = 0
        while elapsed < milliseconds && !Task.isCancelled && isRunning {
            if (needsImmediateScan || abs(cumulativeScrollDelta.y) >= 14) && !isInteracting {
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
                try? await Task.sleep(for: .milliseconds(15))
                continue
            }
            needsImmediateScan = false

            do {
                isScanningFrame = true
                defer { isScanningFrame = false }

                let capture = try await ScreenCapturer.captureScreenUnderMouse()
                if Task.isCancelled || !isRunning { break }

                // 캡처 직후의 누적 스크롤 Y값을 읽어 캡처 시점의 기준선으로 삼는다
                var capturedScrollDy = cumulativeScrollDelta.y
                let hadScrollActivity = wasTrackingScroll || abs(capturedScrollDy) >= 10

                currentScreen = capture.screen
                let scale = CGFloat(capture.image.width) / max(1, model.canvasSize.width)
                model.image = capture.image
                let latestTabContext = ScrollTracker.windowTabContextUnderMouse(in: capture.screen)
                currentTabContext = latestTabContext
                let screenRect = CGRect(origin: .zero, size: model.canvasSize)
                let menuBarHeight = AppSettings.shared.includeMenuBar
                    ? 0
                    : max(24, capture.screen.frame.maxY - capture.screen.visibleFrame.maxY)

                // 1-A. 스크롤 직후 새로 노출된 영역만 지연 없이 즉시 부분 크롭 OCR + 비동기 번역
                if hadScrollActivity, !model.anchorBlocks.isEmpty {
                    if let refTab = scrollTracker.referenceTabContext,
                       let curTab = latestTabContext,
                       !curTab.isSameTab(as: refTab) {
                        scrollTracker.reset()
                        cumulativeScrollDelta = .zero
                        clampedScrollDirection = 0
                        wasTrackingScroll = false
                    } else {
                        var detectedPinnedIds = Set<Int>()
                        if scrollTracker.hasReference, abs(capturedScrollDy) >= 3.0 {
                            let boundaryResult = scrollTracker.checkScrollBoundary(
                                newImage: capture.image,
                                currentTabContext: latestTabContext,
                                predictedCumulativeDy: capturedScrollDy
                            )
                            switch boundaryResult.state {
                            case .movingNormally(let pinnedIds):
                                detectedPinnedIds = pinnedIds
                            case .driftCorrected(let actualDy, let pinnedIds):
                                let rawCaptured = capturedScrollDy
                                capturedScrollDy = actualDy
                                cumulativeScrollDelta.y += (actualDy - rawCaptured)
                                detectedPinnedIds = pinnedIds
                                needsRealignScan = true
                            case .hitBoundary(let clampedDy, let pinnedIds):
                                let rawCaptured = capturedScrollDy
                                capturedScrollDy = clampedDy
                                cumulativeScrollDelta.y += (clampedDy - rawCaptured)
                                detectedPinnedIds = pinnedIds
                                clampedScrollDirection = (capturedScrollDy >= 0 ? 1 : -1)
                                needsRealignScan = true
                            case .targetLost:
                                scrollTracker.reset()
                                model.clearForRealign()
                                cumulativeScrollDelta = .zero
                                capturedScrollDy = 0
                            }
                        }

                        let viewport = (latestTabContext?.bounds ?? screenRect).intersection(screenRect)
                        if abs(capturedScrollDy) >= 12,
                           abs(capturedScrollDy) < viewport.height * 0.72,
                           viewport.width > 60,
                           viewport.height > 60 {
                            let stripHeight = min(viewport.height, max(52, abs(capturedScrollDy) + 32))
                            let coreStripRect: CGRect
                            let expandedStripRect: CGRect

                            if capturedScrollDy < 0 {
                                let coreMinY = max(viewport.minY, viewport.maxY - stripHeight)
                                coreStripRect = CGRect(x: viewport.minX, y: coreMinY, width: viewport.width, height: viewport.maxY - coreMinY)
                                let expMinY = max(viewport.minY, coreMinY - 48)
                                expandedStripRect = CGRect(x: viewport.minX, y: expMinY, width: viewport.width, height: viewport.maxY - expMinY)
                            } else {
                                let coreMaxY = min(viewport.maxY, viewport.minY + stripHeight)
                                coreStripRect = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: coreMaxY - viewport.minY)
                                let expMaxY = min(viewport.maxY, coreMaxY + 48)
                                expandedStripRect = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: expMaxY - viewport.minY)
                            }

                            if let stripImage = cropImage(capture.image, to: expandedStripRect, scale: scale) {
                                let rawLines = try await TextRecognizer.recognize(
                                    image: stripImage,
                                    canvasSize: expandedStripRect.size
                                )
                                if Task.isCancelled || !isRunning { break }

                                var offsetLines = rawLines.map { line in
                                    RecognizedLine(
                                        text: line.text,
                                        rect: line.rect.offsetBy(dx: expandedStripRect.minX, dy: expandedStripRect.minY),
                                        isVertical: line.isVertical
                                    )
                                }
                                if menuBarHeight > 0 {
                                    offsetLines = offsetLines.filter { $0.rect.midY >= menuBarHeight }
                                }

                                let stripTextBlocks = BlockBuilder.build(from: offsetLines, verticalOnly: false).filter { block in
                                    guard block.rect.midY >= expandedStripRect.minY + 2,
                                          block.rect.midY <= expandedStripRect.maxY - 2
                                    else { return false }
                                    guard let lang = block.language, lang != .korean else { return false }
                                    guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                                    return AppSettings.shared.isEnabled(code)
                                }

                                let fullImage = capture.image
                                var stripOverlayBlocks = await Task.detached(priority: .userInitiated) {
                                    ColorSampler.makeOverlayBlocks(stripTextBlocks, image: fullImage, scale: scale)
                                }.value
                                if Task.isCancelled || !isRunning { break }

                                for i in stripOverlayBlocks.indices {
                                    if let cached = cachedTranslation(for: stripOverlayBlocks[i].sourceText) {
                                        stripOverlayBlocks[i].translated = cached
                                    }
                                }

                                let residualDy = cumulativeScrollDelta.y - capturedScrollDy
                                cumulativeScrollDelta = CGPoint(x: 0, y: residualDy)
                                wasTrackingScroll = abs(residualDy) >= 6

                                let pendingBlocks = model.rebaseAndMergeScrollStrip(
                                    newStripBlocks: stripOverlayBlocks,
                                    coreStripRect: coreStripRect,
                                    capturedDelta: CGPoint(x: 0, y: capturedScrollDy),
                                    residualDelta: cumulativeScrollDelta,
                                    within: latestTabContext?.bounds,
                                    pinnedIds: detectedPinnedIds
                                )

                                lastSignature = model.anchorBlocks.map { "\($0.sourceText)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                                scrollTracker.captureReference(
                                    image: capture.image,
                                    blocks: model.anchorBlocks,
                                    canvasSize: model.canvasSize,
                                    tabContext: latestTabContext
                                )
                                referenceGeneration &+= 1

                                _ = bandTracker.detectChanges(
                                    in: capture.image,
                                    targetRect: screenRect,
                                    threshold: 2.8,
                                    overlapMargin: 28.0
                                )

                                dispatchTranslation(blocks: pendingBlocks, coordinator: coordinator, model: model)

                                await waitNextCycle(milliseconds: 50)
                                continue
                            }
                        }
                    }
                }

                // 2. 가로 4분할 스트립 변화 감지 수행
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
                }

                // 3. 탭 전환 확인 및 스크롤/비전 상태 처리
                var forceFullScan = model.blocks.isEmpty || wasTrackingScroll || needsRealignScan
                if !model.blocks.isEmpty {
                    if let refTab = scrollTracker.referenceTabContext,
                       let curTab = latestTabContext,
                       !curTab.isSameTab(as: refTab) {
                        scrollTracker.reset()
                        cumulativeScrollDelta = .zero
                        clampedScrollDirection = 0
                        wasTrackingScroll = false
                        forceFullScan = true
                    } else if wasTrackingScroll {
                        if scrollTracker.hasReference {
                            let boundaryResult = scrollTracker.checkScrollBoundary(
                                newImage: capture.image,
                                currentTabContext: latestTabContext,
                                predictedCumulativeDy: cumulativeScrollDelta.y
                            )
                            switch boundaryResult.state {
                            case .movingNormally(let pinnedIds):
                                if !pinnedIds.isEmpty {
                                    _ = model.applyScrollOffset(
                                        cumulativeDelta: cumulativeScrollDelta,
                                        within: latestTabContext?.bounds,
                                        pinnedIds: pinnedIds
                                    )
                                }
                            case .driftCorrected(let actualDy, let pinnedIds):
                                cumulativeScrollDelta = CGPoint(x: 0, y: actualDy)
                                withAnimation(.easeOut(duration: 0.06)) {
                                    _ = model.applyScrollOffset(
                                        cumulativeDelta: cumulativeScrollDelta,
                                        within: latestTabContext?.bounds,
                                        pinnedIds: pinnedIds
                                    )
                                }
                            case .hitBoundary(let clampedDy, let pinnedIds):
                                clampedScrollDirection = (cumulativeScrollDelta.y >= 0 ? 1 : -1)
                                cumulativeScrollDelta = CGPoint(x: 0, y: clampedDy)
                                withAnimation(.easeOut(duration: 0.08)) {
                                    _ = model.applyScrollOffset(
                                        cumulativeDelta: cumulativeScrollDelta,
                                        within: latestTabContext?.bounds,
                                        pinnedIds: pinnedIds
                                    )
                                }
                            case .targetLost:
                                scrollTracker.reset()
                                model.clearForRealign()
                                cumulativeScrollDelta = .zero
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
                                if abs(actualDelta.y) >= 3.0 {
                                    forceFullScan = true
                                    withAnimation(.easeOut(duration: 0.10)) {
                                        model.blocks = trackedBlocks
                                    }
                                }
                            case .targetLost:
                                scrollTracker.reset()
                                model.clearForRealign()
                                cumulativeScrollDelta = .zero
                                forceFullScan = true
                            }
                        } else {
                            forceFullScan = true
                        }
                    } else if !forceFullScan {
                        // 4개 가로 밴드 모두 변화가 없고 스크롤/재정렬도 없었으면 OCR 완전 생략
                        await waitNextCycle(milliseconds: 500)
                        continue
                    }
                }

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

                    let fullImage = capture.image
                    var partialOverlayBlocks = await Task.detached(priority: .userInitiated) {
                        ColorSampler.makeOverlayBlocks(partialTextBlocks, image: fullImage, scale: scale)
                    }.value
                    if Task.isCancelled || !isRunning { break }

                    for i in partialOverlayBlocks.indices {
                        if let cached = cachedTranslation(for: partialOverlayBlocks[i].sourceText) {
                            partialOverlayBlocks[i].translated = cached
                        }
                    }

                    let residualDy = cumulativeScrollDelta.y - capturedScrollDy
                    withAnimation(.easeOut(duration: 0.12)) {
                        model.mergePartialBands(newBandBlocks: partialOverlayBlocks, dirtyRanges: dirtyRanges)
                    }
                    lastSignature = model.blocks.map { "\($0.sourceText)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                    scrollTracker.captureReference(
                        image: capture.image,
                        blocks: model.anchorBlocks,
                        canvasSize: model.canvasSize,
                        tabContext: latestTabContext
                    )
                    referenceGeneration &+= 1

                    cumulativeScrollDelta = CGPoint(x: 0, y: residualDy)
                    wasTrackingScroll = abs(residualDy) >= 6
                    if abs(residualDy) > 0.5 {
                        model.applyScrollOffset(cumulativeDelta: cumulativeScrollDelta, within: latestTabContext?.bounds)
                    }

                    dispatchTranslation(blocks: model.anchorBlocks, coordinator: coordinator, model: model)
                } else {
                    // 전체 화면 OCR 스캔
                    var lines = try await TextRecognizer.recognize(image: capture.image, canvasSize: model.canvasSize)
                    if Task.isCancelled || !isRunning { break }

                    if menuBarHeight > 0 {
                        lines = lines.filter { $0.rect.midY >= menuBarHeight }
                    }

                    let blocks = BlockBuilder.build(from: lines, verticalOnly: false).filter { block in
                        guard let lang = block.language, lang != .korean else { return false }
                        guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                        return AppSettings.shared.isEnabled(code)
                    }

                    let currentSignature = blocks.map { "\($0.text)_\(Int($0.rect.minX))_\(Int($0.rect.minY))" }.joined(separator: "|")
                    if currentSignature == lastSignature && !blocks.isEmpty && !model.blocks.isEmpty && !needsRealignScan {
                        let residualDy = cumulativeScrollDelta.y - capturedScrollDy
                        cumulativeScrollDelta = CGPoint(x: 0, y: residualDy)
                        if abs(residualDy) > 0.5 {
                            withAnimation(.easeOut(duration: 0.08)) {
                                _ = model.applyScrollOffset(cumulativeDelta: cumulativeScrollDelta, within: latestTabContext?.bounds)
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

                    for i in overlayBlocks.indices {
                        if let cached = cachedTranslation(for: overlayBlocks[i].sourceText) {
                            overlayBlocks[i].translated = cached
                        }
                    }

                    let residualDy = cumulativeScrollDelta.y - capturedScrollDy
                    withAnimation(.easeOut(duration: 0.12)) {
                        model.mergeBlocks(overlayBlocks)
                    }
                    needsRealignScan = false

                    scrollTracker.captureReference(
                        image: capture.image,
                        blocks: model.anchorBlocks,
                        canvasSize: model.canvasSize,
                        tabContext: latestTabContext
                    )
                    referenceGeneration &+= 1

                    cumulativeScrollDelta = CGPoint(x: 0, y: residualDy)
                    wasTrackingScroll = abs(residualDy) >= 6
                    if abs(residualDy) > 0.5 {
                        model.applyScrollOffset(cumulativeDelta: cumulativeScrollDelta, within: latestTabContext?.bounds)
                    }

                    dispatchTranslation(blocks: model.anchorBlocks, coordinator: coordinator, model: model)
                }
            } catch {
                // 캡처 오류 시 다음 주기에 재시도
            }

            await waitNextCycle(milliseconds: 400)
        }
    }

    private func dispatchTranslation(
        blocks: [OverlayBlock],
        coordinator: TranslationCoordinator,
        model: OverlayModel
    ) {
        let pending = blocks.filter { block in
            block.translated == nil &&
            !block.isMissingPack &&
            !inFlightTranslationBlockIds.contains(block.id)
        }
        guard !pending.isEmpty else { return }

        for b in pending {
            inFlightTranslationBlockIds.insert(b.id)
            inFlightSourceTexts[b.id] = b.sourceText
        }

        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            defer {
                for b in pending {
                    self.inFlightTranslationBlockIds.remove(b.id)
                    self.inFlightSourceTexts.removeValue(forKey: b.id)
                }
            }

            coordinator.onResponse = { [weak self] blockId, translated in
                guard let self else { return }
                if let source = self.inFlightSourceTexts[blockId] {
                    self.storeTranslation(translated, for: source)
                }
            }

            let (_, _) = await coordinator.translateBlocks(pending, into: model)
            guard !Task.isCancelled, self.isRunning else { return }

            for block in model.anchorBlocks {
                if let translated = block.translated {
                    self.storeTranslation(translated, for: block.sourceText)
                }
            }
            if abs(self.cumulativeScrollDelta.y) < 1.0 {
                self.scrollTracker.updateReferenceBlocks(model.anchorBlocks)
            }
        }
    }

}
