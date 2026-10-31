import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle

@main
struct ReadItMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 메뉴 막대 전용 앱 (Dock 아이콘 없음)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem!
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    private let hotkey = HotkeyMonitor()
    private var overlay: OverlayPanel?
    private var pipeline: Task<Void, Never>?
    private var retryTimer: Timer?

    private let permissionWarningItem = NSMenuItem(title: "화면 기록 권한 필요 (설정 열기…)", action: #selector(openPermissionSettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: nil, keyEquivalent: "")
    private let liveTranslateItem = NSMenuItem(title: "실시간 라이브 번역", action: #selector(menuLiveTranslate), keyEquivalent: "3")
    private let regionTranslateItem = NSMenuItem(title: "구역 지정 번역", action: #selector(menuRegionTranslate), keyEquivalent: "4")
    private let regionRedrawItem = NSMenuItem(title: "새 구역 드래그로 지정…", action: #selector(menuRegionRedraw), keyEquivalent: "")
    private var presetMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hotkey.onTrigger = { [weak self] mode in self?.triggerTranslation(mode: mode) }
        LiveTranslationManager.shared.onStateChanged = { [weak self] _ in self?.refreshMenuState() }
        RegionTranslationManager.shared.onStateChanged = { [weak self] _ in self?.refreshMenuState() }
        requestPermissionsIfNeeded()
        startHotkey()
        TextRecognizer.warmUp()
        _ = updaterController
    }

    func applicationWillTerminate(_ notification: Notification) {
        LiveTranslationManager.shared.stop()
        RegionTranslationManager.shared.stop()
        hotkey.stop()
    }

    // MARK: - Status item / menu (macOS 순정 시스템 메뉴 스타일)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        // 1. 권한 경고 (평소에는 숨김, 권한 없을 때만 상단에 표시)
        permissionWarningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        permissionWarningItem.target = self
        menu.addItem(permissionWarningItem)

        // 2. 번역 실행 (기본 ⌥1, 세로쓰기 ⌥2, 실시간 라이브 ⌥3, 구역 지정 ⌥4)
        let translateItem = NSMenuItem(title: "화면 바로 번역", action: #selector(menuTranslate), keyEquivalent: "1")
        translateItem.keyEquivalentModifierMask = [.option]
        translateItem.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "번역")
        translateItem.target = self
        menu.addItem(translateItem)

        let verticalTranslateItem = NSMenuItem(title: "일본어 세로쓰기 번역", action: #selector(menuVerticalTranslate), keyEquivalent: "2")
        verticalTranslateItem.keyEquivalentModifierMask = [.option]
        verticalTranslateItem.image = NSImage(systemSymbolName: "character.textbox", accessibilityDescription: "세로 번역")
        verticalTranslateItem.target = self
        menu.addItem(verticalTranslateItem)

        liveTranslateItem.keyEquivalentModifierMask = [.option]
        liveTranslateItem.image = NSImage(systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: "라이브 번역")
        liveTranslateItem.target = self
        menu.addItem(liveTranslateItem)

        regionTranslateItem.keyEquivalentModifierMask = [.option]
        regionTranslateItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "구역 지정 번역")
        regionTranslateItem.target = self
        menu.addItem(regionTranslateItem)

        regionRedrawItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "새 구역 지정")
        regionRedrawItem.target = self
        menu.addItem(regionRedrawItem)

        menu.addItem(.separator())

        // 3. 언어 팩 및 기본 환경설정
        let packItem = NSMenuItem(title: "환경설정…", action: #selector(openSettings), keyEquivalent: ",")
        packItem.keyEquivalentModifierMask = [.command]
        packItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        packItem.target = self
        menu.addItem(packItem)

        loginItem.action = #selector(toggleLoginItem)
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(loginItem)

        let updateItem = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())

        // 4. 앱 종료
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ReadIt"
        let quitItem = NSMenuItem(title: "\(appName) 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        let screenAccess = CGPreflightScreenCaptureAccess()
        permissionWarningItem.isHidden = screenAccess

        let isLive = LiveTranslationManager.shared.isRunning
        liveTranslateItem.state = isLive ? .on : .off
        liveTranslateItem.title = isLive ? "실시간 라이브 번역 중지" : "실시간 라이브 번역"

        let isRegion = RegionTranslationManager.shared.isRunning
        regionTranslateItem.state = isRegion ? .on : .off
        regionTranslateItem.title = isRegion ? "구역 지정 번역 중지" : "구역 지정 번역"
        regionRedrawItem.isHidden = AppSettings.shared.lastRegionPreset == nil && !isRegion

        if let menu = statusItem.menu {
            for item in presetMenuItems {
                menu.removeItem(item)
            }
            presetMenuItems.removeAll()

            let presets = AppSettings.shared.regionPresets
            if !presets.isEmpty {
                let baseIndex = menu.index(of: regionRedrawItem) + 1
                for (offset, preset) in presets.enumerated() {
                    let modeTag = preset.isLive ? "라이브" : "일반"
                    let vertTag = preset.isVerticalOnly ? " · 세로" : ""
                    let item = NSMenuItem(
                        title: "\(preset.name) (\(modeTag)\(vertTag))",
                        action: #selector(menuSelectRegionPreset(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = preset.id.uuidString
                    item.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: preset.name)
                    menu.insertItem(item, at: baseIndex + offset)
                    presetMenuItems.append(item)
                }
            }
        }

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let hasPermission = CGPreflightScreenCaptureAccess()
        let symbol: String
        if !hasPermission || !hotkey.isRunning {
            symbol = "exclamationmark.triangle"
        } else if LiveTranslationManager.shared.isRunning {
            symbol = "waveform.badge.magnifyingglass"
        } else if RegionTranslationManager.shared.isRunning {
            symbol = "viewfinder"
        } else {
            symbol = "translate"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ReadIt")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func menuTranslate() {
        // 메뉴가 닫힌 뒤에 캡처해야 메뉴 UI가 스크린샷에 찍히지 않는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.triggerTranslation(mode: .standard) }
        }
    }

    @objc private func menuVerticalTranslate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.triggerTranslation(mode: .vertical) }
        }
    }

    @objc private func menuLiveTranslate() {
        triggerTranslation(mode: .live)
    }

    @objc private func menuRegionTranslate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.triggerTranslation(mode: .region) }
        }
    }

    @objc private func menuRegionRedraw() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                LiveTranslationManager.shared.stop()
                RegionTranslationManager.shared.start(preset: nil, forceSelection: true)
            }
        }
    }

    @objc private func menuSelectRegionPreset(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let preset = AppSettings.shared.regionPresets.first(where: { $0.id == id })
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                LiveTranslationManager.shared.stop()
                RegionTranslationManager.shared.applyPreset(preset)
            }
        }
    }

    @objc private func openPermissionSettings() {
        SettingsWindowController.shared.show(tab: .permissions)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(tab: .general)
    }

    @objc private func openLanguagePacks() {
        SettingsWindowController.shared.show(tab: .languages)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "로그인 항목 설정 실패", message: error.localizedDescription)
        }
        refreshMenuState()
    }

    @objc func checkForUpdates() {
        NSApp.activate()
        updaterController.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            NSApp.activate()
        }
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func startHotkey() {
        if hotkey.start() {
            retryTimer?.invalidate()
            retryTimer = nil
            refreshMenuState()
            return
        }
        refreshMenuState()
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startHotkey() }
        }
    }

    // MARK: - Pipeline: 캡처 → OCR → 문단 묶기 → 색 추출 → 번역

    func triggerTranslation(mode: TranslationMode = .standard) {
        if mode == .region {
            if let overlay {
                overlay.dismiss()
            }
            if LiveTranslationManager.shared.isRunning {
                LiveTranslationManager.shared.stop()
            }
            RegionTranslationManager.shared.toggle()
            return
        }

        if mode == .live {
            if let overlay {
                overlay.dismiss()
            }
            if RegionTranslationManager.shared.isRunning {
                RegionTranslationManager.shared.stop()
            }
            LiveTranslationManager.shared.toggle()
            return
        }

        // 일반 번역 실행 시 라이브/구역 모드가 켜져 있다면 먼저 중지
        if LiveTranslationManager.shared.isRunning {
            LiveTranslationManager.shared.stop()
        }
        if RegionTranslationManager.shared.isRunning {
            RegionTranslationManager.shared.stop()
        }

        // 오버레이가 이미 떠 있으면 토글하여 닫기
        if let overlay {
            overlay.dismiss()
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showAlert(title: "화면 기록 권한이 필요합니다", message: ReadItError.screenPermissionDenied.localizedDescription)
            return
        }

        pipeline?.cancel()
        pipeline = Task { [weak self] in
            await self?.runPipeline(mode: mode)
        }
    }

    private func runPipeline(mode: TranslationMode) async {
        let capture: CapturedScreen
        do {
            capture = try await ScreenCapturer.captureScreenUnderMouse()
        } catch {
            showAlert(title: "화면 캡처 실패", message: error.localizedDescription)
            return
        }
        if Task.isCancelled { return }

        let model = OverlayModel(image: capture.image, canvasSize: capture.screen.frame.size)
        let panel = OverlayPanel(screen: capture.screen, model: model) { [weak self] languages in
            self?.overlay?.dismiss()
            LanguagePackWindowController.shared.show(highlighting: languages)
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.overlay === panel {
                    self.overlay = nil
                    self.pipeline?.cancel()
                }
            }
        }
        overlay = panel
        panel.present()

        do {
            let screenFrame = capture.screen.frame
            let menuBarHeight: CGFloat = AppSettings.shared.includeMenuBar
                ? 0
                : max(24, screenFrame.maxY - capture.screen.visibleFrame.maxY)
            let isVerticalOnly = (mode == .vertical)
            let fullImage = capture.image
            let scale = model.scale

            if AppSettings.shared.processingMode == .serial {
                var lines = try await TextRecognizer.recognize(image: fullImage, canvasSize: model.canvasSize)
                if Task.isCancelled { return }

                if menuBarHeight > 0 {
                    lines = lines.filter { $0.rect.midY >= menuBarHeight }
                }

                let blocks = BlockBuilder.build(from: lines, verticalOnly: isVerticalOnly).filter { block in
                    guard let lang = block.language, lang != .korean else { return false }
                    guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                    return AppSettings.shared.isEnabled(code)
                }

                let overlayBlocks = await Task.detached(priority: .userInitiated) {
                    ColorSampler.makeOverlayBlocks(blocks, image: fullImage, scale: scale)
                }.value
                if Task.isCancelled { return }

                AppSettings.shared.recordSerialPipelineRun()
                if AppSettings.shared.shouldShowParallelTip {
                    model.showParallelTipBanner = true
                }

                model.setBlocks(overlayBlocks)
                guard !overlayBlocks.isEmpty else { return }

                await TranslationCoordinator().translate(into: model)
                return
            }

            let mouseGlobal = NSEvent.mouseLocation
            let cursorPoint = CGPoint(
                x: mouseGlobal.x - screenFrame.minX,
                y: screenFrame.maxY - mouseGlobal.y
            )

            let axis: SmartTileSlicer.Axis = isVerticalOnly ? .vertical : .horizontal
            let plan = SmartTileSlicer.makePlan(
                image: fullImage,
                canvasSize: model.canvasSize,
                axis: axis,
                tileCount: 4,
                topInset: menuBarHeight,
                cursorPoint: cursorPoint
            )

            let coordinator = TranslationCoordinator()
            var translationTasks: [Task<(missing: [Locale.Language], failures: [String]), Never>] = []
            var pendingLines: [RecognizedLine] = []
            var emittedLines: [RecognizedLine] = []
            var scannedTileIndices = Set<Int>()

            for tile in plan.tiles {
                if Task.isCancelled { return }
                guard let tileImage = SmartTileSlicer.cropImage(fullImage, to: tile.expandedRect, scale: scale) else {
                    scannedTileIndices.insert(tile.index)
                    continue
                }

                let rawLines = try await TextRecognizer.recognize(
                    image: tileImage,
                    canvasSize: tile.expandedRect.size
                )
                if Task.isCancelled { return }

                var offsetLines = rawLines.map { line in
                    RecognizedLine(
                        text: line.text,
                        rect: line.rect.offsetBy(dx: tile.expandedRect.minX, dy: tile.expandedRect.minY),
                        isVertical: line.isVertical
                    )
                }
                if menuBarHeight > 0 {
                    offsetLines = offsetLines.filter { $0.rect.midY >= menuBarHeight }
                }

                // 크롭 영역(expandedRect)의 인위적 절단선 끝(4pt 이내)에 걸려 잘린 불완전한 줄은 인접 타일 고유 영역에 온전히 존재하므로 제외
                offsetLines = offsetLines.filter { line in
                    switch axis {
                    case .horizontal:
                        if tile.hasLeadingCut,
                           line.rect.minY <= tile.expandedRect.minY + 4,
                           line.rect.maxY <= tile.coreRect.minY + 12 {
                            return false
                        }
                        if tile.hasTrailingCut,
                           line.rect.maxY >= tile.expandedRect.maxY - 4,
                           line.rect.minY >= tile.coreRect.maxY - 12 {
                            return false
                        }
                        return true
                    case .vertical:
                        if tile.hasLeadingCut,
                           line.rect.minX <= tile.expandedRect.minX + 4,
                           line.rect.maxX <= tile.coreRect.minX + 12 {
                            return false
                        }
                        if tile.hasTrailingCut,
                           line.rect.maxX >= tile.expandedRect.maxX - 4,
                           line.rect.minX >= tile.coreRect.maxX - 12 {
                            return false
                        }
                        return true
                    }
                }

                SmartTileSlicer.mergeRecognizedLines(
                    into: &pendingLines,
                    newLines: offsetLines,
                    emittedLines: emittedLines
                )
                scannedTileIndices.insert(tile.index)

                let unsealedCuts = plan.internalCuts.compactMap { cut -> CGFloat? in
                    let isSealed = scannedTileIndices.contains(cut.leadingTileIndex)
                        && scannedTileIndices.contains(cut.trailingTileIndex)
                    return isSealed ? nil : cut.position
                }

                let allCandidateBlocks = BlockBuilder.build(from: pendingLines, verticalOnly: isVerticalOnly)
                var heldBlocks: [TextBlock] = []
                var readyBlocks: [TextBlock] = []

                for block in allCandidateBlocks {
                    if SmartTileSlicer.touchesUnsealedCut(block: block, axis: axis, unsealedCuts: unsealedCuts) {
                        heldBlocks.append(block)
                    } else {
                        readyBlocks.append(block)
                    }
                }

                pendingLines = heldBlocks.flatMap(\.lines)
                emittedLines.append(contentsOf: readyBlocks.flatMap(\.lines))

                let filteredReadyBlocks = readyBlocks.filter { block in
                    guard let lang = block.language, lang != .korean else { return false }
                    guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                    return AppSettings.shared.isEnabled(code)
                }

                if filteredReadyBlocks.isEmpty { continue }

                let overlayBlocks = await Task.detached(priority: .userInitiated) {
                    ColorSampler.makeOverlayBlocks(filteredReadyBlocks, image: fullImage, scale: scale)
                }.value
                if Task.isCancelled { return }

                let addedBlocks = model.appendStreamedBlocks(overlayBlocks)
                if !addedBlocks.isEmpty {
                    let task = Task { @MainActor in
                        await coordinator.translateBlocks(addedBlocks, into: model)
                    }
                    translationTasks.append(task)
                }
            }

            if model.blocks.isEmpty {
                model.setBlocks([])
                return
            }

            var allMissing: [Locale.Language] = []
            var allFailures: [String] = []
            for task in translationTasks {
                if Task.isCancelled { return }
                let result = await task.value
                for lang in result.missing where !allMissing.contains(where: { $0.minimalIdentifier == lang.minimalIdentifier }) {
                    allMissing.append(lang)
                }
                allFailures.append(contentsOf: result.failures)
            }

            if Task.isCancelled { return }
            model.missingLanguages = allMissing
            model.finish(failures: allFailures)
        } catch {
            if Task.isCancelled { return }
            model.phase = .failed("텍스트 인식 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
