#!/usr/bin/env swift

import AppKit
import Foundation

let raycastBundleId = "com.raycast.macos"

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ msg: String) {
    fputs("\(timestamp()) | \(msg)\n", stderr)
}

// --- CGWindowList polling for Raycast windows ---

func getRaycastWindows() -> [[String: Any]] {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: raycastBundleId)
    guard let r = apps.first else { return [] }
    let pid = r.processIdentifier
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return windowList.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
}

func describeWindow(_ w: [String: Any]) -> String {
    let name = w[kCGWindowName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    let x = bounds["X"] as? Int ?? 0
    let y = bounds["Y"] as? Int ?? 0
    return "'\(name)' \(width)x\(height)@\(x),\(y) layer=\(layer) alpha=\(alpha)"
}

// --- AXObserver on Raycast ---

func setupAXObserver() {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: raycastBundleId)
    guard let r = apps.first else {
        log("AX: Raycast not running")
        return
    }
    let pid = r.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)

    // List current AX attributes
    var attrNames: CFArray?
    AXUIElementCopyAttributeNames(axApp, &attrNames)
    if let names = attrNames as? [String] {
        log("AX: Raycast app attributes: \(names.joined(separator: ", "))")
    }

    // Check current windows
    var windowsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    if let windows = windowsRef as? [AXUIElement] {
        log("AX: Raycast has \(windows.count) AX windows")
        for (i, win) in windows.enumerated() {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
            log("AX:   window[\(i)] title=\(titleRef as? String ?? "nil") role=\(roleRef as? String ?? "nil") subrole=\(subroleRef as? String ?? "nil")")
        }
    } else {
        log("AX: Raycast has no AX windows (or access denied)")
    }

    // Create AXObserver
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, _ in
        let notif = notification as String
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        log("AX EVENT: \(notif) | role=\(roleRef as? String ?? "nil") title=\(titleRef as? String ?? "nil")")
    }

    let err = AXObserverCreate(pid, callback, &observer)
    guard err == .success, let observer = observer else {
        log("AX: Failed to create observer: \(err.rawValue)")
        return
    }

    let notifications = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationShownNotification,
        kAXApplicationHiddenNotification,
    ]

    for notif in notifications {
        let result = AXObserverAddNotification(observer, axApp, notif as CFString, nil)
        log("AX: Subscribe \(notif): \(result == .success ? "OK" : "err=\(result.rawValue)")")
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    log("AX: Observer installed for Raycast pid=\(pid)")

    // Keep observer alive
    let _ = Unmanaged.passRetained(observer as AnyObject)
}

// --- NSDistributedNotificationCenter ---

let dnc = DistributedNotificationCenter.default()
dnc.addObserver(forName: nil, object: nil, queue: .main) { notif in
    let name = notif.name.rawValue
    if name.lowercased().contains("raycast") || (notif.object as? String ?? "").lowercased().contains("raycast") {
        log("DISTRIBUTED: \(name) object=\(notif.object ?? "nil") userInfo=\(notif.userInfo ?? [:])")
    }
}

// --- NSWorkspace notifications ---

let nc = NSWorkspace.shared.notificationCenter
let names: [Notification.Name] = [
    NSWorkspace.didActivateApplicationNotification,
    NSWorkspace.didDeactivateApplicationNotification,
]
for name in names {
    nc.addObserver(forName: name, object: nil, queue: .main) { notification in
        let shortName = notification.name.rawValue
            .replacingOccurrences(of: "NSWorkspace", with: "")
            .replacingOccurrences(of: "Notification", with: "")
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bid = app?.bundleIdentifier ?? "?"
        let rcWins = getRaycastWindows()
        let rcDesc = rcWins.isEmpty ? "none" : rcWins.map { describeWindow($0) }.joined(separator: "; ")
        log("NOTIF: \(shortName) app=\(bid) | raycastWindowsOnScreen: \(rcDesc)")
    }
}

// --- CGWindowList poll for Raycast windows ---

var lastRaycastWindowCount = getRaycastWindows().count
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let wins = getRaycastWindows()
    if wins.count != lastRaycastWindowCount {
        let desc = wins.isEmpty ? "none" : wins.map { describeWindow($0) }.joined(separator: "; ")
        log("POLL: Raycast window count changed \(lastRaycastWindowCount) -> \(wins.count): \(desc)")
        lastRaycastWindowCount = wins.count
    }
}

// --- Setup ---

setupAXObserver()
log("Monitoring Raycast via AX, CGWindowList (50ms poll), NSDistributedNotifications, and NSWorkspace.")
log("Open/close Raycast and switch apps. Ctrl+C to stop.\n")
RunLoop.main.run()
