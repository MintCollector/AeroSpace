import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    var isSticky: Bool = false

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    // A macOS native-tab group (e.g. Finder/Safari "Merge All Windows") exposes N window ids but
    // only the active tab is a real frame. Collapse the group onto a single surviving MacWindow and
    // discard the inactive tab siblings so the tree tiles the group as one window. Ported from
    // seatedro/i4 (Add native tab support), minus its immutable-tree TreeStore sync (we have none).
    @MainActor
    static func reconcileNativeTabGroup(_ group: NativeTabWindowGroup, macApp: MacApp) async throws {
        let managedMembers = group.memberWindowIds.compactMap { allWindowsMap[$0] }
        guard let survivor = allWindowsMap[group.activeWindowId] ?? managedMembers.first else { return }

        for window in managedMembers where window !== survivor {
            window.discardNativeTabSidecar()
        }

        if survivor.windowId != group.activeWindowId {
            try await survivor.adoptNativeTabWindowId(group.activeWindowId, macApp: macApp)
        }
    }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp, nativeTabGroups: [NativeTabWindowGroup]? = nil) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        // Reuse the groups already computed during refresh when the caller passes them — an in-memory
        // lookup, no AX. Only fall back to a fresh AX query (a full-app traversal per new window) on
        // paths that have no precomputed groups, e.g. getFocusedWindow.
        if let group = try await containingNativeTabGroup(windowId: windowId, macApp: macApp, precomputed: nativeTabGroups),
           group.memberWindowIds.contains(where: { allWindowsMap[$0] != nil })
        {
            try await reconcileNativeTabGroup(group, macApp: macApp)
            if let existing = allWindowsMap[group.activeWindowId] { return existing }
        }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        let workspace = isStartup
            ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace
            : focus.workspace
        let (windowType, isAxReady) = try await macApp.getAxUiElementWindowTypeAndReadiness(windowId, getWindowLevel(for: windowId), .cancellable)

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        // Must be inside the atomic section because auto tiling may create a container for the new window
        let data = unbindAndGetBindingDataForNewWindow(windowType, workspace, window: nil)
        let parentKind: String = switch data.parent {
            case is TilingContainer: "tiling"
            case is FloatingWindowsContainer: "floating"
            case is MacosPopupWindowsContainer: "popup"
            default: String(describing: type(of: data.parent))
        }
        let ws = data.parent.nodeWorkspace?.name ?? "?"
        focusLog("[getOrRegister] NEW window id=\(windowId) app=\(macApp.name ?? "?") bundle=\(macApp.rawAppBundleId ?? "?") → \(parentKind) on ws '\(ws)'")
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        window.isAwaitingOnWindowDetected = true
        if !isAxReady {
            window.provisionalFloatDeadline = Date().addingTimeInterval(provisionalFloatRecheckWindow)
            focusLog("[getOrRegister] provisional float id=\(windowId) app=\(macApp.name ?? "?"): AX not ready, will re-classify")
        }
        allWindowsMap[windowId] = window
        defer { window.isAwaitingOnWindowDetected = false }

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await tryOnWindowDetected(window)
        }
        return window
    }

    @MainActor
    private static func containingNativeTabGroup(
        windowId: UInt32,
        macApp: MacApp,
        precomputed: [NativeTabWindowGroup]?,
    ) async throws -> NativeTabWindowGroup? {
        if let precomputed {
            return precomputed.first { $0.memberWindowIds.contains(windowId) }
        }
        return try await macApp.nativeTabGroup(containing: windowId)
    }

    // Drop an inactive native-tab sibling from the tree. Unlike garbageCollect, this is NOT a real
    // window close — the underlying window still exists, merged into the active tab — so it must not
    // populate the closed-windows cache or emit a windowDestroyed event.
    @MainActor
    func discardNativeTabSidecar() {
        guard MacWindow.allWindowsMap.removeValue(forKey: windowId) != nil else { return }
        if parent != nil {
            _ = unbindFromParent()
        }
    }

    // Re-point a surviving MacWindow at the active tab's window id (macOS may report a different id
    // for the active tab than the one we originally registered the group under).
    @MainActor
    private func adoptNativeTabWindowId(_ newWindowId: UInt32, macApp: MacApp) async throws {
        check(self.macApp === macApp)
        let oldWindowId = windowId
        MacWindow.allWindowsMap.removeValue(forKey: oldWindowId)
        macApp.nativeTabWindowIdChanged(from: oldWindowId, to: newWindowId)
        windowId = newWindowId
        MacWindow.allWindowsMap[newWindowId] = self
        if let rect = try await macApp.getAxRect(newWindowId, .cancellable) {
            lastFloatingSize = rect.size
        }
        try await debugWindowsIfRecording(self, .cancellable)
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        let wasFocused = focus.windowOrNil == self
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        TabHeaderTitleCache.shared.invalidate(windowId: windowId)
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let destroyedWorkspaceName = nodeWorkspace?.name
        let tiledCount: Int? = {
            guard let ws = nodeWorkspace else { return nil }
            let allTiled = ws.rootTilingContainer.allLeafWindowsRecursive
            let selfIsTiled = allTiled.contains(where: { $0.windowId == self.windowId })
            return allTiled.count - (selfIsTiled ? 1 : 0)
        }()
        broadcastEvent(.windowDestroyed(
            windowId: windowId,
            workspace: destroyedWorkspaceName,
            appBundleId: app.rawAppBundleId,
            appName: app.name,
            tiledWindowCount: tiledCount,
        ))
        lastWindowDestroyedDate = .now
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = resolveFocusAfterWindowRemoval(
                        wasFocused: wasFocused,
                        previousWindow: previousFocusedWindowOrNil,
                        workspace: deadWindowWorkspace,
                    )
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    @MainActor override func nativeRaise() {
        macApp.nativeRaise(windowId)
    }

    override func closeAxWindow() {
        TabHeaderTitleCache.shared.invalidate(windowId: windowId)
        // Don't eagerly GC — the close may be intercepted (e.g., "save changes?" dialog).
        // The refresh cycle handles GC once the window is confirmed dead via
        // kAXUIElementDestroyedNotification or the scheduled heavy refresh.
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    /// - Parameter autoTile: enable-auto-tiling. The window (re)enters the tiling tree the same way as a new window
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false, autoTile: Bool = false) async throws {
        let data: BindingData
        if forceTile {
            data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: self, autoTile: autoTile)
        } else {
            let macWindow = self.asMacWindow()
            let windowType = try await macWindow.macApp.getAxUiElementWindowType(macWindow.windowId, getWindowLevel(for: macWindow.windowId), cm)
            data = unbindAndGetBindingDataForNewWindow(windowType, workspace, window: self)
        }
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowType: AxUiElementWindowType, _ workspace: Workspace, window: Window?) -> BindingData {
    switch windowType {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?, autoTile: Bool = false) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    return workspace.prepareTilingWindowInsertion(autoTile: window == nil || autoTile)
}

@MainActor
func tryOnWindowDetected(_ window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
        tiledWindowCount: window.nodeWorkspace?.rootTilingContainer.allLeafWindowsRecursive.count,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        if callback.noFocus {
            // Arm before (and regardless of) the run commands, so the suppression is active
            // even if a run command fails or moves the window.
            armNoFocusSuppression(for: window)
        }
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                return await matcher.matches(window)
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}

extension LegacyWindowDetectedCallbackMatcher {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        if let startupMatcher = duringAeroSpaceStartup, startupMatcher != isStartup {
            return false
        }
        if let regex = windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
            return false
        }
        if let appIds, !appIds.contains(window.app.rawAppBundleId ?? "") {
            return false
        }
        if let regex = appIdRegexSubstring, !(window.app.rawAppBundleId ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let regex = appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}
