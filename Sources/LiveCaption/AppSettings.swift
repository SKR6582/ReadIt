import AppKit
import CoreGraphics
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

/// 화면 해상도나 전체화면 전환에도 구역 위치·크기가 유지되도록 0.0 ~ 1.0 비율로 정규화한 사각형
struct NormalizedRect: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = max(0, min(0.98, x))
        self.y = max(0, min(0.98, y))
        self.width = max(0.02, min(1.0 - self.x, width))
        self.height = max(0.02, min(1.0 - self.y, height))
    }

    init(rect: CGRect, canvasSize: CGSize) {
        let w = max(1, canvasSize.width)
        let h = max(1, canvasSize.height)
        let nx = max(0, min(0.98, rect.minX / w))
        let ny = max(0, min(0.98, rect.minY / h))
        let nw = max(0.02, min(1.0 - nx, rect.width / w))
        let nh = max(0.02, min(1.0 - ny, rect.height / h))
        self.x = nx
        self.y = ny
        self.width = nw
        self.height = nh
    }

    func toCanvasRect(in canvasSize: CGSize) -> CGRect {
        let raw = CGRect(
            x: x * canvasSize.width,
            y: y * canvasSize.height,
            width: width * canvasSize.width,
            height: height * canvasSize.height
        ).integral
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let clamped = raw.intersection(bounds)
        if clamped.width >= 32 && clamped.height >= 32 {
            return clamped
        }
        return CGRect(
            x: max(0, min(canvasSize.width - 120, raw.minX)),
            y: max(0, min(canvasSize.height - 80, raw.minY)),
            width: max(120, min(canvasSize.width, raw.width)),
            height: max(80, min(canvasSize.height, raw.height))
        ).integral
    }
}

/// ⌥4 구역 지정 번역 프리셋 및 마지막 구역 복원용 모델
struct RegionPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var displayID: UInt32
    var normalizedRect: NormalizedRect
    var isLive: Bool
    var isVerticalOnly: Bool
    var overrideLanguages: Set<String>? = nil
}

extension NSScreen {
    var readItDisplayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// 세션 간 및 모드(⌥3 / ⌥4) 간 공유되는 디스크 연동 LRU 번역 캐시
@MainActor
final class TranslationCacheStore {
    static let shared = TranslationCacheStore()

    private struct CacheEntry: Codable {
        let key: String
        let value: String
    }

    private let maxEntries = 2000
    private var dict: [String: String] = [:]
    private var order: [String] = []
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ReadIt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("translation_cache.json")
        loadFromDisk()
    }

    static func normalizeKey(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func lookup(_ sourceText: String) -> String? {
        if let exact = dict[sourceText] {
            return exact
        }
        let norm = Self.normalizeKey(sourceText)
        guard !norm.isEmpty else { return nil }
        return dict[norm]
    }

    func store(_ translated: String, for sourceText: String) {
        let norm = Self.normalizeKey(sourceText)
        guard !norm.isEmpty, !translated.isEmpty else { return }

        setEntry(key: sourceText, value: translated)
        if norm != sourceText {
            setEntry(key: norm, value: translated)
        }
        scheduleSave()
    }

    private func setEntry(key: String, value: String) {
        if dict[key] != nil {
            order.removeAll { $0 == key }
        }
        dict[key] = value
        order.append(key)

        while order.count > maxEntries {
            let oldest = order.removeFirst()
            dict.removeValue(forKey: oldest)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return }
        for entry in entries.suffix(maxEntries) {
            dict[entry.key] = entry.value
            order.append(entry.key)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.writeToDisk()
        }
    }

    private func writeToDisk() {
        let entries = order.compactMap { key -> CacheEntry? in
            guard let val = dict[key] else { return nil }
            return CacheEntry(key: key, value: val)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 사용자가 번역 대상으로 활성화한 언어 및 부가 옵션 설정 관리자 (UserDefaults 연동).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let maxRegionPresets = 5
    static let maxRecentCopiedTexts = 5

    private let userDefaultsKey = "ReadIt_EnabledLanguages"
    private let menuBarKey = "ReadIt_IncludeMenuBar"
    private let hudStyleKey = "ReadIt_OverlayHUDStyle"
    private let lastRegionKey = "ReadIt_LastRegionPreset_v1"
    private let regionPresetsKey = "ReadIt_RegionPresets_v1"
    private let recentCopiedKey = "ReadIt_RecentCopiedTexts_v1"

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

    /// ⌥4 마지막 사용 구역 (프로세스 종료 후에도 유지)
    @Published var lastRegionPreset: RegionPreset? {
        didSet {
            if let lastRegionPreset, let data = try? JSONEncoder().encode(lastRegionPreset) {
                UserDefaults.standard.set(data, forKey: lastRegionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastRegionKey)
            }
        }
    }

    /// ⌥4 이름 있는 구역 프리셋 목록 (최대 5개)
    @Published var regionPresets: [RegionPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(regionPresets) {
                UserDefaults.standard.set(data, forKey: regionPresetsKey)
            }
        }
    }

    /// 최근 복사한 번역 문장 내역 (최대 5개)
    @Published var recentCopiedTexts: [String] {
        didSet {
            UserDefaults.standard.set(recentCopiedTexts, forKey: recentCopiedKey)
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
            self.includeMenuBar = false
            UserDefaults.standard.set(false, forKey: menuBarKey)
        }

        if let rawStyle = UserDefaults.standard.string(forKey: hudStyleKey),
           let savedStyle = OverlayHUDStyle(rawValue: rawStyle) {
            self.hudStyle = savedStyle
        } else {
            self.hudStyle = .notch
            UserDefaults.standard.set(OverlayHUDStyle.notch.rawValue, forKey: hudStyleKey)
        }

        if let data = UserDefaults.standard.data(forKey: lastRegionKey),
           let decoded = try? JSONDecoder().decode(RegionPreset.self, from: data) {
            self.lastRegionPreset = decoded
        } else {
            self.lastRegionPreset = nil
        }

        if let data = UserDefaults.standard.data(forKey: regionPresetsKey),
           let decoded = try? JSONDecoder().decode([RegionPreset].self, from: data) {
            self.regionPresets = Array(decoded.prefix(Self.maxRegionPresets))
        } else {
            self.regionPresets = []
        }

        if let savedCopied = UserDefaults.standard.stringArray(forKey: recentCopiedKey) {
            self.recentCopiedTexts = Array(savedCopied.prefix(Self.maxRecentCopiedTexts))
        } else {
            self.recentCopiedTexts = []
        }
    }

    func saveLastRegion(
        rect: CGRect,
        canvasSize: CGSize,
        displayID: UInt32,
        isLive: Bool,
        isVerticalOnly: Bool,
        overrideLanguages: Set<String>? = nil,
        presetName: String = "마지막 구역"
    ) {
        let normalized = NormalizedRect(rect: rect, canvasSize: canvasSize)
        lastRegionPreset = RegionPreset(
            id: lastRegionPreset?.id ?? UUID(),
            name: presetName,
            displayID: displayID,
            normalizedRect: normalized,
            isLive: isLive,
            isVerticalOnly: isVerticalOnly,
            overrideLanguages: overrideLanguages
        )
    }

    @discardableResult
    func saveRegionPreset(
        name: String,
        rect: CGRect,
        canvasSize: CGSize,
        displayID: UInt32,
        isLive: Bool,
        isVerticalOnly: Bool,
        overrideLanguages: Set<String>? = nil
    ) -> RegionPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "구역 \(regionPresets.count + 1)" : trimmed
        let normalized = NormalizedRect(rect: rect, canvasSize: canvasSize)

        if let existingIdx = regionPresets.firstIndex(where: { $0.name == finalName }) {
            var updated = regionPresets[existingIdx]
            updated.displayID = displayID
            updated.normalizedRect = normalized
            updated.isLive = isLive
            updated.isVerticalOnly = isVerticalOnly
            updated.overrideLanguages = overrideLanguages
            regionPresets[existingIdx] = updated
            lastRegionPreset = updated
            return updated
        }

        let newPreset = RegionPreset(
            name: finalName,
            displayID: displayID,
            normalizedRect: normalized,
            isLive: isLive,
            isVerticalOnly: isVerticalOnly,
            overrideLanguages: overrideLanguages
        )
        var list = regionPresets
        if list.count >= Self.maxRegionPresets {
            list.removeFirst()
        }
        list.append(newPreset)
        regionPresets = list
        lastRegionPreset = newPreset
        return newPreset
    }

    func deleteRegionPreset(id: UUID) {
        regionPresets.removeAll { $0.id == id }
    }

    func recordCopiedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentCopiedTexts.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > Self.maxRecentCopiedTexts {
            list = Array(list.prefix(Self.maxRecentCopiedTexts))
        }
        recentCopiedTexts = list
    }

    func isEnabled(_ code: String, overrideLanguages: Set<String>? = nil) -> Bool {
        if let overrideLanguages, !overrideLanguages.isEmpty {
            return overrideLanguages.contains(code)
        }
        return enabledCodes.contains(code)
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
