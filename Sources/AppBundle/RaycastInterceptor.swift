import AppKit
import os

private let log = Logger(subsystem: "bobko.aerospace", category: "RaycastInterceptor")

enum RaycastInterceptor {
    private static let raycastBundleId = "com.raycast.macos"
    private static let interceptWindow: TimeInterval = 0.05

    @MainActor static var panelClosedAt: Date? = nil
    @MainActor static var panelOpenBundleId: String? = nil
    @MainActor private static var observerRetain: AnyObject? = nil

    @MainActor
    static func install() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == raycastBundleId {
                Task { @MainActor in setupAXObserver(pid: app.processIdentifier) }
            }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: raycastBundleId).first {
            setupAXObserver(pid: app.processIdentifier)
        }
    }

    @MainActor
    private static func setupAXObserver(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        guard let obs = unsafe AXObserver.new(pid, raycastAXCallback) else {
            log.warning("[RaycastInterceptor] failed to create AXObserver for pid=\(pid)")
            return
        }
        for notif in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, axApp, notif as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observerRetain = obs
        log.warning("[RaycastInterceptor] AX observer installed for Raycast pid=\(pid, privacy: .public)")
    }

    @MainActor
    static func handleActivation(_ nsApp: NSRunningApplication) -> Bool {
        let bundleId = nsApp.bundleIdentifier
        guard let closedAt = panelClosedAt,
              Date().timeIntervalSince(closedAt) < interceptWindow else {
            return false
        }

        panelClosedAt = nil

        if bundleId == panelOpenBundleId {
            log.warning("[RaycastInterceptor] dismissal (target == pre-raycast app), pass through")
            return false
        }

        let cfg = raycastConfig
        let modifierHeld = NSEvent.modifierFlags.contains(cfg.modifier)
        let onAllowlist = bundleId.map { cfg.newWindowApps.contains($0) } ?? false

        log.warning("[RaycastInterceptor] INTERCEPTING: \(bundleId ?? "nil", privacy: .public) | modifier=\(modifierHeld, privacy: .public) allowlist=\(onAllowlist, privacy: .public)")

        if onAllowlist && modifierHeld {
            openNewWindow(nsApp)
        } else if onAllowlist || cfg.defaultBehavior == .move {
            moveWindowHere(nsApp)
        } else {
            return false
        }
        return true
    }

    @MainActor
    private static func openNewWindow(_ nsApp: NSRunningApplication) {
        guard let bundleURL = nsApp.bundleURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try? process.run()
    }

    @MainActor
    private static func moveWindowHere(_ nsApp: NSRunningApplication) {
        guard let macApp = MacApp.allAppsMap[nsApp.processIdentifier] else {
            log.warning("[RaycastInterceptor] no MacApp for pid=\(nsApp.processIdentifier)")
            return
        }
        let window: MacWindow? = {
            if let id = macApp.lastNativeFocusedWindowId, let w = MacWindow.allWindowsMap[id] { return w }
            return MacWindow.allWindows.first { $0.macApp.pid == nsApp.processIdentifier }
        }()
        guard let window else {
            log.warning("[RaycastInterceptor] no window found for \(nsApp.bundleIdentifier ?? "nil", privacy: .public)")
            return
        }
        let targetWorkspace = focus.workspace
        if window.nodeWorkspace != targetWorkspace {
            let targetContainer: NonLeafTreeNodeObject = window.isFloating ? targetWorkspace : targetWorkspace.rootTilingContainer
            window.bind(to: targetContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        _ = window.focusWindow()
        window.nativeFocus()
        scheduleCancellableCompleteRefreshSession(.globalObserver("RaycastMoveWindow"))
    }
}

private func raycastAXCallback(_: AXObserver, _: AXUIElement, notification: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notification as String
    Task { @MainActor in
        if notif == kAXWindowCreatedNotification {
            RaycastInterceptor.panelOpenBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            log.warning("[RaycastInterceptor] panel opened, pre-raycast app: \(RaycastInterceptor.panelOpenBundleId ?? "nil", privacy: .public)")
        } else if notif == kAXUIElementDestroyedNotification {
            RaycastInterceptor.panelClosedAt = Date()
            log.warning("[RaycastInterceptor] panel closed")
        }
    }
}
