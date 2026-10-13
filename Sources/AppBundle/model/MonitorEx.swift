import AppKit

extension MonitorInfo {
    @MainActor
    func visibleRectPaddedByOuterGaps(forWorkspace workspaceName: String? = nil) -> Rect {
        let gapsConfig: Gaps = if let workspaceName, let wsGaps = config.workspaceGaps[workspaceName] {
            wsGaps
        } else {
            config.gaps
        }
        let gaps = ResolvedGaps(gaps: gapsConfig, monitor: self)
        // A seam between two columns of a split screen (split-monitors) looks like the gap between two windows
        let seam = gaps.inner.horizontal.toDouble() / 2
        let left = rect.minX > screen.rect.minX ? seam : gaps.outer.left.toDouble()
        let right = rect.maxX < screen.rect.maxX ? seam : gaps.outer.right.toDouble()
        let topLeft = visibleRect.topLeftCorner
        return Rect(
            topLeftX: topLeft.x + left,
            topLeftY: topLeft.y + gaps.outer.top.toDouble(),
            width: visibleRect.width - left - right,
            height: visibleRect.height - gaps.outer.top.toDouble() - gaps.outer.bottom.toDouble(),
        )
    }

    @MainActor var monitorId_oneBased: Int? {
        let sorted = sortedMonitorInfos
        let origin = self.rect.topLeftCorner
        return sorted.firstIndex { $0.rect.topLeftCorner == origin }.map { $0 + 1 }
    }
}

extension MonitorInfo {
    func optimalHideCorner(monitors: [MonitorInfo]) -> OptimalHideCorner {
        let xOff = width * 0.1
        let yOff = height * 0.1
        // brc = bottomRightCorner
        let brc1 = rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: MonitorInfo, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        return monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
    }

    // Windows cannot be clipped and may enforce a minimum width, so even a distant monitor
    // to the right makes peeking unsafe. Use physical bounds to include menu-bar areas.
    func hasMonitorInRightSpillBand(monitors: [MonitorInfo]) -> Bool {
        let ownRect = rect
        return monitors.contains { monitor in
            let otherRect = monitor.rect
            guard otherRect.topLeftCorner != ownRect.topLeftCorner else { return false }
            return max(ownRect.maxX, otherRect.minX) < otherRect.maxX
                && max(ownRect.minY, otherRect.minY) < min(ownRect.maxY, otherRect.maxY)
        }
    }
}
