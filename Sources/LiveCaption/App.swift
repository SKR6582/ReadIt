import AppKit
import ApplicationServices
import ServiceManagement

@main
struct LiveCaptionMain {
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

    private let hotkeyStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let screenStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hotkey.onTrigger = { [weak self] in self?.triggerTranslation() }
        requestPermissionsIfNeeded()
        startHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
    }

    // MARK: - Status item / menu (macOS 순정 시스템 메뉴 스타일)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        // 1. 번역 실행
        let translateItem = NSMenuItem(title: "화면 실시간 번역", action: #selector(menuTranslate), keyEquivalent: "t")
        translateItem.keyEquivalentModifierMask = [.control, .option]
        translateItem.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "번역")
        translateItem.target = self
        menu.addItem(translateItem)
        menu.addItem(.separator())

        // 2. 단축키 및 권한 상태 표시
        hotkeyStateItem.isEnabled = false
        screenStateItem.isEnabled = false
        menu.addItem(hotkeyStateItem)
        menu.addItem(screenStateItem)

        let permissionItem = NSMenuItem(title: "화면 기록 권한 설정 열기…", action: #selector(openPermissionSettings), keyEquivalent: "")
        permissionItem.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        // 3. 언어 팩 및 기본 환경설정
        let packItem = NSMenuItem(title: "번역 언어 팩 설정…", action: #selector(openLanguagePacks), keyEquivalent: ",")
        packItem.keyEquivalentModifierMask = [.command]
        packItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        packItem.target = self
        menu.addItem(packItem)

        loginItem.action = #selector(toggleLoginItem)
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        // 4. 앱 종료
        let quitItem = NSMenuItem(title: "LiveCaption 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        hotkeyStateItem.title = hotkey.isRunning
            ? "단축키: ⌃⌥T 또는 ⌥1"
            : "단축키 등록 실패"
        hotkeyStateItem.image = NSImage(
            systemSymbolName: hotkey.isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )

        let screenAccess = CGPreflightScreenCaptureAccess()
        screenStateItem.title = screenAccess
            ? "화면 기록 권한 허용됨"
            : "화면 기록 권한 필요"
        screenStateItem.image = NSImage(
            systemSymbolName: screenAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol = hotkey.isRunning ? "translate" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LiveCaption")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func menuTranslate() {
        // 메뉴가 닫힌 뒤에 캡처해야 메뉴 UI가 스크린샷에 찍히지 않는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.triggerTranslation() }
        }
    }

    @objc private func openPermissionSettings() {
        let screen = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: screen) { NSWorkspace.shared.open(url) }
    }

    @objc private func openLanguagePacks() {
        LanguagePackWindowController.shared.show()
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

    func triggerTranslation() {
        // 오버레이가 이미 떠 있으면 토글하여 닫기
        if let overlay {
            overlay.dismiss()
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showAlert(title: "화면 기록 권한이 필요합니다", message: LiveCaptionError.screenPermissionDenied.localizedDescription)
            return
        }

        pipeline?.cancel()
        pipeline = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    private func runPipeline() async {
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

            // 한국어가 아니면서, 사용자가 설정에서 활성화한 언어의 블록만 번역 파이프라인으로 전달
            let blocks = BlockBuilder.build(from: lines).filter { block in
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
