import AppKit
import SwiftUI
import Translation

/// 언어 팩(→ 한국어) 다운로드 창 관리자.
/// macOS 시스템 설정(System Settings) 순정 디자인 스타일 및 메뉴 막대 포함 옵션, 번역 언어 토글 기능을 제공합니다.
@MainActor
final class LanguagePackWindowController: NSObject, NSWindowDelegate {
    static let shared = LanguagePackWindowController()

    static let allLanguages: [Locale.Language] = [
        "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt",
        "ru", "uk", "vi", "th", "id", "nl", "pl", "tr", "ar", "hi",
    ].map { Locale.Language(identifier: $0) }

    private var window: NSWindow?

    func show(highlighting languages: [Locale.Language] = []) {
        // 시스템 번역 다운로드 다이얼로그가 정상 팝업되도록 일반 앱 모드로 전환
        NSApp.setActivationPolicy(.regular)

        let ordered = languages + Self.allLanguages.filter { lang in
            !languages.contains { $0.minimalIdentifier == lang.minimalIdentifier }
        }
        let view = LanguagePackView(
            languages: ordered,
            highlighted: Set(languages.map(\.minimalIdentifier)),
            autoDownload: languages.first,
            onClose: { [weak self] in self?.window?.close() }
        )
        let controller = NSHostingController(rootView: view)

        if let existing = window {
            existing.contentViewController = controller
        } else {
            let win = NSWindow(contentViewController: controller)
            win.title = "번역 환경설정"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            win.isReleasedWhenClosed = false
            win.delegate = self
            self.window = win
        }

        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 창이 닫히면 다시 메뉴 막대 전용 앱으로 복원
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Language Pack & Settings View

struct LanguagePackView: View {
    let languages: [Locale.Language]
    let highlighted: Set<String>
    let autoDownload: Locale.Language?
    var onClose: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    @State private var configuration: TranslationSession.Configuration?
    @State private var downloading: String?
    @State private var errorText: String?
    @State private var isRefreshing = false

    @State private var searchText = ""
    @State private var selectedFilter: FilterOption = .all

    private let target = TranslationCoordinator.targetLanguage

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "모든 언어"
        case enabledOnly = "번역 켜짐"
        case installed = "설치됨"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 상단 macOS 네이티브 스타일 헤더
            headerView
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)

            // 설정 옵션 카드: 메뉴 막대 번역에 포함하기
            optionsSection
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            // 안내 팁 배너
            tipBanner
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            // 검색 및 필터 세그먼트 바
            filterBar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            // 언어 카드 목록
            ScrollView {
                VStack(spacing: 8) {
                    if filteredLanguages.isEmpty {
                        emptySearchResultView
                    } else {
                        ForEach(filteredLanguages, id: \.minimalIdentifier) { language in
                            let id = language.minimalIdentifier
                            LanguageRowView(
                                language: language,
                                status: statuses[id],
                                isEnabled: Binding(
                                    get: { settings.isEnabled(id) },
                                    set: { newValue in settings.setEnabled(id, enabled: newValue) }
                                ),
                                isHighlighted: highlighted.contains(id),
                                isDownloading: downloading == id,
                                onDownload: { download(language) }
                            )
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic)

            Divider()

            // 하단 푸터 및 시스템 설정 연동 안내
            footerView
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 550, height: 690)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await refresh()
            if let autoDownload, statuses[autoDownload.minimalIdentifier] == .supported {
                download(autoDownload)
            }
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                _ = try await session.translate("Hello")
                errorText = nil
            } catch {
                let desc = error.localizedDescription
                if !desc.contains("cancelled") {
                    errorText = "다운로드 안내: \(desc)\n팝업이 표시되지 않는 경우 아래 '시스템 설정'에서 직접 내려받으실 수 있습니다."
                }
            }
            downloading = nil
            configuration = nil
            await refresh()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "translate")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("번역 환경설정")
                    .font(.system(size: 19, weight: .bold))
                Text("번역에 사용할 언어와 화면 캡처 옵션을 설정합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("완료", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
        }
    }

    // MARK: - Options Section (UI 스타일 전환 및 메뉴 막대 포함 토글)

    private var optionsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "menubar.dock.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("메뉴 막대 영역 번역에 포함")
                        .font(.system(size: 12, weight: .semibold))
                    Text("화면 최상단 메뉴 막대(Apple 메뉴, File, Edit, 시계 등)의 텍스트도 번역합니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $settings.includeMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
            )

            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("오버레이 컨트롤 UI 스타일")
                        .font(.system(size: 12, weight: .semibold))
                    Text("기본 노치(Notch) 통합 HUD 대신 플로팅 캡슐 바를 사용하려면 변경하세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $settings.hudStyle) {
                    ForEach(OverlayHUDStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
            )
        }
    }

    // MARK: - Tip Banner

    private var tipBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
            Text("자주 읽는 언어(예: 영어, 일본어)만 켜두면, 짧은 영단어가 스페인어나 튀르키예어로 잘못 인식되는 현상이 방지됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Filter & Search Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            // 네이티브 검색창
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("언어 검색…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                    )
            )

            // 세그먼트 필터
            Picker("", selection: $selectedFilter) {
                ForEach(FilterOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    // MARK: - Filtered Languages Logic

    private var filteredLanguages: [Locale.Language] {
        languages.filter { lang in
            let id = lang.minimalIdentifier
            let name = TranslationCoordinator.displayName(of: lang)

            let matchesSearch = searchText.isEmpty ||
                name.localizedCaseInsensitiveContains(searchText) ||
                id.localizedCaseInsensitiveContains(searchText)

            guard matchesSearch else { return false }

            switch selectedFilter {
            case .all:
                return true
            case .enabledOnly:
                return settings.isEnabled(id)
            case .installed:
                return statuses[id] == .installed
            }
        }
    }

    // MARK: - Empty State

    private var emptySearchResultView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)
            Text("일치하는 언어가 없습니다")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
            }

            HStack {
                Button {
                    openSystemLocalizationSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                        Text("시스템 설정에서 번역 언어 관리")
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)

                Spacer()

                HStack(spacing: 12) {
                    Text("켜진 언어: \(settings.enabledCodes.count)개")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("새로고침")
                        }
                        .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .disabled(isRefreshing)
                }
            }
        }
    }

    // MARK: - Actions

    private func download(_ language: Locale.Language) {
        let id = language.minimalIdentifier
        downloading = id
        settings.setEnabled(id, enabled: true)
        errorText = nil
        configuration = nil
        Task { @MainActor in
            configuration = TranslationSession.Configuration(source: language, target: target)
        }
    }

    private func refresh() async {
        isRefreshing = true
        let availability = LanguageAvailability()
        for language in languages {
            statuses[language.minimalIdentifier] = await availability.status(from: language, to: target)
        }
        isRefreshing = false
    }

    private func openSystemLocalizationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Native Language Row View with Toggle

private struct LanguageRowView: View {
    let language: Locale.Language
    let status: LanguageAvailability.Status?
    @Binding var isEnabled: Bool
    let isHighlighted: Bool
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        let id = language.minimalIdentifier
        HStack(spacing: 12) {
            // 번역 사용 여부 토글 스위치
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(isEnabled ? "번역 대상에서 제외하려면 클릭" : "화면 번역 대상으로 활성화하려면 클릭")

            // 국기 이모지 배지
            Text(flagEmoji(for: id))
                .font(.system(size: 22))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.04)))

            // 언어 정보
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TranslationCoordinator.displayName(of: language))
                        .font(.system(size: 13, weight: isEnabled ? .semibold : .regular))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    Text("(\(nativeLanguageName(for: id)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text("\(id) → ko")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text(isEnabled ? "번역 활성화됨" : "번역 꺼짐")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                }
            }

            Spacer()

            // 다운로드 상태 및 액션 버튼
            actionArea(for: id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isEnabled
                        ? (isHighlighted ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                        : Color.primary.opacity(0.02)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isHighlighted ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06),
                            lineWidth: 0.8
                        )
                )
        )
    }

    @ViewBuilder
    private func actionArea(for id: String) -> some View {
        switch status {
        case .installed:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                Text("설치됨")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1), in: Capsule())

        case .supported:
            if isDownloading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("다운로드 중…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
            } else {
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 11))
                        Text("받기")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

        case .unsupported:
            Text("미지원")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

        default:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func flagEmoji(for identifier: String) -> String {
        switch identifier.lowercased() {
        case "en", "en-us": return "🇺🇸"
        case "ja": return "🇯🇵"
        case "zh-hans", "zh": return "🇨🇳"
        case "zh-hant": return "🇹🇼"
        case "fr": return "🇫🇷"
        case "de": return "🇩🇪"
        case "es": return "🇪🇸"
        case "it": return "🇮🇹"
        case "pt", "pt-br": return "🇧🇷"
        case "ru": return "🇷🇺"
        case "uk": return "🇺🇦"
        case "vi": return "🇻🇳"
        case "th": return "🇹🇭"
        case "id": return "🇮🇩"
        case "nl": return "🇳🇱"
        case "pl": return "🇵🇱"
        case "tr": return "🇹🇷"
        case "ar": return "🇸🇦"
        case "hi": return "🇮🇳"
        default: return "🌐"
        }
    }

    private func nativeLanguageName(for identifier: String) -> String {
        switch identifier.lowercased() {
        case "en": return "English"
        case "ja": return "日本語"
        case "zh-hans": return "简体中文"
        case "zh-hant": return "繁體中文"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "es": return "Español"
        case "it": return "Italiano"
        case "pt": return "Português"
        case "ru": return "Русский"
        case "uk": return "Українська"
        case "vi": return "Tiếng Việt"
        case "th": return "ไทย"
        case "id": return "Bahasa Indonesia"
        case "nl": return "Nederlands"
        case "pl": return "Polski"
        case "tr": return "Türkçe"
        case "ar": return "العربية"
        case "hi": return "हिन्दी"
        default: return identifier
        }
    }
}
