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

        log.warning("[RaycastInterceptor] INTERCEPTING: \(bundleId ?? "nil", privacy: .public) | bundleURL: \(nsApp.bundleURL?.path ?? "nil", privacy: .public)")
        if let bundleURL = nsApp.bundleURL {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            try? process.run()
        }
        return true
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
