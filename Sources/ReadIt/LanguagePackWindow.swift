import AppKit
import SwiftUI
import Translation
import ServiceManagement

/// 설정 창 탭 구분 (macOS 네이티브 사이드바 항목)
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "일반 설정"
    case processing = "처리 모드"
    case languages = "번역팩 관리"
    case shortcuts = "단축키"
    case permissions = "시스템 권한"
    case about = "앱 정보"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape.2"
        case .processing: return "cpu"
        case .languages: return "character.book.closed"
        case .shortcuts: return "command.square"
        case .permissions: return "shield.lefthalf.filled"
        case .about: return "info.circle"
        }
    }

    var sectionHeader: String? {
        switch self {
        case .general: return nil
        case .processing: return "번역 엔진"
        case .languages: return nil
        case .shortcuts: return "단축키 및 조작"
        case .permissions: return "시스템"
        case .about: return nil
        }
    }
}

/// 설정 창 전역 상태 뷰모델
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab
    @Published var highlightedCodes: Set<String>
    @Published var isScreenCaptureGranted: Bool = false
    @Published var isAccessibilityGranted: Bool = false

    let languages: [Locale.Language]

    init(
        languages: [Locale.Language],
        highlighted: Set<String> = [],
        initialTab: SettingsTab = .general
    ) {
        self.languages = languages
        self.highlightedCodes = highlighted
        self.selectedTab = initialTab
        refreshPermissionStates()
    }

    func refreshPermissionStates() {
        self.isScreenCaptureGranted = CGPreflightScreenCaptureAccess()
        self.isAccessibilityGranted = AXIsProcessTrusted()
    }
}

/// 설정 창 관리자 (macOS 사이드바 기반 네이티브 창)
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    static let allLanguages: [Locale.Language] = [
        "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt",
        "ru", "uk", "vi", "th", "id", "nl", "pl", "tr", "ar", "hi",
    ].map { Locale.Language(identifier: $0) }

    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    func show(tab: SettingsTab = .general, highlighting: [Locale.Language] = []) {
        NSApp.setActivationPolicy(.regular)

        let ordered = highlighting + Self.allLanguages.filter { lang in
            !highlighting.contains { $0.minimalIdentifier == lang.minimalIdentifier }
        }

        let vm: SettingsViewModel
        if let existing = viewModel {
            vm = existing
            vm.selectedTab = tab
            if !highlighting.isEmpty {
                vm.highlightedCodes = Set(highlighting.map(\.minimalIdentifier))
            }
            vm.refreshPermissionStates()
        } else {
            vm = SettingsViewModel(
                languages: ordered,
                highlighted: Set(highlighting.map(\.minimalIdentifier)),
                initialTab: tab
            )
            self.viewModel = vm
        }

        let view = SettingsRootLayoutView(viewModel: vm)
        let controller = NSHostingController(rootView: view)

        if let existing = window {
            existing.contentViewController = controller
            existing.setContentSize(NSSize(width: 860, height: 600))
        } else {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.contentViewController = controller
            win.title = "ReadIt 환경설정"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 860, height: 600))
            win.minSize = NSSize(width: 780, height: 520)
            win.delegate = self
            self.window = win
        }

        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 기존 LanguagePackWindowController 호출 호환 브릿지
@MainActor
final class LanguagePackWindowController {
    static let shared = LanguagePackWindowController()

    func show(highlighting languages: [Locale.Language] = []) {
        SettingsWindowController.shared.show(
            tab: languages.isEmpty ? .general : .languages,
            highlighting: languages
        )
    }
}

// MARK: - Root Layout View: Sidebar + Detail (Image 2 Native Style)

struct SettingsRootLayoutView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: 0) {
            // 좌측 사이드바
            SettingsSidebarView(selectedTab: $viewModel.selectedTab)
                .frame(width: 220)

            Divider()

            // 우측 디테일 뷰
            SettingsDetailHostView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.13, green: 0.14, blue: 0.17))
        }
        .frame(minWidth: 780, idealWidth: 860, maxWidth: .infinity, minHeight: 520, idealHeight: 600, maxHeight: .infinity)
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
    }
}

// MARK: - Sidebar View

struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            // 상단 윈도우 신호등 공간 확보 및 헤더
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 38) // macOS 트래픽 라이트 버튼 높이

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(SettingsTab.allCases) { tab in
                            if let header = tab.sectionHeader {
                                Text(header)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.secondary.opacity(0.8))
                                    .padding(.horizontal, 14)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                            }

                            sidebarRow(for: tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)

            Divider()

            // 하단 툴바 버튼 영역 (전원, 도움말, 설정)
            sidebarBottomBar
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color(red: 0.20, green: 0.47, blue: 0.96) : Color(white: 0.70))
                    .frame(width: 18)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color(white: 0.85))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var sidebarBottomBar: some View {
        HStack {
            // 종료 버튼만 유지하고 Quit 레이블 적용
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color(white: 0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .help("ReadIt 종료 (Quit)")

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Detail Host View

struct SettingsDetailHostView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch viewModel.selectedTab {
                case .general:
                    SettingsGeneralDetailView()
                case .processing:
                    SettingsProcessingDetailView()
                case .languages:
                    SettingsLanguagesDetailView(
                        languages: viewModel.languages,
                        highlighted: viewModel.highlightedCodes
                    )
                case .shortcuts:
                    SettingsShortcutsDetailView()
                case .permissions:
                    SettingsPermissionsDetailView(viewModel: viewModel)
                case .about:
                    SettingsAboutDetailView()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
    }
}

// MARK: - Detail View 1: 일반 설정

struct SettingsGeneralDetailView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("일반 설정")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("화면 캡처 영역과 시작 옵션 등 기본 동작을 구성합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            // 메뉴 막대 포함 여부
            NativeSettingRow(
                icon: "menubar.dock.rectangle",
                title: "메뉴 막대 영역 번역에 포함",
                tooltip: "화면 최상단 메뉴 막대(Apple 메뉴, 활성 앱 메뉴, 시계 등)의 텍스트도 번역 대상에 포함합니다."
            ) {
                Toggle("", isOn: $settings.includeMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            // 오버레이 스타일
            NativeSettingRow(
                icon: "macwindow",
                title: "오버레이 컨트롤 스타일",
                tooltip: "화면 상단 노치 영역에 일체형으로 통합되어 방해 없이 동작합니다."
            ) {
                Text("노치 통합 HUD (고정)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

            // 로그인 시 자동 실행
            NativeSettingRow(
                icon: "arrow.clockwise",
                title: "로그인 시 자동 실행",
                tooltip: "Mac 시동 시 백그라운드 메뉴 막대에서 ReadIt을 실행합니다."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isLaunchAtLoginEnabled },
                    set: { settings.isLaunchAtLoginEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            // 하위 안내 서브 카드
            NativeSubCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                        Text("메뉴 막대 실행 안내")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                    Text("ReadIt은 상단 메뉴 막대 상주 앱입니다. 독(Dock) 아이콘 없이 메뉴 막대 트레이 아이콘 및 전역 단축키를 통해 언제든 즉시 호출할 수 있습니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

// MARK: - Detail View 2: 번역 처리 모드

struct SettingsProcessingDetailView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("번역 처리 모드")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("OCR 인식 및 번역 파이프라인의 직렬/병렬 스트리밍 방식을 설정합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            // 파이프라인 처리 방식 Row
            NativeSettingRow(
                icon: "bolt.horizontal.fill",
                title: "스트리밍 파이프라인 모드",
                tooltip: "직렬은 문단을 안정적으로 결합하고, 병렬은 모든 타일을 동시 스트리밍합니다."
            ) {
                Picker("", selection: $settings.processingMode) {
                    ForEach(TranslationProcessingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }

            // TIP 안내 서브 카드
            NativeSubCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.18))
                        Text("TIP")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.18))
                        Spacer()
                        if settings.processingMode == .serial {
                            Button {
                                settings.enableParallelModeFromTip()
                            } label: {
                                Text("병렬 처리 켜기")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.18))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(Color(red: 1.0, green: 0.74, blue: 0.18).opacity(0.18))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(
                        settings.processingMode == .serial
                            ? "기본 '직렬 처리(번역만)'는 전체 화면 글자를 한 번에 인식해 긴 문단 유지에 유리합니다. 첫 번역이 뜨는 체감 속도를 더 높이고 싶다면 '병렬 처리(전부 스트리밍)'를 선택해 보세요."
                            : "현재 '병렬 처리(전부 스트리밍)'가 켜져 있어 마우스 커서 주변 타일부터 OCR과 번역이 동시에 스트리밍됩니다. 자주 읽는 언어만 켜두면 짧은 단어 오인식도 함께 줄어듭니다."
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondary)
                }
            }

            // 파이프라인 다이어그램 서브 카드 (Image 2의 배터리 보정 단계 스타일)
            NativeSubCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                        Text("파이프라인 실행 단계")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        pipelineStepCard(icon: "camera.viewfinder", step: "1단계", label: "화면 캡처", desc: "메탈 최적화")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                        pipelineStepCard(icon: "character.cursor.ibeam", step: "2단계", label: "Vision OCR", desc: "고속 텍스트 인식")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                        pipelineStepCard(icon: "text.bubble.fill", step: "3단계", label: "Apple 번역", desc: "온디바이스 번역")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                        pipelineStepCard(icon: "macwindow.on.rectangle", step: "4단계", label: "오버레이", desc: "원문 매칭 렌더링")
                    }
                }
            }
        }
    }

    private func pipelineStepCard(icon: String, step: String, label: String, desc: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                .frame(height: 22)

            Text(step)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.secondary)

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)

            Text(desc)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Detail View 3: 번역팩 관리

struct SettingsLanguagesDetailView: View {
    let languages: [Locale.Language]
    let highlighted: Set<String>

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
        VStack(alignment: .leading, spacing: 18) {
            // 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("번역팩 관리")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("화면 텍스트를 감지하여 한국어로 번역할 언어 팩을 활성화하거나 다운로드합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            // 상단 검색 & 필터
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    TextField("언어 검색…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.17, green: 0.18, blue: 0.22))
                )

                Picker("", selection: $selectedFilter) {
                    ForEach(FilterOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            // 언어 카드 목록
            VStack(spacing: 8) {
                ForEach(filteredLanguages, id: \.minimalIdentifier) { language in
                    let id = language.minimalIdentifier
                    LanguageRowView(
                        language: language,
                        status: statuses[id],
                        isEnabled: Binding(
                            get: { settings.isEnabled(id) },
                            set: { settings.setEnabled(id, enabled: $0) }
                        ),
                        isHighlighted: highlighted.contains(id),
                        isDownloading: downloading == id,
                        onDownload: { download(language) }
                    )
                }

                if filteredLanguages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .padding(.top, 30)
                        Text("일치하는 언어가 없습니다")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // 하단 상태 정보 & 시스템 설정 바로가기
            NativeSubCard {
                HStack {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape")
                            Text("시스템 설정에서 번역 언어 관리")
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("켜진 언어: \(settings.enabledCodes.count)개")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)

                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("새로고침")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            await refresh()
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
}

// MARK: - Detail View 4: 단축키 안내

struct SettingsShortcutsDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("전역 단축키")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("다른 앱을 사용하는 중에도 언제든 즉시 번역을 실행할 수 있는 키보드 단축키입니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            VStack(spacing: 8) {
                shortcutRow(keys: "⌥1", desc: "화면 전체 번역 (가로 읽기)", icon: "text.alignleft")
                shortcutRow(keys: "⌥2", desc: "세로 읽기 번역 (만화, 세로쓰기 문서)", icon: "text.aligncenter")
                shortcutRow(keys: "⌥3", desc: "실시간 라이브 번역 (스크롤 추적)", icon: "arrow.up.and.down.circle")
                shortcutRow(keys: "⌥4", desc: "구역 지정 번역 (사각형 드래그 선택)", icon: "rectangle.dashed")
                shortcutRow(keys: "⌥ (길게 누름)", desc: "번역 오버레이 원문 임시 보기", icon: "eye")
                shortcutRow(keys: "ESC", desc: "활성화된 번역 오버레이 닫기", icon: "xmark.circle")
            }

            NativeSubCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                        Text("단축키 동작 팁")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                    Text("웹페이지를 스크롤하며 연속으로 읽을 때는 ⌥3(실시간 라이브 번역) 또는 ⌥4(구역 지정 후 라이브 모드)를 사용하면 텍스트가 이동해도 번역 레이어가 부드럽게 따라옵니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func shortcutRow(keys: String, desc: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                .frame(width: 20)

            Text(desc)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white)

            Spacer()

            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.95))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.20, green: 0.22, blue: 0.26))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.16, green: 0.17, blue: 0.21))
        )
    }
}

// MARK: - Detail View 5: 시스템 권한

struct SettingsPermissionsDetailView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("시스템 권한 관리")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("화면 텍스트 인식과 스크롤 추적을 위해 필요한 macOS 시스템 보안 권한 상태입니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            // 1. 화면 기록 권한
            permissionRowCard(
                icon: "display",
                title: "화면 기록 권한 (필수)",
                desc: "화면에 노출된 외국어 텍스트를 실시간으로 캡처하고 OCR 분석하기 위해 화면 기록 권한이 반드시 필요합니다.",
                isGranted: viewModel.isScreenCaptureGranted,
                actionTitle: "시스템 설정에서 열기",
                actionURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )

            // 2. 손쉬운 사용 권한
            permissionRowCard(
                icon: "accessibility",
                title: "손쉬운 사용 권한 (창 추적)",
                desc: "스크롤 시 마우스 커서 아래에 있는 브라우저나 문서 창을 식별하여 오차 없는 추적을 지원합니다.",
                isGranted: viewModel.isAccessibilityGranted,
                actionTitle: "시스템 설정에서 열기 ↗",
                actionURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )

            // 3. 전역 입력 모니터링
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("전역 단축키 및 스크롤 이벤트")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
                            Text("동작 중")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.14, green: 0.22, blue: 0.16), in: Capsule())
                    }

                    Text("백그라운드에서 ⌥1, ⌥2, ⌥3, ⌥4 단축키 및 스크롤 휠, Option 길게 누르기(원문 보기)를 감지합니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.17, blue: 0.21))
            )

            // 하단 새로고침 버튼
            HStack {
                Spacer()
                Button {
                    viewModel.refreshPermissionStates()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("권한 상태 다시 확인")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func permissionRowCard(
        icon: String,
        title: String,
        desc: String,
        isGranted: Bool,
        actionTitle: String,
        actionURL: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)

                    Spacer()

                    if isGranted {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
                            Text("허용됨")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.14, green: 0.22, blue: 0.16), in: Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.18))
                            Text("승인 필요")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.18))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.25, green: 0.18, blue: 0.12), in: Capsule())
                    }
                }

                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondary)

                if !isGranted {
                    Button {
                        if let url = URL(string: actionURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(actionTitle)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.16, green: 0.17, blue: 0.21))
        )
    }
}

// MARK: - Detail View 6: 앱 정보

struct SettingsAboutDetailView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "ReadIt"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "6"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("앱 정보")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("ReadIt 버전 및 소프트웨어 정보입니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            NativeSubCard {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.white)
                        Text("macOS 실시간 온디바이스 화면 번역기")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                        Text("버전 \(appVersion) (빌드 \(appBuild))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.9))
                    }

                    Spacer()

                    Button {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.checkForUpdates()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle")
                            Text("업데이트 확인…")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(red: 0.20, green: 0.47, blue: 0.96))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            NativeSubCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GitHub 저장소")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text("https://github.com/SKR6582/ReadIt")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: "https://github.com/SKR6582/ReadIt") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("저장소 열기")
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            NativeSubCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("운영체제 환경")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Text(ProcessInfo.processInfo.operatingSystemVersionString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                    }
                    Divider()
                    HStack {
                        Text("번역 엔진")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Text("Apple Translation (온디바이스)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
                    }
                }
            }
        }
    }
}

// MARK: - Reusable Native Components (Image 2 Style)

/// Image 2 스타일 세팅 로우 (아이콘 + 타이틀 + 도움말 버튼 + 트레일링 컨트롤)
struct NativeSettingRow<Control: View>: View {
    let icon: String
    let title: String
    let tooltip: String
    let control: Control

    init(
        icon: String,
        title: String,
        tooltip: String,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.tooltip = tooltip
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color(white: 0.70))
                .frame(width: 22)

            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)

                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .help(tooltip)
            }

            Spacer()

            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.16, green: 0.17, blue: 0.21))
        )
    }
}

/// Image 2 스타일 하위 서브 카드 (다크 라운드 카드 컨테이너)
struct NativeSubCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.18, green: 0.19, blue: 0.23))
            )
    }
}

/// 언어 항목 카드 로우
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
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text(flagEmoji(for: id))
                .font(.system(size: 20))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.06)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TranslationCoordinator.displayName(of: language))
                        .font(.system(size: 13, weight: isEnabled ? .semibold : .regular))
                        .foregroundStyle(isEnabled ? Color.white : Color(white: 0.7))
                    Text("(\(nativeLanguageName(for: id)))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }

                HStack(spacing: 6) {
                    Text("\(id) → ko")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.secondary)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)

                    Text(isEnabled ? "번역 활성화됨" : "번역 꺼짐")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isEnabled ? Color(red: 0.20, green: 0.47, blue: 0.96) : Color.secondary)
                }
            }

            Spacer()

            actionArea(for: id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? Color(red: 0.20, green: 0.47, blue: 0.96).opacity(0.12) : Color(red: 0.16, green: 0.17, blue: 0.21))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isHighlighted ? Color(red: 0.20, green: 0.47, blue: 0.96).opacity(0.5) : Color.clear,
                            lineWidth: 1.0
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
                Text("설치됨")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.35))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(red: 0.14, green: 0.22, blue: 0.16), in: Capsule())

        case .supported:
            if isDownloading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("다운로드 중…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 10)
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
                    .background(Color(red: 0.20, green: 0.47, blue: 0.96).opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.20, green: 0.47, blue: 0.96))
            }

        case .unsupported:
            Text("미지원")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.5))

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
