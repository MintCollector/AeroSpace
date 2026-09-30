import AppKit
import Common

open class Window: TreeNode, Hashable {
    // var (not let) so native-tab reconciliation can re-point a surviving window to the
    // active tab's window id when macOS reassigns it. See MacWindow.adoptNativeTabWindowId.
    var windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    /// The window is already bound to the tree, but its `on-window-detected` callbacks haven't
    /// run yet. Until they have, its place in the tree isn't settled: a callback may still move it
    /// to another workspace, or make it floating. Laying it out in the meantime applies geometry
    /// that is about to be thrown away, and takes space away from its siblings for a frame.
    var isAwaitingOnWindowDetected: Bool = false
    /// The window was floated as a dialog only because its app didn't answer the AX reads the
    /// classification relies on (typical while an app is launching). Until this deadline passes,
    /// refresh re-classifies it and tiles it if it turns out to be a regular window. Cleared once
    /// the app answers, or when a `layout` command takes explicit control of the window.
    var provisionalFloatDeadline: Date? = nil
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    var isExplicitlyUnmanaged: Bool = false
    var lastFocusedAt: UInt64 = 0 // Monotonically increasing value, 0 means never focused
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    @MainActor func nativeFocus() { die("Not implemented") }
    /// Raise the window to the top of its app's z-order without activating the app or changing focus.
    @MainActor func nativeRaise() {} // best-effort, no-op for non-mac windows
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }

    /// Save the current window position so it can be restored later by unhideFromCorner.
    /// Returns false when current AX/screen state is unsafe, so caller must not move the window to a hide corner.
    @MainActor
    @discardableResult
    func saveFloatingPositionIfNeeded() async throws -> Bool {
        guard !isHiddenInCorner else { return true }
        guard !screenSleepWakeInProgress else { return false }
        guard let workspace = nodeWorkspace else { return false }
        let workspaceRect = workspace.workspaceMonitor.rect
        let visibleRect = workspace.workspaceMonitor.visibleRect
        guard let windowRect = try await getAxRect(.cancellable) else { return false }
        // Check again after the suspension point above. Another hideInCorner/unhideFromCorner
        // cycle may have already saved the correct position while this AX read was awaiting.
        guard !screenSleepWakeInProgress else { return false }
        guard !isHiddenInCorner else { return true }
        guard let snapshot = floatingPositionSnapshot(
            windowRect: windowRect,
            workspaceRect: workspaceRect,
            visibleRect: visibleRect,
        ) else { return false }
        prevUnhiddenProportionalPositionInsideWorkspaceRect = snapshot
        // Upstream 649301b2: without this, unhide restores the position but not the size,
        // and the window gets nudged away from the right/bottom monitor edges.
        if isFloating {
            lastFloatingSize = windowRect.size
        }
        return true
    }

    private func floatingPositionSnapshot(windowRect: Rect, workspaceRect: Rect, visibleRect: Rect) -> CGPoint? {
        if workspaceRect.width <= 0 || workspaceRect.height <= 0 { return nil }

        let topLeftCorner = windowRect.topLeftCorner
        let absolutePoint = topLeftCorner - workspaceRect.topLeftCorner
        let snapshot = CGPoint(x: absolutePoint.x / workspaceRect.width, y: absolutePoint.y / workspaceRect.height)

        // Reject positions that look like AeroSpace hide corners.
        // Hide corners place window's top-left at visible monitor bottom edge, sometimes outside X bounds.
        // This protects against saving wrong positions after macOS wake from sleep.
        let tolerance: CGFloat = 5
        let isNearBottomEdge = topLeftCorner.y >= visibleRect.maxY - tolerance
        let isNearRightHideCorner = topLeftCorner.x >= visibleRect.maxX - tolerance
        let isNearLeftHideCorner = topLeftCorner.x + windowRect.width <= visibleRect.minX + tolerance
        let looksLikeHideCorner = isNearBottomEdge && (isNearLeftHideCorner || isNearRightHideCorner)
        return looksLikeHideCorner ? nil : snapshot
    }

    // Hides windows of invisible workspaces, and inactive tabs / off-screen scrolling pages.
    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard !screenSleepWakeInProgress else { return }
        guard let nodeMonitor else { return }
        // Don't move a floating window to a hide corner unless we know how to restore it.
        guard try await saveFloatingPositionIfNeeded() else { return }
        guard !screenSleepWakeInProgress else { return }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == KnownBundleId.zoom.rawValue ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == KnownBundleId.zoom.rawValue ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        lastAppliedLayoutPhysicalRect = nil
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
                self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
            case .tiling, .rootTilingContainer:
                // Tiling windows are positioned by layoutRecursive, safe to clear.
                self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
                lastAppliedLayoutPhysicalRect = nil // See below
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .shimContainerRelation:
                // Preserve saved position — window is in a temporary macOS state and will
                // need the position when it returns to floating.
                // The window was physically moved away while the workspace was hidden, so force the next layout pass
                // to re-apply its frame instead of assuming the cached rect is still on screen.
                lastAppliedLayoutPhysicalRect = nil
        }
    }

    var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
