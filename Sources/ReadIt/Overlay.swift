import AppKit
import SwiftUI

struct NotchMetrics: Equatable {
    let hasHardwareNotch: Bool
    let notchHeight: CGFloat
    let hardwareNotchWidth: CGFloat

    static let fallback = NotchMetrics(hasHardwareNotch: false, notchHeight: 0, hardwareNotchWidth: 184)

    static func from(screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(160, right.minX - left.maxX)
            return NotchMetrics(hasHardwareNotch: true, notchHeight: topInset, hardwareNotchWidth: width)
        }
        return NotchMetrics(hasHardwareNotch: false, notchHeight: 0, hardwareNotchWidth: 184)
    }
}

struct OverlayBlock: Identifiable {
    var id: Int
    var rect: CGRect
    let sourceText: String
    let sourceLanguage: String
    var translated: String?
    var isMissingPack: Bool = false
    let fontSize: CGFloat
    let lineCount: Int
    let background: NSColor
    let foreground: NSColor
    let isVertical: Bool
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recognizing
        case translating
        case done
        case failed(String)
    }

    @Published var image: CGImage?
    let canvasSize: CGSize
    let isLiveMode: Bool
    var scale: CGFloat {
        guard let image else { return 1.0 }
        return CGFloat(image.width) / max(1, canvasSize.width)
    }

    @Published var phase: Phase = .recognizing
    @Published var blocks: [OverlayBlock] = []
    @Published var showOriginal = false
    @Published var isTrackingScroll = false
    @Published var missingLanguages: [Locale.Language] = []
    @Published var notice: String?
    @Published var scrollSpeedWarning: String?
    @Published var showParallelTipBanner: Bool = false
    @Published var notchMetrics: NotchMetrics = .fallback
    @Published var isNotchExpanded: Bool = false
    @Published var isHoveringNotch: Bool = false
    @Published var sessionElapsedSeconds: Int = 0

    // MARK: - 구역 지정 번역(⌥4) 전용 상태
    @Published var isRegionMode: Bool = false
    @Published var isSelectingRegion: Bool = false
    @Published var isAdjustingRegion: Bool = false
    @Published var regionRect: CGRect?
    @Published var isRegionLive: Bool = false
    @Published var isRegionVerticalOnly: Bool = false
    @Published var activePresetName: String? = nil
    @Published var overrideLanguages: Set<String>? = nil
    @Published var regionCropImage: CGImage?

    var onSelectRegion: ((CGRect) -> Void)?
    var onUpdateRegionRect: ((CGRect) -> Void)?
    var onToggleRegionLive: ((Bool) -> Void)?
    var onToggleRegionVertical: ((Bool) -> Void)?
    var onReselectRegion: (() -> Void)?
    var onRefreshRegion: (() -> Void)?
    var onApplyPreset: ((RegionPreset) -> Void)?
    var onSavePreset: ((String) -> Void)?
    var onDeletePreset: ((UUID) -> Void)?

    /// 스크롤 추적 시 기준이 되는 원본 블록 배열
    private(set) var anchorBlocks: [OverlayBlock] = []
    private var noticeTask: Task<Void, Never>?
    private var scrollWarningTask: Task<Void, Never>?
    private var sessionTimerTask: Task<Void, Never>?

    init(
        image: CGImage?,
        canvasSize: CGSize,
        isLiveMode: Bool = false,
        isRegionMode: Bool = false
    ) {
        self.image = image
        self.canvasSize = canvasSize
        self.isLiveMode = isLiveMode
        self.isRegionMode = isRegionMode
        self.isSelectingRegion = isRegionMode
        if isLiveMode {
            startSessionTimer()
        }
    }

    func startSessionTimer() {
        sessionTimerTask?.cancel()
        sessionElapsedSeconds = 0
        sessionTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                self.sessionElapsedSeconds += 1
            }
        }
    }

    func stopSessionTimer() {
        sessionTimerTask?.cancel()
        sessionTimerTask = nil
    }

    var formattedSessionTime: String {
        let m = sessionElapsedSeconds / 60
        let s = sessionElapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    static func regionControlBarRect(for region: CGRect, canvasSize: CGSize) -> CGRect {
        let halfW: CGFloat = 290
        let halfH: CGFloat = 28
        let centerX = min(max(region.midX, halfW + 12), canvasSize.width - halfW - 12)
        let centerY: CGFloat
        if region.minY >= 58 {
            centerY = region.minY - 26
        } else if region.maxY + 58 <= canvasSize.height {
            centerY = region.maxY + 26
        } else {
            centerY = region.minY + 28
        }
        return CGRect(x: centerX - halfW, y: centerY - halfH, width: halfW * 2, height: halfH * 2)
    }

    /// 구역 테두리(이동) 또는 모서리/변 핸들(크기 조절) 위에 마우스 커서가 있는지 판정
    static func isPointOnRegionFrame(_ point: CGPoint, region: CGRect, tolerance: CGFloat = 10) -> Bool {
        let outer = region.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }
        let innerWidth = max(0, region.width - tolerance * 2)
        let innerHeight = max(0, region.height - tolerance * 2)
        guard innerWidth > 0, innerHeight > 0 else { return true }
        let inner = region.insetBy(dx: tolerance, dy: tolerance)
        return !inner.contains(point)
    }

    /// 노치 통합 HUD 모드일 때 화면 상단 중앙에서 클릭 및 호버를 수신할 히트 테스트 영역
    static func notchHUDHitRect(canvasSize: CGSize, notchMetrics: NotchMetrics, isExpanded: Bool = true) -> CGRect {
        let width: CGFloat = isExpanded ? 760 : max(340, notchMetrics.hardwareNotchWidth + 160)
        let baseHeight = notchMetrics.hasHardwareNotch ? notchMetrics.notchHeight : 0
        let height: CGFloat = isExpanded ? (baseHeight + 220) : max(38, baseHeight + 18)
        return CGRect(
            x: (canvasSize.width - width) / 2.0,
            y: 0,
            width: width,
            height: height
        )
    }

    var translatedCount: Int { blocks.filter { $0.translated != nil }.count }
    var missingPackCount: Int { blocks.filter { $0.isMissingPack }.count }

    /// 스크롤 중 움직이지 않는 상단 내비게이션/고정 사이드바 등의 블록 ID 집합
    private var pinnedBlockIds: Set<Int> = []

    func setBlocks(_ newBlocks: [OverlayBlock]) {
        blocks = newBlocks
        anchorBlocks = newBlocks
        pinnedBlockIds.removeAll(keepingCapacity: true)
        phase = newBlocks.isEmpty || newBlocks.allSatisfy({ $0.translated != nil }) ? .done : .translating
        if newBlocks.isEmpty && !isLiveMode && AppSettings.shared.hudStyle != .notch {
            flash("번역할 외국어 텍스트가 없어요")
        }
    }

    /// 타일 스트리밍 OCR 중 새로 인식된 블록들을 기존 블록 배열에 중복/ID 충돌 없이 추가하고, 실제 추가된 블록 목록을 반환한다.
    @discardableResult
    func appendStreamedBlocks(_ incoming: [OverlayBlock]) -> [OverlayBlock] {
        guard !incoming.isEmpty else { return [] }
        var usedIds = Set(blocks.map(\.id))
        var added: [OverlayBlock] = []
        added.reserveCapacity(incoming.count)
        var supersededIds = Set<Int>()

        for var candidate in incoming {
            let candidateArea = max(1, candidate.rect.width * candidate.rect.height)
            var isDuplicateOfLargerOrEqual = false

            for existing in blocks where !supersededIds.contains(existing.id) {
                let inter = existing.rect.intersection(candidate.rect)
                guard !inter.isNull else { continue }
                let existingArea = max(1, existing.rect.width * existing.rect.height)
                let minArea = min(existingArea, candidateArea)
                guard (inter.width * inter.height) / minArea >= 0.40 else { continue }

                if candidateArea > existingArea * 1.35 {
                    supersededIds.insert(existing.id)
                } else {
                    isDuplicateOfLargerOrEqual = true
                    break
                }
            }

            if isDuplicateOfLargerOrEqual { continue }

            while usedIds.contains(candidate.id) {
                candidate.id &+= 1
            }
            usedIds.insert(candidate.id)
            added.append(candidate)
        }

        guard !added.isEmpty || !supersededIds.isEmpty else { return [] }
        withAnimation(.easeOut(duration: 0.14)) {
            if !supersededIds.isEmpty {
                blocks.removeAll { supersededIds.contains($0.id) }
                anchorBlocks.removeAll { supersededIds.contains($0.id) }
            }
            blocks.append(contentsOf: added)
            anchorBlocks.append(contentsOf: added)
            if phase == .recognizing {
                phase = .translating
            }
        }
        return added
    }

    func updateAnchors(_ newAnchors: [OverlayBlock]) {
        anchorBlocks = newAnchors
        blocks = newAnchors
    }

    /// 기존에 화면을 따라 이동한 블록들과 새로 OCR 인식된 블록들을 병합하여 깜빡임 없이 갱신한다.
    func mergeBlocks(_ incoming: [OverlayBlock]) {
        guard !blocks.isEmpty || !anchorBlocks.isEmpty else {
            setBlocks(incoming)
            return
        }

        // 화면 밖으로 잠시 벗어나 visible 목록에 없더라도 기준 블록의 번역/ID는 재사용한다.
        let existingBlocks = blocks.isEmpty ? anchorBlocks : blocks
        var usedExistingIndices = Set<Int>()
        var usedIds = Set<Int>()
        var merged = incoming

        // 1차: 정규화 원문 일치 기준 매칭 (가장 가까운 블록 우선)
        for i in merged.indices {
            let key = ColorSampler.normalizedTextKey(merged[i].sourceText)
            var bestIdx: Int?
            var bestDist = CGFloat.greatestFiniteMagnitude

            for (eIdx, existing) in existingBlocks.enumerated() where !usedExistingIndices.contains(eIdx) {
                let existingKey = ColorSampler.normalizedTextKey(existing.sourceText)
                guard key == existingKey else { continue }
                let dist = hypot(merged[i].rect.midX - existing.rect.midX, merged[i].rect.midY - existing.rect.midY)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = eIdx
                }
            }

            if let eIdx = bestIdx {
                usedExistingIndices.insert(eIdx)
                let existing = existingBlocks[eIdx]
                if !usedIds.contains(existing.id) {
                    merged[i].id = existing.id
                }
                if merged[i].translated == nil {
                    merged[i].translated = existing.translated
                    merged[i].isMissingPack = existing.isMissingPack
                }
                usedIds.insert(merged[i].id)
            }
        }

        // 2차: 동일 위치(수직 오차 32pt 이내 또는 영역 중첩 35% 이상)에서 OCR 미세 오차가 발생한 블록만 보수적으로 매칭
        for i in merged.indices where !usedIds.contains(merged[i].id) || merged[i].translated == nil {
            var bestIdx: Int?
            var bestScore: CGFloat = 0

            for (eIdx, existing) in existingBlocks.enumerated() where !usedExistingIndices.contains(eIdx) {
                let verticalDiff = abs(merged[i].rect.midY - existing.rect.midY)
                let horizontalDiff = abs(merged[i].rect.midX - existing.rect.midX)
                let intersection = merged[i].rect.intersection(existing.rect)
                let minArea = max(1, min(merged[i].rect.width * merged[i].rect.height, existing.rect.width * existing.rect.height))
                let overlapRatio = intersection.isNull ? 0 : (intersection.width * intersection.height) / minArea

                guard overlapRatio >= 0.35 || (verticalDiff < 32 && horizontalDiff < 60) else { continue }

                let sim = Self.textSimilarity(merged[i].sourceText, existing.sourceText)
                guard sim >= 0.82 else { continue }

                let score = sim * 0.8 + overlapRatio * 0.2
                if score > bestScore {
                    bestScore = score
                    bestIdx = eIdx
                }
            }

            if let eIdx = bestIdx {
                usedExistingIndices.insert(eIdx)
                let existing = existingBlocks[eIdx]
                if !usedIds.contains(existing.id) {
                    merged[i].id = existing.id
                }
                if merged[i].translated == nil {
                    merged[i].translated = existing.translated
                    merged[i].isMissingPack = existing.isMissingPack
                }
            }
            usedIds.insert(merged[i].id)
        }

        // ID 중복 방지 보정
        var finalIds = Set<Int>()
        for i in merged.indices {
            var candidateId = merged[i].id
            while finalIds.contains(candidateId) {
                candidateId &+= 1
            }
            merged[i].id = candidateId
            finalIds.insert(candidateId)
        }

        blocks = merged
        anchorBlocks = merged
        pinnedBlockIds.removeAll(keepingCapacity: true)
        phase = merged.isEmpty || merged.allSatisfy({ $0.translated != nil }) ? .done : .translating
    }

    /// 가로 4분할 밴드 중 일부 밴드만 변화했을 때, 변화가 없는 밴드의 기존 블록은 그대로 유지하고 변화된 밴드의 블록만 교체·병합한다.
    func mergePartialBands(
        newBandBlocks: [OverlayBlock],
        dirtyRanges: [HorizontalBandTracker.DirtyBandRange]
    ) {
        let preserved = blocks.filter { existing in
            let inDirtyBand = dirtyRanges.contains { range in
                existing.rect.midY >= range.coreRect.minY && existing.rect.midY <= range.coreRect.maxY
            }
            if inDirtyBand { return false }

            // 경계선 Overlap 영역에서 새로 인식된 블록과 40% 이상 겹치는 경우 중복 방지를 위해 새 블록 우선
            let overlapsNew = newBandBlocks.contains { incoming in
                let inter = existing.rect.intersection(incoming.rect)
                guard !inter.isNull else { return false }
                let minArea = max(1, min(existing.rect.width * existing.rect.height, incoming.rect.width * incoming.rect.height))
                return (inter.width * inter.height) / minArea >= 0.40
            }
            return !overlapsNew
        }

        let combined = preserved + newBandBlocks
        mergeBlocks(combined)
    }

    /// 스크롤 직후 새로 노출된 상·하단 영역의 OCR 결과를 캡처 시점 기준(capturedDelta)으로 기존 앵커 블록과 병합하고,
    /// OCR 진행 중 추가로 발생한 잔여 스크롤(residualDelta)까지 즉시 반영한다.
    @discardableResult
    func rebaseAndMergeScrollStrip(
        newStripBlocks: [OverlayBlock],
        coreStripRect: CGRect,
        capturedDelta: CGPoint,
        residualDelta: CGPoint,
        within windowRect: CGRect?,
        pinnedIds: Set<Int>? = nil
    ) -> [OverlayBlock] {
        if let pinnedIds {
            self.pinnedBlockIds = pinnedIds
        }
        let activePinnedIds = self.pinnedBlockIds
        let screenBounds = CGRect(origin: .zero, size: canvasSize)
        let clipBounds = (isRegionMode ? regionRect?.intersection(screenBounds) : nil) ?? screenBounds

        var shiftedAnchors: [OverlayBlock] = []
        shiftedAnchors.reserveCapacity(anchorBlocks.count)

        for var block in anchorBlocks {
            if activePinnedIds.contains(block.id) {
                shiftedAnchors.append(block)
                continue
            }
            if let winRect = windowRect, !winRect.intersects(block.rect) {
                shiftedAnchors.append(block)
                continue
            }
            block.rect = block.rect.offsetBy(dx: capturedDelta.x, dy: capturedDelta.y)
            let visible = block.rect.intersection(clipBounds)
            if !visible.isNull,
               visible.height >= min(8, block.rect.height * 0.20),
               visible.width >= min(8, block.rect.width * 0.20) {
                shiftedAnchors.append(block)
            }
        }

        let preserved = shiftedAnchors.filter { existing in
            if activePinnedIds.contains(existing.id) {
                return true
            }
            let inCoreStrip = existing.rect.midY >= coreStripRect.minY && existing.rect.midY <= coreStripRect.maxY
            if inCoreStrip { return false }

            let overlapsNew = newStripBlocks.contains { incoming in
                let inter = existing.rect.intersection(incoming.rect)
                guard !inter.isNull else { return false }
                let minArea = max(1, min(existing.rect.width * existing.rect.height, incoming.rect.width * incoming.rect.height))
                return (inter.width * inter.height) / minArea >= 0.40
            }
            return !overlapsNew
        }

        blocks = shiftedAnchors
        anchorBlocks = shiftedAnchors
        mergeBlocks(preserved + newStripBlocks)

        if abs(residualDelta.x) > 0.1 || abs(residualDelta.y) > 0.1 {
            _ = applyScrollOffset(cumulativeDelta: residualDelta, within: windowRect)
        }

        return anchorBlocks.filter { $0.translated == nil && !$0.isMissingPack }
    }

    /// 기준 블록(anchorBlocks)에 누적 스크롤 오프셋을 적용하고 화면에 보이는 블록 수를 반환한다.
    @discardableResult
    func applyScrollOffset(
        cumulativeDelta: CGPoint,
        within windowRect: CGRect?,
        pinnedIds: Set<Int>? = nil
    ) -> Int {
        guard !anchorBlocks.isEmpty else { return 0 }
        if let pinnedIds {
            self.pinnedBlockIds = pinnedIds
        }
        let activePinnedIds = self.pinnedBlockIds
        let screenBounds = CGRect(origin: .zero, size: canvasSize)
        let clipBounds = (isRegionMode ? regionRect?.intersection(screenBounds) : nil) ?? screenBounds

        var updated: [OverlayBlock] = []
        updated.reserveCapacity(anchorBlocks.count)
        var visibleInScrollArea = 0

        for var block in anchorBlocks {
            if activePinnedIds.contains(block.id) {
                updated.append(block)
                continue
            }
            if let winRect = windowRect, !winRect.intersects(block.rect) {
                updated.append(block)
                continue
            }

            block.rect = block.rect.offsetBy(dx: cumulativeDelta.x, dy: cumulativeDelta.y)
            let visible = block.rect.intersection(clipBounds)
            if !visible.isNull,
               visible.height >= min(8, block.rect.height * 0.20),
               visible.width >= min(8, block.rect.width * 0.20) {
                updated.append(block)
                visibleInScrollArea += 1
            }
        }

        blocks = updated
        return visibleInScrollArea
    }

    private static func textSimilarity(_ a: String, _ b: String) -> CGFloat {
        let ka = Array(ColorSampler.normalizedTextKey(a))
        let kb = Array(ColorSampler.normalizedTextKey(b))
        if ka == kb { return 1.0 }
        guard !ka.isEmpty, !kb.isEmpty else { return 0.0 }
        let maxLen = max(ka.count, kb.count)
        let minLen = min(ka.count, kb.count)
        if CGFloat(minLen) / CGFloat(maxLen) < 0.6 { return 0.0 }

        // 빠른 공통 문자 바이그램 유사도(Dice coefficient) 계산
        if ka.count < 2 || kb.count < 2 {
            return ka.first == kb.first ? 0.8 : 0.0
        }
        var bigramsA: [Int: Int] = [:]
        for i in 0..<(ka.count - 1) {
            let h = (ka[i].hashValue &* 31) &+ ka[i + 1].hashValue
            bigramsA[h, default: 0] += 1
        }
        var matches = 0
        for i in 0..<(kb.count - 1) {
            let h = (kb[i].hashValue &* 31) &+ kb[i + 1].hashValue
            if let count = bigramsA[h], count > 0 {
                matches += 1
                bigramsA[h] = count - 1
            }
        }
        return CGFloat(2 * matches) / CGFloat((ka.count - 1) + (kb.count - 1))
    }

    func apply(translation: String, toBlock id: Int) {
        if let anchorIndex = anchorBlocks.firstIndex(where: { $0.id == id }) {
            anchorBlocks[anchorIndex].translated = translation
            anchorBlocks[anchorIndex].isMissingPack = false
        }
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            blocks[index].translated = translation
            blocks[index].isMissingPack = false
        }
    }

    func markMissingPack(forLanguage code: String) {
        for index in anchorBlocks.indices {
            if anchorBlocks[index].sourceLanguage == code && anchorBlocks[index].translated == nil {
                anchorBlocks[index].isMissingPack = true
            }
        }
        withAnimation(.easeOut(duration: 0.2)) {
            for index in blocks.indices {
                if blocks[index].sourceLanguage == code && blocks[index].translated == nil {
                    blocks[index].isMissingPack = true
                }
            }
        }
    }

    /// 번역 배치 종료 처리.
    /// targetIds가 주어지면 해당 배치에 포함된 블록만 정리하여, 번역 도중 스크롤 OCR로 새로 추가된 미번역 블록은 보존한다.
    func finish(failures: [String], forBlockIds targetIds: Set<Int>? = nil) {
        let shouldRemove: (OverlayBlock) -> Bool = { block in
            guard block.translated == nil, !block.isMissingPack else { return false }
            if let targetIds { return targetIds.contains(block.id) }
            return true
        }
        anchorBlocks.removeAll(where: shouldRemove)
        // 번역되지 못했고 언어 팩 미설치 하이라이트 대상도 아닌 블록만 제거
        // 언어 팩이 없어 번역하지 못한 블록(isMissingPack == true)은 붉은색 하이라이트로 화면에 유지
        withAnimation(.easeOut(duration: 0.2)) {
            blocks.removeAll(where: shouldRemove)
        }
        let hasRemainingPending = anchorBlocks.contains { $0.translated == nil && !$0.isMissingPack }
        if hasRemainingPending {
            phase = .translating
        } else if let first = failures.first, translatedCount == 0, missingPackCount == 0 {
            phase = .failed(first)
        } else {
            phase = .done
        }
    }

    /// 추적 기준을 잃었을 때 잘못된 위치의 오버레이가 남지 않도록 모든 블록을 즉시 비운다.
    func clearForRealign() {
        blocks = []
        anchorBlocks = []
        pinnedBlockIds.removeAll(keepingCapacity: true)
        if phase != .recognizing {
            phase = .done
        }
    }

    /// 같은 창이 이동했을 때 현재 화면 위치의 블록을 창 이동량만큼 옮기고 이를 새 기준 좌표로 삼는다.
    func shiftAllBlocks(by delta: CGPoint, within windowRect: CGRect? = nil) {
        let moved = blocks.map { block -> OverlayBlock in
            if let winRect = windowRect, !winRect.intersects(block.rect) {
                return block
            }
            var copy = block
            copy.rect = block.rect.offsetBy(dx: delta.x, dy: delta.y)
            return copy
        }
        blocks = moved
        anchorBlocks = moved
    }

    func copyAll() {
        let text = blocks
            .filter { $0.translated != nil || $0.isMissingPack }
            .sorted { abs($0.rect.minY - $1.rect.minY) < 4 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
            .compactMap { $0.translated ?? $0.sourceText }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppSettings.shared.recordCopiedText(text)
        flash("텍스트를 클립보드에 복사했어요")
    }

    func copyText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        AppSettings.shared.recordCopiedText(trimmed)
        flash("문장을 클립보드에 복사했어요")
    }

    func flash(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { notice = message }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) { self?.notice = nil }
        }
    }

    func triggerScrollSpeedWarning(
        _ message: String = "스크롤이 너무 빠릅니다. 정확한 추적을 위해 천천히 스크롤해 주세요."
    ) {
        scrollWarningTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            if scrollSpeedWarning != message {
                scrollSpeedWarning = message
            }
            if !isNotchExpanded {
                isNotchExpanded = true
            }
        }
        scrollWarningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                self.scrollSpeedWarning = nil
                if (self.isLiveMode || self.isRegionMode) && !self.isHoveringNotch {
                    self.isNotchExpanded = false
                }
            }
        }
    }
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    let model: OverlayModel
    var onClose: (() -> Void)?
    private var isClosing = false

    @MainActor
    init(screen: NSScreen, model: OverlayModel, onOpenLanguagePacks: @escaping ([Locale.Language]) -> Void) {
        self.model = model
        model.notchMetrics = NotchMetrics.from(screen: screen)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        if model.isLiveMode {
            // 전체 화면 라이브 모드에서는 마우스 이벤트를 아래 창으로 완전히 통과시킨다
            ignoresMouseEvents = true
        }

        let root = OverlayView(
            model: model,
            onDismiss: { [weak self] in self?.dismiss() },
            onOpenLanguagePacks: onOpenLanguagePacks
        )
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = host
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { !model.isLiveMode && !(model.isRegionMode && model.isRegionLive && !model.isSelectingRegion) }
    override var canBecomeMain: Bool { false }

    func present() {
        alphaValue = 0
        if model.isLiveMode {
            orderFrontRegardless()
        } else {
            makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.onClose?()
        })
    }

    override func mouseDown(with event: NSEvent) {
        if !model.isLiveMode && !model.isRegionMode {
            dismiss()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !model.isLiveMode && event.keyCode == 53 { // Esc
            dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if !model.isLiveMode {
            dismiss()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                MainActor.assumeIsolated { model.copyAll() }
                return true
            case "w":
                dismiss()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let optionDown = event.modifierFlags.contains(.option)
        MainActor.assumeIsolated {
            if model.showOriginal != optionDown {
                withAnimation(.easeOut(duration: 0.15)) { model.showOriginal = optionDown }
            }
        }
        super.flagsChanged(with: event)
    }
}
