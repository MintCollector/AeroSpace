import AppKit
import os

private let log = Logger(subsystem: "bobko.aerospace", category: "RaycastInterceptor")

enum RaycastInterceptor {
    private static let raycastBundleId = "com.raycast.macos"
    private static let interceptWindow: TimeInterval = 0.2

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
        let onExtensionList = bundleId.map { cfg.extensionApps.contains($0) } ?? false

        log.warning("[RaycastInterceptor] INTERCEPTING: \(bundleId ?? "nil", privacy: .public) | extensionApp=\(onExtensionList, privacy: .public)")

        if onExtensionList {
            launchExtension(nsApp)
        } else if cfg.defaultBehavior == .move {
            moveWindowHere(nsApp)
        } else {
            return false
        }
        return true
    }

    @MainActor
    private static func launchExtension(_ nsApp: NSRunningApplication) {
        let pid = nsApp.processIdentifier
        let bundleId = nsApp.bundleIdentifier ?? ""
        let appName = nsApp.localizedName ?? ""
        let bundlePath = nsApp.bundleURL?.path ?? ""
        let windows = MacWindow.allWindows.filter { $0.macApp.pid == pid }

        Task { @MainActor in
            var windowData: [[String: Any]] = []
            for window in windows {
                let title = (try? await window.title) ?? ""
                let workspace = window.nodeWorkspace?.name ?? ""
                windowData.append([
                    "id": window.windowId,
                    "title": title,
                    "workspace": workspace,
                ])
            }

            let payload: [String: Any] = [
                "bundleId": bundleId,
                "appName": appName,
                "bundlePath": bundlePath,
                "windows": windowData,
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonString = String(data: jsonData, encoding: .utf8),
                  let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "raycast://extensions/aerospace/aerospace/window-action?launchContext=\(encoded)") else {
                log.warning("[RaycastInterceptor] failed to build deeplink")
                return
            }
            log.warning("[RaycastInterceptor] launching extension for \(bundleId, privacy: .public)")
            NSWorkspace.shared.open(url)
        }
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
