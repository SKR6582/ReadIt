import AppKit
import ApplicationServices
import ServiceManagement

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private var overlay: OverlayPanel?
    private var pipeline: Task<Void, Never>?
    private var retryTimer: Timer?

    private let permissionWarningItem = NSMenuItem(title: "화면 기록 권한 필요 (설정 열기…)", action: #selector(openPermissionSettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: nil, keyEquivalent: "")
    private let notchHUDItem = NSMenuItem(title: "노치 통합 HUD 사용", action: #selector(toggleNotchHUD), keyEquivalent: "")
    private let liveTranslateItem = NSMenuItem(title: "실시간 라이브 번역", action: #selector(menuLiveTranslate), keyEquivalent: "3")
    private let regionTranslateItem = NSMenuItem(title: "구역 지정 번역", action: #selector(menuRegionTranslate), keyEquivalent: "4")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hotkey.onTrigger = { [weak self] mode in self?.triggerTranslation(mode: mode) }
        LiveTranslationManager.shared.onStateChanged = { [weak self] _ in self?.refreshMenuState() }
        RegionTranslationManager.shared.onStateChanged = { [weak self] _ in self?.refreshMenuState() }
        requestPermissionsIfNeeded()
        startHotkey()
        TextRecognizer.warmUp()

        // 시작 후 백그라운드에서 업데이트 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            GitHubUpdater.shared.checkForUpdates(isUserInitiated: false)
        }
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
        menu.addItem(.separator())

        // 3. 언어 팩 및 기본 환경설정
        let packItem = NSMenuItem(title: "번역 언어 팩 설정…", action: #selector(openLanguagePacks), keyEquivalent: ",")
        packItem.keyEquivalentModifierMask = [.command]
        packItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        packItem.target = self
        menu.addItem(packItem)

        notchHUDItem.target = self
        notchHUDItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        menu.addItem(notchHUDItem)

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

        notchHUDItem.state = AppSettings.shared.hudStyle == .notch ? .on : .off
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

    @objc private func openPermissionSettings() {
        let screen = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: screen) { NSWorkspace.shared.open(url) }
    }

    @objc private func openLanguagePacks() {
        LanguagePackWindowController.shared.show()
    }

    @objc private func toggleNotchHUD() {
        AppSettings.shared.hudStyle = (AppSettings.shared.hudStyle == .notch) ? .floating : .notch
        refreshMenuState()
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

    @objc private func checkForUpdates() {
        GitHubUpdater.shared.checkForUpdates(isUserInitiated: true)
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
            var lines = try await TextRecognizer.recognize(image: capture.image, canvasSize: model.canvasSize)
            if Task.isCancelled { return }

            // 메뉴 막대 번역에 포함하지 않는 경우, 화면 최상단 메뉴 막대 영역의 텍스트 제외
            if !AppSettings.shared.includeMenuBar {
                let menuBarHeight = max(24, capture.screen.frame.maxY - capture.screen.visibleFrame.maxY)
                lines = lines.filter { line in
                    line.rect.midY >= menuBarHeight
                }
            }

            // 모드에 따라 블록 생성 (vertical 모드는 세로쓰기 문단만 집중 번역)
            let isVerticalOnly = (mode == .vertical)
            let blocks = BlockBuilder.build(from: lines, verticalOnly: isVerticalOnly).filter { block in
                guard let lang = block.language else { return false }
                guard lang != .korean else { return false }
                guard let code = AppSettings.nlLanguageToCode[lang] else { return false }
                return AppSettings.shared.isEnabled(code)
            }

            let image = capture.image
            let scale = model.scale
            let overlayBlocks = await Task.detached(priority: .userInitiated) {
                ColorSampler.makeOverlayBlocks(blocks, image: image, scale: scale)
            }.value
            if Task.isCancelled { return }

            model.setBlocks(overlayBlocks)
            guard !overlayBlocks.isEmpty else { return }

            await TranslationCoordinator().translate(into: model)
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
