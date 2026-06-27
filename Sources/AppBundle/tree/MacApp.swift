import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]
    @MainActor static var failedRegistrationRetryAfter: [pid_t: Date] = [:]
    @MainActor private static var failedRegistrationFailures: [pid_t: Int] = [:]
    // Exponential backoff for failed AX registrations. The FIRST retry is fast: a just-launched app
    // whose AX API isn't subscribable for the first few ms must still get tiled promptly — a flat
    // multi-second delay made every new app appear to "hang" before tiling. Repeated failures (a
    // genuinely unsubscribable app) back off, doubling up to the cap, so we never retry in a tight
    // CPU-spiking loop — the property #2085 originally protected.
    static let failedRegistrationRetryDelay: TimeInterval = 0.1 // base / first-failure delay
    static let failedRegistrationMaxRetryDelay: TimeInterval = 5

    /// Decides whether a failed-registration retry for `pid` should be throttled (skipped).
    /// If a throttle deadline is set and still in the future, returns `true` (skip).
    /// If the deadline has passed, it is cleared and `false` is returned (proceed).
    /// The failure count is intentionally retained on expiry so a subsequent failure keeps backing
    /// off; it is reset only on success/destroy via `clearFailedRegistration`.
    /// `now` is injectable to keep this pure and testable.
    @MainActor static func shouldThrottleFailedRegistration(_ pid: pid_t, now: Date = Date()) -> Bool {
        if let retryAfter = failedRegistrationRetryAfter[pid] {
            if retryAfter > now { return true }
            failedRegistrationRetryAfter[pid] = nil
        }
        return false
    }

    /// Records a failed registration for `pid`, throttling retries with exponential backoff:
    /// `base * 2^priorFailures`, capped at `failedRegistrationMaxRetryDelay`.
    @MainActor static func recordFailedRegistration(_ pid: pid_t, now: Date = Date()) {
        let priorFailures = failedRegistrationFailures[pid] ?? 0
        let delay = min(failedRegistrationMaxRetryDelay, failedRegistrationRetryDelay * pow(2, Double(priorFailures)))
        failedRegistrationFailures[pid] = priorFailures + 1
        failedRegistrationRetryAfter[pid] = now.addingTimeInterval(delay)
    }

    /// Clears any throttle state for `pid` (called on successful registration and on destroy).
    @MainActor static func clearFailedRegistration(_ pid: pid_t) {
        failedRegistrationRetryAfter[pid] = nil
        failedRegistrationFailures[pid] = nil
    }

    private init(_ nsApp: NSRunningApplication, _ axApp: AXUIElement, _ axSubscriptions: [AxSubscription], _ thread: Thread) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        while true {
            if let existing = allAppsMap[pid] { return existing }
            if shouldThrottleFailedRegistration(pid) { return nil }
            try checkCancellation()
            if let wip = wipPids[pid] {
                try await wip.await()
                continue
            }
            let wip = AwaitableOneTimeBroadcastLatch()
            wipPids[pid] = wip

            let thread = Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                    let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                    // Bound every AX message to this app at 1s. The read path no longer uses AX
                    // (list-tree reads CGWindowList), but mutations (setAxFrame etc.) still do —
                    // a hung app then fails fast (~1s) instead of blocking the thread ~6s.
                    AXUIElementSetMessagingTimeout(axApp, 1.0)
                    let handlers: HandlerToNotifKeyMapping = unsafe [
                        (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                    ]
                    let job = RunLoopJob(.cancellable)
                    let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                    let isGood = !subscriptions.isEmpty
                    let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil
                    Task.startUnstructured { @MainActor in
                        if let app {
                            allAppsMap[pid] = app
                            clearFailedRegistration(pid)
                        } else {
                            recordFailedRegistration(pid)
                        }
                        await wip.signalToAll()
                        wipPids[pid] = nil
                    }
                    if isGood {
                        CFRunLoopRun()
                    }
                }
            }
            thread.name = "AxAppThread \(nsApp.idForDebug)"
            thread.start()
        }
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                guard windows.threadGuardedOrNil != nil else { return }
                windows.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let windowId = try await thread?.runInLoop(cm) { [nsApp, axApp, windows] (job) -> UInt32? in
            guard let axApp = axApp.threadGuardedOrNil else { return nil }
            guard windows.threadGuardedOrNil != nil else { return nil }
            return try axApp.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || monitors.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
        } else {
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                window.set(Ax.isMainAttr, true)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    /// Raise the window to the top of this app's z-order without activating the app (unlike nativeFocus).
    @MainActor func nativeRaise(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        _ = withWindowAsync(windowId, .cancellable) { window, job in
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { [axApp] window, job in
            guard let axApp = axApp.threadGuardedOrNil else { return }
            try disableAnimations(app: axApp, job) {
                try setFrame(window, topLeft, size, job)
            }
        }
    }

    func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [axApp] window, job in
            guard let axApp = axApp.threadGuardedOrNil else { semaphore.signal(); return }
            try? disableAnimations(app: axApp, job) {
                try setFrame(window, topLeft, size, job)
            }
            semaphore.signal()
        }
        switch job.isCancelled {
            case true: return
            case false: semaphore.wait()
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await thread?.runInLoop(cm) { [axApp] job in
            axApp.threadGuardedOrNil?.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try AppBundle.getAxRect(window: window, job: job)
        }
    }

    func nativeTabGroup(containing windowId: UInt32) async throws -> NativeTabWindowGroup? {
        try await thread?.runInLoop(.cancellable) { [windows] job in
            try job.checkCancellation()
            return windows.threadGuardedOrNil?.nativeTabGroups().first { $0.memberWindowIds.contains(windowId) }
        }
    }

    func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle.getAxRect(window: window, job: job))
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet()
        }
    }

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            guard let axApp = axApp.threadGuardedOrNil else { return nil }
            return window.isWindowHeuristic(axApp: axApp, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            guard let axApp = axApp.threadGuardedOrNil else { return nil }
            return window.getWindowType(axApp: axApp, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    // Cancel any pending setFrame jobs keyed on either id when a native-tab survivor adopts a new
    // window id, so a stale job can't fire against the wrong window. See adoptNativeTabWindowId.
    func nativeTabWindowIdChanged(from oldWindowId: UInt32, to newWindowId: UInt32) {
        setFrameJobs.removeValue(forKey: oldWindowId)?.cancel()
        setFrameJobs.removeValue(forKey: newWindowId)?.cancel()
    }

    func dumpWindowAxInfo(windowId: UInt32, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            var result = dumpAxRecursive(window, .window)
            if let nativeTabs = window.nativeTabGroupInfo() {
                result["Aero.NativeTabs"] = nativeTabs.debugJson
            }
            return result
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await thread?.runInLoop(cm) { [axApp] job in
            guard let axApp = axApp.threadGuardedOrNil else { return nil }
            return dumpAxRecursive(axApp, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: MacAppWindowsRefreshResult] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                eprint("[alive-check] \(app.nsApp.idForDebug): terminated — destroying")
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, MacAppWindowsRefreshResult).self, returning: [MacApp: MacAppWindowsRefreshResult].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, .empty) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: MacAppWindowsRefreshResult] = [:]
            for try await (pid, refreshResult) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = refreshResult
                }
            }
            return result
        }
    }

    private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> MacAppWindowsRefreshResult {
        if nsApp.isTerminated {
            await destroy()
            return .empty
        }
        guard let thread else { return .empty }
        let (alive, dead, nativeTabGroups) = try await thread.runInLoop(.cancellable) { [nsApp, windows, axApp] (job) -> ([UInt32], [UInt32], [NativeTabWindowGroup]) in
            guard var alive: [UInt32: AxWindow] = windows.threadGuardedOrNil else { return ([], [], []) }
            guard let axApp = axApp.threadGuardedOrNil else { return ([], [], []) }
            var dead = [UInt32: AxWindow]()

            // Probe app liveness FIRST — a responsive app answers in <10ms; 200ms is generous.
            // If nil, the app is unresponsive — skip the per-window partition and nativeTabGroups
            // entirely (both do per-window AX calls that would each block for the full timeout).
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            let axWindows = axApp.get(Ax.windowsAttr)
            AXUIElementSetMessagingTimeout(axApp, 1.0)

            let nativeTabGroups: [NativeTabWindowGroup]
            if let axWindows {
                let axWindowIds = Set(axWindows.map(\.0))
                for (id, window) in axWindows {
                    try job.checkCancellation()
                    try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
                }
                // GC windows that are still in CGWindowList but no longer in the app's AX tree
                let axGone = alive.filter { !axWindowIds.contains($0.key) }
                dead.merge(axGone) { _, new in new }
                for key in axGone.keys { alive.removeValue(forKey: key) }
                nativeTabGroups = alive.nativeTabGroups()
            } else {
                // AX unresponsive — fall back to CGWindowList to GC truly-gone windows
                // while keeping windows that are still in the WindowServer (just AX-slow).
                let cgIds: Set<UInt32> = {
                    let opts = CGWindowListOption([.excludeDesktopElements])
                    guard let arr = CGWindowListCopyWindowInfo(opts, CGWindowID(0)) as? [NSDictionary] else { return [] }
                    return Set(arr.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
                }()
                let cgGone = alive.filter { !cgIds.contains($0.key) }
                if !cgGone.isEmpty {
                    eprint("[alive-check] \(nsApp.idForDebug): AX probe failed — GC'd \(cgGone.count) window(s) not in CGWindowList: \(cgGone.keys.sorted())")
                    dead.merge(cgGone) { _, new in new }
                    for key in cgGone.keys { alive.removeValue(forKey: key) }
                } else {
                    eprint("[alive-check] \(nsApp.idForDebug): AX probe failed — all \(alive.count) window(s) still in CGWindowList, keeping alive")
                }
                nativeTabGroups = alive.nativeTabGroups()
            }
            let inactiveNativeTabWindowIds = nativeTabGroups.flatMap(\.inactiveWindowIds).toSet()
            let activeWindowIds = alive.keys.filter { !inactiveNativeTabWindowIds.contains($0) }

            windows.threadGuarded = alive
            return (activeWindowIds, Array(dead.keys), nativeTabGroups)
        }
        windowsCount = alive.count
        for windowId in dead + nativeTabGroups.flatMap(\.inactiveWindowIds) {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return MacAppWindowsRefreshResult(aliveWindowIds: alive, nativeTabGroups: nativeTabGroups)
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in
            _ = MacApp.allAppsMap.removeValue(forKey: pid)
            MacApp.clearFailedRegistration(pid)
        }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { [windows, appAxSubscriptions, axApp] job in
            appAxSubscriptions.destroy() // Destroy AX objects in reverse order of their creation
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        try await thread?.runInLoop(cm) { [windows] job in
            guard let window = windows.threadGuardedOrNil?[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(_ windowId: UInt32, _ cm: CancellationMode, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        thread?.runInLoopAsync(job: RunLoopJob(cm)) { [windows] job in
            guard let window = windows.threadGuardedOrNil?[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

struct MacAppWindowsRefreshResult: Sendable {
    let aliveWindowIds: [UInt32]
    let nativeTabGroups: [NativeTabWindowGroup]

    static let empty = MacAppWindowsRefreshResult(aliveWindowIds: [], nativeTabGroups: [])
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if id == 0 { return nil }
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }

    // Must be called on the app's AX thread — reads AX attributes (title, AXTabGroup) directly.
    fileprivate func nativeTabGroups() -> [NativeTabWindowGroup] {
        // A native-tab group always spans ≥2 AX windows in one app (macOS exposes each merged tab as
        // its own window id). A single-window app can't have one, so skip the per-window title/
        // children/role AX walk entirely — the common case, every refresh.
        guard values.count >= 2 else { return [] }
        let candidates = values.map {
            NativeTabWindowCandidate(
                windowId: $0.windowId,
                title: $0.ax.get(Ax.titleAttr) ?? "",
                tabGroup: $0.ax.nativeTabGroupInfo(),
            )
        }
        return resolveNativeTabWindowGroups(from: candidates)
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
