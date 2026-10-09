import AppKit

extension Workspace {
    /// Where layoutWorkspace would put each tiled window, without touching AX, weights or caches.
    /// Rects are global top-left points, like `lastAppliedLayoutPhysicalRect`. Tiles and accordion
    /// are exact (they share `tileFrames`/`accordionFrames` with the live pass). Scrolling and tabs
    /// show one page at a time, so every page previews as the full container rect.
    /// `asTiles` previews every container as tiles instead (same orientation and weights) and a
    /// fullscreen window in its tile: where `layout tiles` everywhere would put each window, so no
    /// window hides another. aero-helper's overview draws workspaces this way.
    /// Floating windows are not included; see `Window.floatingRestoreRect`.
    @MainActor
    func previewLayoutRects(asTiles: Bool = false) -> [UInt32: Rect] {
        var result: [UInt32: Rect] = [:]
        if isEffectivelyEmpty { return result }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps(forWorkspace: name)
        let context = LayoutContext(self, asTiles: asTiles)
        rootTilingContainer.preview(rect.topLeftCorner, width: rect.width, height: rect.height - 1,
                                    virtual: rect, context, into: &result)
        return result
    }
}

extension TreeNode {
    @MainActor
    fileprivate func preview(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect,
                             _ context: LayoutContext, into result: inout [UInt32: Rect])
    {
        switch nodeCases {
            case .window(let window):
                if window.isAwaitingOnWindowDetected { return }
                if !context.asTiles && window.isFullscreen
                    && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive
                {
                    let monitor = context.workspace.workspaceMonitor
                    result[window.windowId] = window.noOuterGapsInFullscreen
                        ? monitor.visibleRect
                        : monitor.visibleRectPaddedByOuterGaps(forWorkspace: context.workspace.name)
                } else {
                    result[window.windowId] = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
                }
            case .tilingContainer(let container):
                let layout: Layout = if context.asTiles {
                    .tiles
                } else if !TrayMenuModel.shared.isEnabled && (container.layout == .scrolling || container.layout == .tabs) {
                    .accordion // Same layout substitution as layoutRecursive's .tilingContainer case
                } else {
                    container.layout
                }
                let frames: [TilingContainer.ChildFrame] = switch layout {
                    case .tiles: container.tileFrames(point, width: width, height: height, virtual: virtual,
                                                      gaps: context.resolvedGaps, maxWindowWidth: context.maxWindowWidth)
                    case .accordion: container.accordionFrames(point, width: width, height: height, virtual: virtual)
                    case .scrolling, .tabs: container.children.map {
                            .init(child: $0, point: point, width: width, height: height, virtual: virtual, weight: 0)
                        }
                }
                for f in frames {
                    f.child.preview(f.point, width: f.width, height: f.height, virtual: f.virtual, context, into: &result)
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return
        }
    }
}
