import Cocoa
import ScreenCaptureKit

enum ReadItError: LocalizedError {
    case screenNotFound
    case screenPermissionDenied
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenNotFound:
            return "캡처할 디스플레이를 찾지 못했어요."
        case .screenPermissionDenied:
            let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "ReadIt"
            return "화면 기록 권한이 필요해요. 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 기록에서 \(appName)을 허용한 뒤 앱을 다시 실행해 주세요."
        case .captureFailed(let message):
            return "화면 캡처 실패: \(message)"
        }
    }
}

struct CapturedScreen {
    let image: CGImage
    let screen: NSScreen
}

@MainActor
enum ScreenCapturer {
    /// 마우스 커서가 있는 디스플레이 전체를 캡처한다 (ReadIt 자신의 창은 제외).
    static func captureScreenUnderMouse() async throws -> CapturedScreen {
        try await capture(screen: nil)
    }

    /// 지정된 디스플레이(없으면 마우스 커서 위치 디스플레이) 전체를 캡처한다 (ReadIt 자신의 창은 제외).
    static func capture(screen preferredScreen: NSScreen? = nil) async throws -> CapturedScreen {
        let mouse = NSEvent.mouseLocation
        let resolvedScreen = preferredScreen
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let screen = resolvedScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw ReadItError.screenNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw ReadItError.screenPermissionDenied }
            throw ReadItError.captureFailed(error.localizedDescription)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ReadItError.screenNotFound
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CapturedScreen(image: image, screen: screen)
        } catch {
            throw ReadItError.captureFailed(error.localizedDescription)
        }
    }
}
