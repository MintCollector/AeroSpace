import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws -> [TabHeaderSnapshot] {
        if isEffectivelyEmpty { return [] }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps(forWorkspace: name)
        let context = LayoutContext(self)
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
        return context.tabHeaderSnapshots
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    if window.isAwaitingOnWindowDetected { continue }
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.isAwaitingOnWindowDetected { break }
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    window.unhideFromCorner()
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                // Restore every page/tab as overlapping windows without changing their saved layout or weights.
                let layout = !TrayMenuModel.shared.isEnabled && (container.layout == .scrolling || container.layout == .tabs)
                    ? Layout.accordion : container.layout
                switch layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                    case .scrolling:
                        try await container.layoutScrolling(point, width: width, height: height, virtual: virtual, context)
                    case .tabs:
                        try await container.layoutTabs(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        unhideFromCorner()
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        // Dialogs can inherit an off-screen position even when they belong to the active workspace.
        if let currentMonitor, let windowRect,
           workspace != currentMonitor.activeWorkspace || (!isLeftMouseButtonDown && !currentMonitor.visibleRect.contains(windowRect.center))
        {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps(forWorkspace: context.workspace.name)
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    /// Children that take part in the layout. Windows still awaiting their `on-window-detected`
    /// callbacks are left out: reserving space for a window that is about to be moved elsewhere
    /// makes its siblings jump, and the space is handed back a moment later.
    @MainActor
    private var layoutChildren: [TreeNode] {
        children.filter { ($0 as? Window)?.isAwaitingOnWindowDetected != true }
    }

    struct ChildFrame {
        let child: TreeNode
        let point: CGPoint
        let width: CGFloat
        let height: CGFloat
        let virtual: Rect
        /// Weight along the container orientation after normalization (tiles only)
        let weight: CGFloat
    }

    /// Where each child of a `tiles` container goes. Pure: weights are read, not normalized in place.
    /// The caller applies `weight` when it is laying out for real.
    @MainActor
    func tileFrames(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect,
                    gaps: ResolvedGaps, maxWindowWidth: CGFloat?) -> [ChildFrame]
    {
        var point = point
        var virtualPoint = virtual.topLeftCorner
        let effectiveChildren = layoutChildren

        guard let delta = ((orientation == .h ? width : height) - CGFloat(effectiveChildren.sumOfDouble { $0.getWeight(orientation) }))
            .div(effectiveChildren.count) else { return [] }

        let lastIndex = effectiveChildren.indices.last
        let rawGap = gaps.inner.get(orientation).toDouble()

        // Center clamped children as a group so excess space goes to outer edges
        if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0 {
            var totalOccupied: CGFloat = 0
            for (i, child) in effectiveChildren.enumerated() {
                let adjustedWeight = CGFloat(child.getWeight(orientation) + delta)
                let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
                totalOccupied += min(adjustedWeight, maxWidth + gap)
            }
            point = CGPoint(x: point.x + (width - totalOccupied) / 2, y: point.y)
        }

        var frames: [ChildFrame] = []
        for (i, child) in effectiveChildren.enumerated() {
            let weight = child.getWeight(orientation) + delta
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)

            var childWidth = orientation == .h ? weight - gap : width
            if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0, childWidth > maxWidth {
                childWidth = maxWidth
            }

            frames.append(ChildFrame(
                child: child,
                point: i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: childWidth,
                height: orientation == .v ? weight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? weight : width,
                    height: orientation == .v ? weight : height,
                ),
                weight: weight,
            ))
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(weight) : virtualPoint.addingYOffset(weight)
            if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0 {
                point = point.addingXOffset(min(weight, maxWidth + gap))
            } else {
                point = orientation == .h ? point.addingXOffset(weight) : point.addingYOffset(weight)
            }
        }
        return frames
    }

    /// Where each child of an `accordion` container goes. Pure.
    @MainActor
    func accordionFrames(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect) -> [ChildFrame] {
        guard let mostRecentChild else { return [] }
        let children = layoutChildren
        let mruIndex: Int = children.firstIndex { $0 === mostRecentChild } ?? 0
        let padding = CGFloat(config.accordionPadding)
        return children.enumerated().map { index, child in
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            return switch orientation {
                case .h: ChildFrame(child: child, point: point + CGPoint(x: lPadding, y: 0),
                                    width: width - rPadding - lPadding, height: height, virtual: virtual, weight: 0)
                case .v: ChildFrame(child: child, point: point + CGPoint(x: 0, y: lPadding),
                                    width: width, height: height - lPadding - rPadding, virtual: virtual, weight: 0)
            }
        }
    }

    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        for f in tileFrames(point, width: width, height: height, virtual: virtual,
                            gaps: context.resolvedGaps, maxWindowWidth: context.maxWindowWidth)
        {
            f.child.setWeight(orientation, f.weight)
            try await f.child.layoutRecursive(f.point, width: f.width, height: f.height, virtual: f.virtual, context)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        for f in accordionFrames(point, width: width, height: height, virtual: virtual) {
            try await f.child.layoutRecursive(f.point, width: f.width, height: f.height, virtual: f.virtual, context)
        }
    }

    @MainActor
    fileprivate func layoutScrolling(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        clampScrollingIndex()
        switch children.count {
            case 0:
                return
            case 1:
                try await children[0].layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            default:
                let rawGap = context.resolvedGaps.inner.horizontal.toDouble()
                let peek = resolvedScrollingPeekWidth(viewportWidth: width, gap: rawGap, context)
                let pageWidth = (width - peek) / 2
                let lastVisibleIndex = scrollingIndex + (peek > 0 ? 2 : 1)
                for (index, child) in children.enumerated() {
                    // Park every page beyond the peek to avoid spilling onto adjacent monitors.
                    guard index >= scrollingIndex && index <= lastVisibleIndex else {
                        try await child.hideSubtree(in: context.hideCorner)
                        continue
                    }
                    let virtualX = virtual.topLeftX + CGFloat(index) * pageWidth
                    let physicalX = point.x + CGFloat(index - scrollingIndex) * pageWidth
                    let lPadding = index == scrollingIndex ? 0 : rawGap / 2
                    let rPadding = index == lastVisibleIndex ? 0 : rawGap / 2
                    try await child.layoutRecursive(
                        CGPoint(x: physicalX + lPadding, y: point.y),
                        width: pageWidth - lPadding - rPadding,
                        height: height,
                        virtual: Rect(topLeftX: virtualX, topLeftY: virtual.topLeftY, width: pageWidth, height: height),
                        context,
                    )
                }
        }
    }

    @MainActor
    private func resolvedScrollingPeekWidth(viewportWidth: CGFloat, gap: CGFloat, _ context: LayoutContext) -> CGFloat {
        let peek = CGFloat(config.scrollingPeekWidth)
        let pageWidth = (viewportWidth - peek) / 2
        // Invalid geometry keeps the original two-page layout. The gap must leave a visible sliver,
        // and each full page must remain wider than both the peek and its padding.
        guard scrollingIndex + 2 < children.count,
              !context.suppressScrollingPeek,
              gap >= 0,
              peek > gap / 2,
              pageWidth > max(peek, gap)
        else { return 0 }
        return peek
    }

    @MainActor
    fileprivate func layoutTabs(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let activeChild = mostRecentChild ?? children.first else { return }
        let headerHeight = TabHeaderMetrics.height
        let hasVisibleHeader = width >= TabHeaderMetrics.minTabWidth && height > headerHeight + 1
        let headerFrame = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: hasVisibleHeader ? headerHeight : 0)
        if hasVisibleHeader {
            let availableWidth = max(0, width - 2 * TabHeaderMetrics.horizontalPadding)
            let spacingCount = max(0, children.count - 1)
            let itemWidth = max(
                1,
                (availableWidth - CGFloat(spacingCount) * TabHeaderMetrics.itemSpacing) / CGFloat(max(1, children.count)),
            )
            var cursorX = TabHeaderMetrics.horizontalPadding
            var items: [TabHeaderItem] = []
            for (index, child) in children.enumerated() {
                guard let targetWindow = child.tabHeaderTargetWindow(),
                      let title = try await child.tabHeaderTitle()
                else { continue }
                let remaining = max(0, width - cursorX - TabHeaderMetrics.horizontalPadding)
                let currentWidth = min(itemWidth, remaining)
                if currentWidth <= 0 { break }
                let itemFrame = Rect(
                    topLeftX: cursorX,
                    topLeftY: TabHeaderMetrics.verticalPadding,
                    width: currentWidth,
                    height: headerHeight - 2 * TabHeaderMetrics.verticalPadding,
                )
                let closeButtonFrame = Rect(
                    topLeftX: max(
                        itemFrame.minX,
                        itemFrame.maxX - TabHeaderMetrics.closeButtonTrailingInset - TabHeaderMetrics.closeButtonSize,
                    ),
                    topLeftY: itemFrame.topLeftY + (itemFrame.height - TabHeaderMetrics.closeButtonSize) / 2,
                    width: min(TabHeaderMetrics.closeButtonSize, itemFrame.width),
                    height: min(TabHeaderMetrics.closeButtonSize, itemFrame.height),
                )
                let titleMaxX = max(itemFrame.minX, closeButtonFrame.minX - TabHeaderMetrics.closeButtonLeadingSpacing)
                let titleFrame = Rect(
                    topLeftX: itemFrame.topLeftX,
                    topLeftY: itemFrame.topLeftY,
                    width: max(0, titleMaxX - itemFrame.topLeftX),
                    height: itemFrame.height,
                )
                items.append(
                    TabHeaderItem(
                        id: "\(ObjectIdentifier(self).debugDescription)-\(index)-\(targetWindow.windowId)",
                        targetWindow: targetWindow,
                        title: title,
                        frame: itemFrame,
                        titleFrame: titleFrame,
                        closeButtonFrame: closeButtonFrame,
                        isActive: child == activeChild,
                    ),
                )
                cursorX += currentWidth + TabHeaderMetrics.itemSpacing
            }
            if !items.isEmpty {
                context.tabHeaderSnapshots.append(
                    TabHeaderSnapshot(
                        id: ObjectIdentifier(self),
                        headerFrame: headerFrame,
                        items: items,
                    ),
                )
            }
        }
        for child in children where child != activeChild {
            try await child.hideSubtree(in: context.hideCorner)
        }
        let contentPoint = hasVisibleHeader ? point + CGPoint(x: 0, y: headerHeight) : point
        let contentHeight = hasVisibleHeader ? height - headerHeight : height
        let contentVirtual = hasVisibleHeader
            ? Rect(topLeftX: virtual.topLeftX, topLeftY: virtual.topLeftY + headerHeight, width: virtual.width, height: virtual.height - headerHeight)
            : virtual
        try await activeChild.layoutRecursive(contentPoint, width: width, height: contentHeight, virtual: contentVirtual, context)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func hideSubtree(in corner: OptimalHideCorner) async throws {
        switch nodeCases {
            case .window(let window):
                try await window.hideInCorner(corner)
            case .tilingContainer(let container):
                container.lastAppliedLayoutPhysicalRect = nil
                for child in container.children {
                    try await child.hideSubtree(in: corner)
                }
            case .workspace, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer, .floatingWindowsContainer:
                return
        }
    }
}
