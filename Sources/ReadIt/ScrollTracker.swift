import AppKit
import CoreGraphics
import Foundation

struct WindowTabContext: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let title: String
    let bounds: CGRect

    func isSameTab(as other: WindowTabContext) -> Bool {
        guard windowID == other.windowID, ownerPID == other.ownerPID else {
            return false
        }
        if abs(bounds.minX - other.bounds.minX) > 6 ||
           abs(bounds.minY - other.bounds.minY) > 6 ||
           abs(bounds.width - other.bounds.width) > 6 ||
           abs(bounds.height - other.bounds.height) > 6 {
            return false
        }
        // 브라우저 알림 수, 영상 재생 제목, SPA 하위 경로 변경 등으로 창 제목만 바뀌는 경우에는
        // 동일한 창/위치이므로 스크롤 앵커를 즉시 파기하지 않고 유지한다.
        return true
    }
}

struct ScrollBoundaryCheckResult {
    enum State {
        /// 화면이 스크롤 입력에 맞춰 정상 이동 중 (고정 UI 블록 ID 포함)
        case movingNormally(pinnedBlockIds: Set<Int>)
        /// 스크롤 중 예측 이동량과 실제 픽셀 이동량 간 오차(Drift)가 감지되어 실제 이동량으로 즉시 보정
        case driftCorrected(actualCumulativeDy: CGFloat, pinnedBlockIds: Set<Int>)
        /// 최상단/최하단 스크롤 한계에 도달해 화면이 멈춤 (실제 이동한 총 Y 오프셋으로 고정 필요)
        case hitBoundary(clampedCumulativeDy: CGFloat, pinnedBlockIds: Set<Int>)
        /// 탭 전환 또는 급격한 화면 변화로 대상을 놓침 (즉시 복귀 재스캔 필요)
        case targetLost
    }

    let state: State
}

struct ScrollTrackResult {
    enum Status {
        case unchanged
        case tracked(blocks: [OverlayBlock], cumulativeDelta: CGPoint)
        case targetLost
    }

    let status: Status
}

/// 실시간 스크롤 이벤트의 순간 속도 및 구간 이동량을 측정하여 과속 스크롤 여부를 판별하는 모니터
@MainActor
final class ScrollVelocityMonitor {
    private struct Sample {
        let timestamp: TimeInterval
        let absDy: CGFloat
    }

    private var samples: [Sample] = []
    private let windowDuration: TimeInterval = 0.22

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// 스크롤 델타를 기록하고, 추적 한계를 넘는 과속 스크롤인지 여부를 반환한다.
    func record(dy: CGFloat, viewportHeight: CGFloat) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let absDy = abs(dy)
        samples.removeAll { now - $0.timestamp > windowDuration }
        samples.append(Sample(timestamp: now, absDy: absDy))

        let effectiveHeight = max(240.0, viewportHeight)
        let singleTickLimit = max(46.0, min(72.0, effectiveHeight * 0.065))
        let windowDisplacementLimit = max(195.0, min(320.0, effectiveHeight * 0.28))

        let windowDisplacement = samples.reduce(0.0) { $0 + $1.absDy }
        return absDy >= singleTickLimit || windowDisplacement >= windowDisplacementLimit
    }
}

/// 화면 또는 지정 구역을 가로로 긴 4개의 스트립(상·중상·중하·하단)으로 분할하여 독립적으로 변화를 감지하는 추적기
@MainActor
final class HorizontalBandTracker {
    static let bandCount = 4
    private static let thumbWidth = 48
    private static let thumbBandHeight = 8
    private static let subColumns = 4

    struct DirtyBandRange: Sendable {
        let bandIndices: ClosedRange<Int>
        /// 실제 변화가 감지된 밴드의 정확한 화면 좌표 영역
        let coreRect: CGRect
        /// 문단 경계 잘림 방지를 위해 위아래 여유(Overlap Margin)를 확장한 OCR 크롭용 좌표 영역
        let expandedRect: CGRect
    }

    enum DetectionResult {
        case none
        case partial([DirtyBandRange])
        case full
    }

    private var lastBandPixels: [[UInt8]] = []
    private var lastTargetRect: CGRect = .zero

    func reset() {
        lastBandPixels = []
        lastTargetRect = .zero
    }

    /// 현재 프레임의 4개 가로 밴드를 직전 프레임과 비교하여 변화가 발생한 밴드 구간만 반환한다.
    func detectChanges(
        in image: CGImage,
        targetRect: CGRect,
        threshold: Double = 2.8,
        overlapMargin: CGFloat = 28.0
    ) -> DetectionResult {
        let totalHeight = Self.bandCount * Self.thumbBandHeight
        let currentBands = Self.extractBandPixels(
            from: image,
            width: Self.thumbWidth,
            totalHeight: totalHeight,
            bandCount: Self.bandCount
        )
        guard currentBands.count == Self.bandCount else {
            return .full
        }

        defer {
            lastBandPixels = currentBands
            lastTargetRect = targetRect
        }

        guard lastBandPixels.count == Self.bandCount,
              abs(lastTargetRect.width - targetRect.width) < 2,
              abs(lastTargetRect.height - targetRect.height) < 2
        else {
            return .full
        }

        var changedIndices: [Int] = []
        let subColWidth = Self.thumbWidth / Self.subColumns

        for b in 0..<Self.bandCount {
            let cur = currentBands[b]
            let prev = lastBandPixels[b]
            guard cur.count == prev.count, !cur.isEmpty else {
                changedIndices.append(b)
                continue
            }

            var bandDiffSum = 0
            var subColDiffSums = [Int](repeating: 0, count: Self.subColumns)
            var subColCounts = [Int](repeating: 0, count: Self.subColumns)

            for i in 0..<cur.count {
                let diff = abs(Int(cur[i]) - Int(prev[i]))
                bandDiffSum += diff
                let x = i % Self.thumbWidth
                let col = min(Self.subColumns - 1, x / max(1, subColWidth))
                subColDiffSums[col] += diff
                subColCounts[col] += 1
            }

            let avgBandDiff = Double(bandDiffSum) / Double(cur.count)
            var maxSubColDiff = 0.0
            for c in 0..<Self.subColumns where subColCounts[c] > 0 {
                let subAvg = Double(subColDiffSums[c]) / Double(subColCounts[c])
                if subAvg > maxSubColDiff {
                    maxSubColDiff = subAvg
                }
            }

            // 밴드 전체 평균 변화량 또는 좌측 채팅/짧은 문장 등 부분 셀 변화량이 임계값을 넘으면 해당 가로 밴드만 변화로 판정
            if avgBandDiff > threshold || maxSubColDiff > threshold * 1.55 {
                changedIndices.append(b)
            }
        }

        if changedIndices.isEmpty {
            return .none
        }
        if changedIndices.count == Self.bandCount {
            return .full
        }

        // 인접한 변화 밴드들을 하나의 연속 구간으로 병합 (경계선 문단 분리 방지)
        var contiguousRanges: [ClosedRange<Int>] = []
        for idx in changedIndices {
            if let last = contiguousRanges.last, last.upperBound + 1 == idx {
                contiguousRanges[contiguousRanges.count - 1] = last.lowerBound...idx
            } else {
                contiguousRanges.append(idx...idx)
            }
        }

        let bandHeight = targetRect.height / CGFloat(Self.bandCount)
        let dirtyRanges: [DirtyBandRange] = contiguousRanges.map { range in
            let coreMinY = targetRect.minY + CGFloat(range.lowerBound) * bandHeight
            let coreMaxY = (range.upperBound == Self.bandCount - 1)
                ? targetRect.maxY
                : (targetRect.minY + CGFloat(range.upperBound + 1) * bandHeight)
            let coreRect = CGRect(
                x: targetRect.minX,
                y: coreMinY,
                width: targetRect.width,
                height: coreMaxY - coreMinY
            )

            let expMinY = max(targetRect.minY, coreMinY - overlapMargin)
            let expMaxY = min(targetRect.maxY, coreMaxY + overlapMargin)
            let expandedRect = CGRect(
                x: targetRect.minX,
                y: expMinY,
                width: targetRect.width,
                height: expMaxY - expMinY
            )

            return DirtyBandRange(
                bandIndices: range,
                coreRect: coreRect,
                expandedRect: expandedRect
            )
        }

        return .partial(dirtyRanges)
    }

    nonisolated private static func extractBandPixels(
        from image: CGImage,
        width: Int,
        totalHeight: Int,
        bandCount: Int
    ) -> [[UInt8]] {
        var pixels = [UInt8](repeating: 0, count: width * totalHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return []
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: totalHeight))

        let bandHeight = totalHeight / bandCount
        let bandPixelCount = width * bandHeight
        var bands: [[UInt8]] = []
        bands.reserveCapacity(bandCount)

        for b in 0..<bandCount {
            let start = b * bandPixelCount
            let end = start + bandPixelCount
            bands.append(Array(pixels[start..<end]))
        }
        return bands
    }
}

@MainActor
final class ScrollTracker {
    struct GrayscaleFrame: Sendable {
        let width: Int
        let height: Int
        let scaleX: CGFloat
        let scaleY: CGFloat
        let pixels: [UInt8]
        let gradients: [UInt8]
        let bandCount: Int
        let bandMeans: [UInt8]
        let bandGradients: [UInt8]
        /// 스크롤 본문 영역의 행별 텍스트 에지 고주파 프로파일 (전체 폭)
        let rowHighPassEdge: [Float]
        /// 가로 4등분 컬럼별 독립 행 고주파 에지 프로파일 (고정 사이드바/다단 분리 추적용)
        let bandHighPassEdge: [[Float]]
    }

    private var referenceFrame: GrayscaleFrame?
    private(set) var referenceBlocks: [OverlayBlock] = []
    private(set) var referenceTabContext: WindowTabContext?
    private var canvasSize: CGSize = .zero

    /// 스크롤 도중 직전 시점의 프레임과 그때의 누적 스크롤 Y값 (최상단/최하단 정지 감지용)
    private var lastStepFrame: GrayscaleFrame?
    private var lastStepCumulativeDy: CGFloat = 0
    private var stationaryStepCount: Int = 0

    var hasReference: Bool {
        referenceFrame != nil && !referenceBlocks.isEmpty
    }

    func reset() {
        referenceFrame = nil
        referenceBlocks = []
        referenceTabContext = nil
        lastStepFrame = nil
        lastStepCumulativeDy = 0
        stationaryStepCount = 0
        canvasSize = .zero
    }

    func captureReference(
        image: CGImage,
        blocks: [OverlayBlock],
        canvasSize: CGSize,
        tabContext: WindowTabContext?
    ) {
        guard !blocks.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else {
            reset()
            return
        }
        guard let frame = Self.makeGrayscaleFrame(
            from: image,
            canvasSize: canvasSize,
            windowRect: tabContext?.bounds
        ) else {
            reset()
            return
        }
        self.referenceFrame = frame
        self.referenceBlocks = blocks
        self.referenceTabContext = tabContext
        self.lastStepFrame = frame
        self.lastStepCumulativeDy = 0
        self.stationaryStepCount = 0
        self.canvasSize = canvasSize
    }

    func updateReferenceBlocks(_ blocks: [OverlayBlock]) {
        guard referenceFrame != nil, !blocks.isEmpty else { return }
        self.referenceBlocks = blocks
    }

    /// 스크롤 중 또는 스크롤 직후에 실제 화면 이동량(Drift), 고정 블록(Sticky UI), 스크롤 한계 도달, 추적 실패 여부를 판별한다.
    func checkScrollBoundary(
        newImage: CGImage,
        currentTabContext: WindowTabContext?,
        predictedCumulativeDy: CGFloat
    ) -> ScrollBoundaryCheckResult {
        guard let ref = referenceFrame, !referenceBlocks.isEmpty else {
            return ScrollBoundaryCheckResult(state: .targetLost)
        }

        if let refTab = referenceTabContext, let curTab = currentTabContext {
            if !curTab.isSameTab(as: refTab) {
                return ScrollBoundaryCheckResult(state: .targetLost)
            }
        }

        let winRect = currentTabContext?.bounds ?? referenceTabContext?.bounds
        guard let cur = Self.makeGrayscaleFrame(
            from: newImage,
            canvasSize: canvasSize,
            windowRect: winRect
        ), cur.width == ref.width, cur.height == ref.height else {
            return ScrollBoundaryCheckResult(state: .movingNormally(pinnedBlockIds: []))
        }

        let screenBounds = CGRect(origin: .zero, size: canvasSize)
        let activeWin = (winRect ?? screenBounds).intersection(screenBounds)

        let tabBarCost = Self.computeTabHeaderStripCost(ref: ref, cur: cur, windowRect: activeWin)
        if tabBarCost > 0.20 {
            return ScrollBoundaryCheckResult(state: .targetLost)
        }

        let contentMinY = min(activeWin.maxY - 20, activeWin.minY + min(64, activeWin.height * 0.15))
        let contentMaxY = max(contentMinY + 20, activeWin.maxY - min(24, activeWin.height * 0.06))

        let prevFrame = lastStepFrame ?? ref
        let stepWheelDy = predictedCumulativeDy - lastStepCumulativeDy

        // 1. 기준 프레임(ref)과 현재 프레임(cur)이 본문 영역에서 전혀 움직이지 않았는지 검사 (이미 최상단/최하단인 상태)
        let refZeroNCC = Self.computeMultiBandRowEdgeZNCC(
            ref: ref,
            cur: cur,
            minYScreen: contentMinY,
            maxYScreen: contentMaxY,
            gDy: 0
        )
        let refZeroSAD = Self.computeContentRegionSAD(
            ref: ref,
            cur: cur,
            windowRect: activeWin,
            contentMinY: contentMinY,
            contentMaxY: contentMaxY,
            gDy: 0
        )

        if abs(predictedCumulativeDy) >= 4.0 && (refZeroSAD < 0.007 || refZeroNCC > 0.88) {
            stationaryStepCount += 1
            lastStepFrame = cur
            lastStepCumulativeDy = 0
            return ScrollBoundaryCheckResult(state: .hitBoundary(clampedCumulativeDy: 0, pinnedBlockIds: []))
        }

        // 2. 다중 컬럼 ZNCC + 포물선 서브픽셀 보간으로 실제 수직 이동량(actualTotalDy) 탐색
        let predTotalGDy = Int((predictedCumulativeDy * ref.scaleY).rounded())
        let (bestTotalGDyFloat, bestTotalNCC) = Self.findBestShiftByMultiBandEdgeZNCC(
            ref: ref,
            cur: cur,
            minYScreen: contentMinY,
            maxYScreen: contentMaxY,
            predGDy: predTotalGDy
        )
        let actualTotalDy = CGFloat(bestTotalGDyFloat) / ref.scaleY

        // 3. 직전 체크 프레임(prevFrame)과 현재 프레임(cur) 사이에 정지 여부 검사
        let stepZeroNCC = Self.computeMultiBandRowEdgeZNCC(
            ref: prevFrame,
            cur: cur,
            minYScreen: contentMinY,
            maxYScreen: contentMaxY,
            gDy: 0
        )
        let stepZeroSAD = Self.computeContentRegionSAD(
            ref: prevFrame,
            cur: cur,
            windowRect: activeWin,
            contentMinY: contentMinY,
            contentMaxY: contentMaxY,
            gDy: 0
        )

        let candidateDy = (bestTotalNCC > 0.52) ? actualTotalDy : predictedCumulativeDy
        let (pinnedIds, matchedCount, visibleCandidateCount) = Self.evaluateBlockMatchesAndPins(
            ref: ref,
            cur: cur,
            blocks: referenceBlocks,
            windowRect: activeWin,
            screenBounds: screenBounds,
            actualDy: candidateDy
        )

        if abs(stepWheelDy) >= 5.0 && (stepZeroSAD < 0.007 || stepZeroNCC > 0.88) {
            stationaryStepCount += 1
            let clampedDy = (bestTotalNCC > 0.52) ? actualTotalDy : lastStepCumulativeDy
            lastStepFrame = cur
            lastStepCumulativeDy = clampedDy
            return ScrollBoundaryCheckResult(
                state: .hitBoundary(clampedCumulativeDy: clampedDy, pinnedBlockIds: pinnedIds)
            )
        } else {
            stationaryStepCount = 0
        }

        // 4. 추적 실패(Target Lost) 감지:
        //    화면이 크게 변했으나(refZeroSAD > 0.048) ZNCC 상관도와 블록 패치 매칭률이 모두 무너진 경우
        let matchRatio = visibleCandidateCount > 0
            ? Double(matchedCount) / Double(visibleCandidateCount)
            : 1.0
        if bestTotalNCC < 0.34 && matchRatio < 0.22 && refZeroSAD > 0.048 {
            return ScrollBoundaryCheckResult(state: .targetLost)
        }

        // 5. 스크롤 도중 바닥/천장에 부딪혀 예측 이동량보다 실제 이동량이 현저히 적게 멈춘 경우
        if bestTotalNCC > 0.65 {
            let sameSign = (predictedCumulativeDy * actualTotalDy) >= 0
            if sameSign && abs(actualTotalDy) + 10.0 < abs(predictedCumulativeDy) {
                let nccAtPred = Self.computeMultiBandRowEdgeZNCC(
                    ref: ref,
                    cur: cur,
                    minYScreen: contentMinY,
                    maxYScreen: contentMaxY,
                    gDy: predTotalGDy
                )
                if bestTotalNCC > nccAtPred + 0.16 {
                    lastStepFrame = cur
                    lastStepCumulativeDy = actualTotalDy
                    return ScrollBoundaryCheckResult(
                        state: .hitBoundary(clampedCumulativeDy: actualTotalDy, pinnedBlockIds: pinnedIds)
                    )
                }
            }
        }

        // 6. 예측 스크롤 오프셋과 실제 픽셀 이동량 간 Drift(>= 1.5pt) 발생 또는 고정 블록 감지 시 즉시 보정
        lastStepFrame = cur
        if bestTotalNCC > 0.58 {
            lastStepCumulativeDy = actualTotalDy
            if abs(actualTotalDy - predictedCumulativeDy) >= 1.5 || !pinnedIds.isEmpty {
                return ScrollBoundaryCheckResult(
                    state: .driftCorrected(actualCumulativeDy: actualTotalDy, pinnedBlockIds: pinnedIds)
                )
            }
        } else {
            lastStepCumulativeDy = predictedCumulativeDy
        }

        return ScrollBoundaryCheckResult(state: .movingNormally(pinnedBlockIds: pinnedIds))
    }

    /// 보고 있는 탭 정보(창 ID, 탭 제목, 상단 탭 바 영역 픽셀)와 블록 패치를 함께 비교하여 스크롤 추적 및 탭 전환 여부를 판별한다.
    func verifyAndTrack(
        newImage: CGImage,
        currentTabContext: WindowTabContext?,
        predictedCumulativeDelta: CGPoint
    ) -> ScrollTrackResult {
        guard let ref = referenceFrame, !referenceBlocks.isEmpty else {
            return ScrollTrackResult(status: .targetLost)
        }

        if let refTab = referenceTabContext, let curTab = currentTabContext {
            if !curTab.isSameTab(as: refTab) {
                return ScrollTrackResult(status: .targetLost)
            }
        }

        let activeWindowRect = currentTabContext?.bounds ?? referenceTabContext?.bounds
        guard let cur = Self.makeGrayscaleFrame(
            from: newImage,
            canvasSize: canvasSize,
            windowRect: activeWindowRect
        ), cur.width == ref.width, cur.height == ref.height else {
            return ScrollTrackResult(status: .targetLost)
        }

        let screenBounds = CGRect(origin: .zero, size: canvasSize)

        let tabBarCost = Self.computeTabHeaderStripCost(
            ref: ref,
            cur: cur,
            windowRect: activeWindowRect ?? screenBounds
        )
        let isSameTabMetadata = (referenceTabContext != nil && currentTabContext != nil)
            ? currentTabContext!.isSameTab(as: referenceTabContext!)
            : false
        let isSameTabHeaderVisually = tabBarCost < 0.085
        let isViewingSameTab = isSameTabMetadata && isSameTabHeaderVisually

        if tabBarCost > 0.16 {
            return ScrollTrackResult(status: .targetLost)
        }

        var scrollingCandidates: [OverlayBlock] = []
        var outsideBlocks: [OverlayBlock] = []

        for block in referenceBlocks {
            if let winRect = activeWindowRect, !winRect.intersects(block.rect) {
                outsideBlocks.append(block)
            } else {
                scrollingCandidates.append(block)
            }
        }

        if scrollingCandidates.isEmpty {
            scrollingCandidates = referenceBlocks
            outsideBlocks = []
        }

        let unmovedCost = Self.evaluateShiftCost(
            ref: ref,
            cur: cur,
            blocks: scrollingCandidates,
            gDx: 0,
            gDy: 0
        )

        let movedDistance = abs(predictedCumulativeDelta.y)
        if unmovedCost < 0.022 && movedDistance < 1.5 {
            return ScrollTrackResult(status: .unchanged)
        }

        let activeWin = (activeWindowRect ?? screenBounds).intersection(screenBounds)
        let contentMinY = min(activeWin.maxY - 20, activeWin.minY + min(64, activeWin.height * 0.15))
        let contentMaxY = max(contentMinY + 20, activeWin.maxY - min(24, activeWin.height * 0.06))

        let predGDy = Int((predictedCumulativeDelta.y * ref.scaleY).rounded())
        let (znccBestGDy, znccBestScore) = Self.findBestShiftByMultiBandEdgeZNCC(
            ref: ref,
            cur: cur,
            minYScreen: contentMinY,
            maxYScreen: contentMaxY,
            predGDy: predGDy
        )

        let actualDx: CGFloat = 0
        let actualDy: CGFloat
        if znccBestScore > 0.62 {
            if abs(znccBestGDy - predictedCumulativeDelta.y * ref.scaleY) <= 2.0 {
                actualDy = predictedCumulativeDelta.y
            } else {
                actualDy = znccBestGDy / ref.scaleY
            }
        } else {
            actualDy = predictedCumulativeDelta.y
        }

        var resultBlocks: [OverlayBlock] = []
        var matchedBlockCount = 0
        let hasSignificantScroll = abs(actualDy) >= 5.0

        for block in scrollingCandidates {
            let blockUnmovedCost = Self.computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: 0, dy: 0)
            let shiftedRect = block.rect.offsetBy(dx: actualDx, dy: actualDy)
            let visibleInter = shiftedRect.intersection(screenBounds)
            let isOnScreen = !visibleInter.isNull
                && visibleInter.height >= min(8, block.rect.height * 0.20)
                && visibleInter.width >= min(8, block.rect.width * 0.20)

            if hasSignificantScroll {
                let blockShiftedCost = isOnScreen
                    ? Self.computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: actualDx, dy: actualDy)
                    : 1.0

                if blockUnmovedCost < 0.050 && blockUnmovedCost + 0.040 < blockShiftedCost {
                    resultBlocks.append(block)
                    matchedBlockCount += 1
                    continue
                }
            }

            if isOnScreen {
                let blockShiftedCost = Self.computeBlockPatchCost(
                    ref: ref,
                    cur: cur,
                    rect: block.rect,
                    dx: actualDx,
                    dy: actualDy
                )
                var movedBlock = block
                movedBlock.rect = shiftedRect
                resultBlocks.append(movedBlock)
                if blockShiftedCost < 0.38 || isViewingSameTab {
                    matchedBlockCount += 1
                }
            }
        }

        for block in outsideBlocks {
            let cost = Self.computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: 0, dy: 0)
            if cost < 0.32 {
                resultBlocks.append(block)
                matchedBlockCount += 1
            }
        }

        if resultBlocks.isEmpty {
            return ScrollTrackResult(status: .targetLost)
        }
        if !isViewingSameTab && matchedBlockCount == 0 && unmovedCost > 0.36 {
            return ScrollTrackResult(status: .targetLost)
        }

        return ScrollTrackResult(
            status: .tracked(
                blocks: resultBlocks,
                cumulativeDelta: CGPoint(x: actualDx, y: actualDy)
            )
        )
    }

    // MARK: - Window & Tab Detection Under Mouse

    static func windowTabContextUnderMouse(in screen: NSScreen) -> WindowTabContext? {
        let mouse = NSEvent.mouseLocation
        guard NSMouseInRect(mouse, screen.frame, false) else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgMouse = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let screenCGOrigin = CGPoint(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY
        )

        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }

            guard cgBounds.width >= 160, cgBounds.height >= 160 else { continue }
            if cgBounds.contains(cgMouse) {
                let localRect = CGRect(
                    x: cgBounds.minX - screenCGOrigin.x,
                    y: cgBounds.minY - screenCGOrigin.y,
                    width: cgBounds.width,
                    height: cgBounds.height
                ).intersection(CGRect(origin: .zero, size: screen.frame.size))

                let windowTitle = (info[kCGWindowName as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                return WindowTabContext(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    title: windowTitle,
                    bounds: localRect
                )
            }
        }
        return nil
    }

    // MARK: - Nonisolated Image, 1D Edge ZNCC & Patch Matching Helpers

    nonisolated private static func computeTabHeaderStripCost(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        windowRect: CGRect
    ) -> Double {
        let stripRect = CGRect(
            x: windowRect.minX + min(24, windowRect.width * 0.05),
            y: windowRect.minY + 4,
            width: max(40, windowRect.width - min(48, windowRect.width * 0.10)),
            height: min(52, max(24, windowRect.height * 0.12))
        )
        return computeBlockPatchCost(ref: ref, cur: cur, rect: stripRect, dx: 0, dy: 0)
    }

    nonisolated private static func makeGrayscaleFrame(
        from image: CGImage,
        canvasSize: CGSize,
        windowRect: CGRect?
    ) -> GrayscaleFrame? {
        let targetWidth = max(200, min(560, Int(canvasSize.width * 0.35)))
        let targetHeight = max(130, min(380, Int(canvasSize.height * 0.35)))
        let bandCount = 4

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        let scaleX = CGFloat(targetWidth) / max(1, canvasSize.width)
        let scaleY = CGFloat(targetHeight) / max(1, canvasSize.height)

        var gradients = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        var bandMeans = [UInt8](repeating: 0, count: targetHeight * bandCount)
        var bandGradients = [UInt8](repeating: 0, count: targetHeight * bandCount)
        let bandWidth = max(1, targetWidth / bandCount)

        // 창 내부 본문 가로 범위 (좌우 테두리 및 우측 스크롤바 제외)
        let win = windowRect ?? CGRect(origin: .zero, size: canvasSize)
        let edgeStartX = max(1, Int((win.minX + win.width * 0.12) * scaleX))
        let edgeEndX = min(targetWidth - 2, Int((win.maxX - win.width * 0.12) * scaleX))
        let validRangeX = edgeEndX > edgeStartX ? (edgeStartX..<edgeEndX) : (1..<(targetWidth - 1))
        let invWidth = 1.0 / Float(max(1, validRangeX.count))

        var rawRowEdge = [Float](repeating: 0, count: targetHeight)
        var rawBandEdges = [[Float]](repeating: [Float](repeating: 0, count: targetHeight), count: bandCount)

        for y in 0..<targetHeight {
            let prevRow = max(0, y - 1) * targetWidth
            let nextRow = min(targetHeight - 1, y + 1) * targetWidth
            let curRow = y * targetWidth

            for b in 0..<bandCount {
                let startX = max(1, b * bandWidth)
                let endX = (b == bandCount - 1) ? (targetWidth - 1) : min(targetWidth - 1, (b + 1) * bandWidth)
                let count = max(1, endX - startX)
                var sumLum = 0
                var sumGrad = 0
                var bandEdgeSum = 0

                for x in startX..<endX {
                    let lum = Int(pixels[curRow + x])
                    let grad = abs(Int(pixels[nextRow + x]) - Int(pixels[prevRow + x]))
                    let dx = abs(Int(pixels[curRow + x + 1]) - Int(pixels[curRow + x - 1]))
                    gradients[curRow + x] = UInt8(clamping: grad)
                    sumLum += lum
                    sumGrad += grad
                    bandEdgeSum += dx + grad
                }
                bandMeans[y * bandCount + b] = UInt8(clamping: sumLum / count)
                bandGradients[y * bandCount + b] = UInt8(clamping: sumGrad / count)
                rawBandEdges[b][y] = Float(bandEdgeSum) / Float(count)
            }

            var edgeSum: Int = 0
            for x in validRangeX {
                let dx = abs(Int(pixels[curRow + x + 1]) - Int(pixels[curRow + x - 1]))
                let dy = Int(gradients[curRow + x])
                edgeSum += dx + dy
            }
            rawRowEdge[y] = Float(edgeSum) * invWidth
        }

        // 로컬 평균(±8행)을 제거한 고주파 에지 프로파일 생성 (배경 밝기 영향을 제거하고 텍스트 줄 간격만 추출)
        var rowHighPassEdge = [Float](repeating: 0, count: targetHeight)
        var bandHighPassEdge = [[Float]](repeating: [Float](repeating: 0, count: targetHeight), count: bandCount)
        let windowRadius = 8
        for y in 0..<targetHeight {
            let lo = max(0, y - windowRadius)
            let hi = min(targetHeight - 1, y + windowRadius)
            let spanCount = Float(hi - lo + 1)
            var sum: Float = 0
            for k in lo...hi {
                sum += rawRowEdge[k]
            }
            rowHighPassEdge[y] = rawRowEdge[y] - (sum / spanCount)

            for b in 0..<bandCount {
                var bSum: Float = 0
                for k in lo...hi {
                    bSum += rawBandEdges[b][k]
                }
                bandHighPassEdge[b][y] = rawBandEdges[b][y] - (bSum / spanCount)
            }
        }

        return GrayscaleFrame(
            width: targetWidth,
            height: targetHeight,
            scaleX: scaleX,
            scaleY: scaleY,
            pixels: pixels,
            gradients: gradients,
            bandCount: bandCount,
            bandMeans: bandMeans,
            bandGradients: bandGradients,
            rowHighPassEdge: rowHighPassEdge,
            bandHighPassEdge: bandHighPassEdge
        )
    }

    nonisolated private static func computeProfileZNCC(
        refProfile: [Float],
        curProfile: [Float],
        startY: Int,
        endY: Int,
        gDy: Int
    ) -> Double {
        var dot: Float = 0
        var normRef: Float = 0
        var normCur: Float = 0

        for y in startY..<endY {
            let r = refProfile[y]
            let c = curProfile[y + gDy]
            dot += r * c
            normRef += r * r
            normCur += c * c
        }

        let denom = (normRef * normCur).squareRoot()
        guard denom > 1.0 else { return 0.0 }
        return Double(dot / denom)
    }

    /// 전체 폭 프로파일과 4개 가로 서브 컬럼 프로파일의 ZNCC를 결합하여 고정 사이드바 등에서도 안정적인 상관계수를 반환한다.
    nonisolated private static func computeMultiBandRowEdgeZNCC(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        minYScreen: CGFloat,
        maxYScreen: CGFloat,
        gDy: Int
    ) -> Double {
        let minY = max(2, Int(minYScreen * ref.scaleY))
        let maxY = min(ref.height - 2, Int(maxYScreen * ref.scaleY))
        let startY = max(minY, minY - gDy)
        let endY = min(maxY, maxY - gDy)
        let overlap = endY - startY
        guard overlap >= 16 else { return 0.0 }

        let fullZNCC = computeProfileZNCC(
            refProfile: ref.rowHighPassEdge,
            curProfile: cur.rowHighPassEdge,
            startY: startY,
            endY: endY,
            gDy: gDy
        )

        guard ref.bandHighPassEdge.count == cur.bandHighPassEdge.count, !ref.bandHighPassEdge.isEmpty else {
            return fullZNCC
        }

        var bandScores: [Double] = []
        bandScores.reserveCapacity(ref.bandHighPassEdge.count)
        for b in 0..<ref.bandHighPassEdge.count {
            let score = computeProfileZNCC(
                refProfile: ref.bandHighPassEdge[b],
                curProfile: cur.bandHighPassEdge[b],
                startY: startY,
                endY: endY,
                gDy: gDy
            )
            bandScores.append(score)
        }
        bandScores.sort(by: >)
        let top2Mean = bandScores.count >= 2 ? (bandScores[0] + bandScores[1]) * 0.5 : (bandScores.first ?? fullZNCC)
        return max(fullZNCC, top2Mean)
    }

    /// 0부터 예측 스크롤 오프셋(predGDy) 주변까지 다중 밴드 1D ZNCC가 가장 높은 실제 수직 이동량을 서브픽셀 정밀도로 찾는다.
    nonisolated private static func findBestShiftByMultiBandEdgeZNCC(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        minYScreen: CGFloat,
        maxYScreen: CGFloat,
        predGDy: Int
    ) -> (CGFloat, Double) {
        let minY = max(2, Int(minYScreen * ref.scaleY))
        let maxY = min(ref.height - 2, Int(maxYScreen * ref.scaleY))
        let roiH = maxY - minY
        guard roiH >= 20 else { return (CGFloat(predGDy), 0.0) }

        let maxSearch = min(ref.height * 3 / 4, max(abs(predGDy) + 28, Int(Double(roiH) * 0.78)))
        let searchLo = max(-maxSearch, min(0, predGDy) - 28)
        let searchHi = min(maxSearch, max(0, predGDy) + 28)
        guard searchLo <= searchHi else { return (CGFloat(predGDy), 0.0) }

        let count = searchHi - searchLo + 1
        var scores = [Double](repeating: -1.0, count: count)
        var bestIdx = 0
        var bestZNCC = -1.0

        for i in 0..<count {
            let gDy = searchLo + i
            let zncc = computeMultiBandRowEdgeZNCC(
                ref: ref,
                cur: cur,
                minYScreen: minYScreen,
                maxYScreen: maxYScreen,
                gDy: gDy
            )
            scores[i] = zncc
            if zncc > bestZNCC {
                bestZNCC = zncc
                bestIdx = i
            }
        }

        let bestGDy = searchLo + bestIdx
        var subpixelOffset: Double = 0.0
        if bestIdx > 0 && bestIdx < count - 1 {
            let sLeft = scores[bestIdx - 1]
            let sMid = scores[bestIdx]
            let sRight = scores[bestIdx + 1]
            let denom = 2.0 * (sLeft - 2.0 * sMid + sRight)
            if abs(denom) > 1e-5 {
                let delta = (sLeft - sRight) / denom
                if abs(delta) <= 0.5 {
                    subpixelOffset = delta
                }
            }
        }

        return (CGFloat(Double(bestGDy) + subpixelOffset), bestZNCC)
    }

    /// 각 기준 블록의 미이동 비용과 이동 후 비용을 비교하여 고정 UI 블록(pinnedIds)과 매칭 블록 수를 반환한다.
    nonisolated private static func evaluateBlockMatchesAndPins(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        blocks: [OverlayBlock],
        windowRect: CGRect,
        screenBounds: CGRect,
        actualDy: CGFloat
    ) -> (pinnedIds: Set<Int>, matchedCount: Int, visibleCandidateCount: Int) {
        var pinnedIds = Set<Int>()
        var matchedCount = 0
        var visibleCandidateCount = 0
        let hasSignificantScroll = abs(actualDy) >= 6.0

        for block in blocks.prefix(18) {
            guard windowRect.intersects(block.rect) else { continue }
            let unmovedCost = computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: 0, dy: 0)
            let shiftedRect = block.rect.offsetBy(dx: 0, dy: actualDy)
            let visibleInter = shiftedRect.intersection(screenBounds)
            let isOnScreen = !visibleInter.isNull
                && visibleInter.height >= min(8, block.rect.height * 0.20)
                && visibleInter.width >= min(8, block.rect.width * 0.20)

            let shiftedCost = isOnScreen
                ? computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: 0, dy: actualDy)
                : 1.0

            if hasSignificantScroll && unmovedCost < 0.045 && unmovedCost + 0.045 < shiftedCost {
                pinnedIds.insert(block.id)
                matchedCount += 1
                visibleCandidateCount += 1
                continue
            }

            if isOnScreen {
                visibleCandidateCount += 1
                if shiftedCost < 0.36 {
                    matchedCount += 1
                }
            }
        }

        return (pinnedIds, matchedCount, visibleCandidateCount)
    }

    nonisolated private static func computeContentRegionSAD(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        windowRect: CGRect,
        contentMinY: CGFloat,
        contentMaxY: CGFloat,
        gDy: Int
    ) -> Double {
        let minX = max(2, Int((windowRect.minX + windowRect.width * 0.12) * ref.scaleX))
        let maxX = min(ref.width - 2, Int((windowRect.maxX - windowRect.width * 0.12) * ref.scaleX))
        let minY = max(2, Int(contentMinY * ref.scaleY))
        let maxY = min(ref.height - 2, Int(contentMaxY * ref.scaleY))

        let startY = max(minY, minY - gDy)
        let endY = min(maxY, maxY - gDy)
        guard maxX - minX >= 12, endY - startY >= 12 else { return 1.0 }

        var diffSum = 0
        var count = 0
        let stepX = max(1, (maxX - minX) / 36)
        let stepY = max(1, (endY - startY) / 36)

        var y = startY
        while y < endY {
            let curY = y + gDy
            let refRow = y * ref.width
            let curRow = curY * cur.width
            var x = minX
            while x < maxX {
                diffSum += abs(Int(ref.pixels[refRow + x]) - Int(cur.pixels[curRow + x]))
                count += 1
                x += stepX
            }
            y += stepY
        }

        guard count > 0 else { return 1.0 }
        return Double(diffSum) / Double(count * 255)
    }

    nonisolated private static func evaluateShiftCost(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        blocks: [OverlayBlock],
        gDx: Int,
        gDy: Int
    ) -> Double {
        let dx = CGFloat(gDx) / ref.scaleX
        let dy = CGFloat(gDy) / ref.scaleY

        var weightedSum = 0.0
        var weightTotal = 0.0

        for block in blocks.prefix(12) {
            let cost = computeBlockPatchCost(ref: ref, cur: cur, rect: block.rect, dx: dx, dy: dy)
            if cost < 0.95 {
                let weight = max(1.0, Double(block.rect.width * block.rect.height))
                weightedSum += cost * weight
                weightTotal += weight
            }
        }

        guard weightTotal > 0 else { return 1.0 }
        return weightedSum / weightTotal
    }

    nonisolated private static func computeBlockPatchCost(
        ref: GrayscaleFrame,
        cur: GrayscaleFrame,
        rect: CGRect,
        dx: CGFloat,
        dy: CGFloat
    ) -> Double {
        let gDx = Int((dx * ref.scaleX).rounded())
        let gDy = Int((dy * ref.scaleY).rounded())

        let expanded = rect.insetBy(dx: -8, dy: -6)
        let minX = max(0, Int(expanded.minX * ref.scaleX))
        let maxX = min(ref.width, Int(expanded.maxX * ref.scaleX))
        let minY = max(0, Int(expanded.minY * ref.scaleY))
        let maxY = min(ref.height, Int(expanded.maxY * ref.scaleY))

        let startX = max(minX, minX - gDx)
        let endX = min(maxX, maxX - gDx)
        let startY = max(minY, minY - gDy)
        let endY = min(maxY, maxY - gDy)

        guard endX - startX >= 2, endY - startY >= 2 else { return 1.0 }

        var lumDiffSum = 0
        var gradDiffSum = 0
        var count = 0

        for y in startY..<endY {
            let curY = y + gDy
            guard curY >= 0, curY < cur.height else { continue }
            let refRow = y * ref.width
            let curRow = curY * cur.width

            for x in startX..<endX {
                let curX = x + gDx
                guard curX >= 0, curX < cur.width else { continue }
                lumDiffSum += abs(Int(ref.pixels[refRow + x]) - Int(cur.pixels[curRow + curX]))
                gradDiffSum += abs(Int(ref.gradients[refRow + x]) - Int(cur.gradients[curRow + curX]))
                count += 1
            }
        }

        guard count > 0 else { return 1.0 }
        let lumNorm = Double(lumDiffSum) / Double(count * 255)
        let gradNorm = Double(gradDiffSum) / Double(count * 255)
        return lumNorm * 0.65 + gradNorm * 0.35
    }
}
