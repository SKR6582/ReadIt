import Foundation
import NaturalLanguage

enum OverlayHUDStyle: String, CaseIterable, Identifiable {
    case floating = "floating"
    case notch = "notch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floating: return "플로팅 캡슐 (기본)"
        case .notch: return "노치 통합 HUD"
        }
    }
}

/// 사용자가 번역 대상으로 활성화한 언어 및 부가 옵션 설정 관리자 (UserDefaults 연동).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let userDefaultsKey = "ReadIt_EnabledLanguages"
    private let menuBarKey = "ReadIt_IncludeMenuBar"
    private let hudStyleKey = "ReadIt_OverlayHUDStyle"

    /// 기본적으로 자주 쓰이는 언어 (영어, 일본어, 중국어 간체, 중국어 번체)
    static let defaultEnabledCodes: Set<String> = [
        "en", "ja", "zh-Hans", "zh-Hant"
    ]

    @Published var enabledCodes: Set<String> {
        didSet {
            save()
        }
    }

    /// 화면 최상단 메뉴 막대 영역도 번역 대상에 포함할지 여부
    @Published var includeMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(includeMenuBar, forKey: menuBarKey)
        }
    }

    /// 오버레이 상단 컨트롤 UI 스타일 (플로팅 캡슐 vs 노치 통합 HUD)
    @Published var hudStyle: OverlayHUDStyle {
        didSet {
            UserDefaults.standard.set(hudStyle.rawValue, forKey: hudStyleKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] {
            self.enabledCodes = Set(saved)
        } else {
            self.enabledCodes = Self.defaultEnabledCodes
            UserDefaults.standard.set(Array(Self.defaultEnabledCodes), forKey: userDefaultsKey)
        }

        if UserDefaults.standard.object(forKey: menuBarKey) != nil {
            self.includeMenuBar = UserDefaults.standard.bool(forKey: menuBarKey)
        } else {
            // 기본값은 메뉴 막대 제외 (false)
            self.includeMenuBar = false
            UserDefaults.standard.set(false, forKey: menuBarKey)
        }

        if let rawStyle = UserDefaults.standard.string(forKey: hudStyleKey),
           let savedStyle = OverlayHUDStyle(rawValue: rawStyle) {
            self.hudStyle = savedStyle
        } else {
            // 노치 통합 UI 비교를 바로 체험할 수 있도록 기본값은 .notch로 설정하되 언제든 전환 가능
            self.hudStyle = .notch
            UserDefaults.standard.set(OverlayHUDStyle.notch.rawValue, forKey: hudStyleKey)
        }
    }

    func isEnabled(_ code: String) -> Bool {
        enabledCodes.contains(code)
    }

    func setEnabled(_ code: String, enabled: Bool) {
        if enabled {
            enabledCodes.insert(code)
        } else {
            enabledCodes.remove(code)
        }
    }

    func toggle(_ code: String) {
        if enabledCodes.contains(code) {
            enabledCodes.remove(code)
        } else {
            enabledCodes.insert(code)
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(enabledCodes), forKey: userDefaultsKey)
    }

    /// 활성화된 NLLanguage 목록 (언어 감지 제약 조건용)
    var activeNLLanguages: [NLLanguage] {
        var langs: [NLLanguage] = [.korean] // 한국어는 번역 제외 판정용으로 항상 포함
        for code in enabledCodes {
            if let nl = Self.codeToNLLanguage[code] {
                langs.append(nl)
            }
        }
        return langs
    }

    static let codeToNLLanguage: [String: NLLanguage] = [
        "en": .english,
        "ja": .japanese,
        "zh-Hans": .simplifiedChinese,
        "zh-Hant": .traditionalChinese,
        "fr": .french,
        "de": .german,
        "es": .spanish,
        "it": .italian,
        "pt": .portuguese,
        "ru": .russian,
        "uk": .ukrainian,
        "vi": .vietnamese,
        "th": .thai,
        "id": .indonesian,
        "nl": .dutch,
        "pl": .polish,
        "tr": .turkish,
        "ar": .arabic,
        "hi": .hindi,
    ]

    static let nlLanguageToCode: [NLLanguage: String] = {
        var dict: [NLLanguage: String] = [:]
        for (code, nl) in codeToNLLanguage {
            dict[nl] = code
        }
        return dict
    }()
}
