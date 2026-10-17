import Carbon
import Cocoa

/// Carbon EventHotKey API를 사용하여 시스템 프리즈 없이 100% 안전하게 동작하는 전역 단축키 모니터.
/// CGEventTap과 달리 키보드 이벤트를 차단/지연/재전송하지 않고,
/// OS 레벨에서 지정된 핫키 조합만 감지하므로 시스템 먹통(Freeze) 현상이 원천적으로 발생하지 않습니다.
/// 손쉬운 사용(Accessibility) 권한 없이도 모든 앱 위에서 안정적으로 작동합니다.
enum TranslationMode {
    case standard
    case vertical
}

final class HotkeyMonitor {
    var onTrigger: (@MainActor (TranslationMode) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    var isRunning: Bool { !hotKeyRefs.isEmpty }

    @discardableResult
    func start() -> Bool {
        guard hotKeyRefs.isEmpty else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }

            let mode: TranslationMode = (hotKeyID.id == 3) ? .vertical : .standard
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.onTrigger?(mode)
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return false }

        // 핫키 1: ⌃ + ⌥ + T (Control + Option + T)
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))

        // 핫키 2: ⌥ + 1 (Option + 1) - 기본 일반 번역
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))

        // 핫키 3: ⌥ + 2 (Option + 2) - 일본어 세로쓰기 전용 번역
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))

        return !hotKeyRefs.isEmpty
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: 0x4C43_4150, id: id) // 'LCAP'
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if regStatus == noErr, let ref {
            hotKeyRefs.append(ref)
        }
    }

    func stop() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        stop()
    }
}
