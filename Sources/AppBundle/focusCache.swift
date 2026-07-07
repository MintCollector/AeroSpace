import Foundation
import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil
@MainActor var lastWindowDestroyedDate: Date = .distantPast

private func parentKindLabel(_ window: Window?) -> String {
    guard let parent = window?.parent else { return "nil" }
    switch parent {
        case is TilingContainer: return "tiling"
        case is FloatingWindowsContainer: return "floating"
        case is MacosPopupWindowsContainer: return "popup"
        default: return String(describing: type(of: parent))
    }
}

private let focusCacheLogFile: FileHandle? = {
    let path = "/tmp/aerospace-focus-cache.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func focusLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let event = refreshSessionEvent?.description ?? "none"
    let line = "[\(ts)] [\(event)] \(msg)\n"
    eprint(msg)
    focusCacheLogFile?.seekToEndOfFile()
    focusCacheLogFile?.write(line.data(using: .utf8) ?? Data())
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?, now: Date = Date()) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        focusLog("[focus-cache] skip popup window \(nativeFocused?.windowId ?? 0)")
        return
    }
    if let macWindow = nativeFocused as? MacWindow,
       macWindow.isSticky,
       macWindow.visualWorkspace != focus.workspace
    {
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        macWindow.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        let oldId = lastKnownNativeFocusedWindowId.map(String.init) ?? "nil"
        let newId = nativeFocused.map { String($0.windowId) } ?? "nil"
        let app = nativeFocused?.app.name ?? "?"
        let bundleId = nativeFocused?.app.rawAppBundleId ?? "?"
        let nativeWs = nativeFocused?.toLiveFocusOrNil()?.workspace.name ?? "nil"
        let currentWs = focus.workspace.name
        let parentKind = parentKindLabel(nativeFocused)
        // A matched 'on-window-detected' rule with 'no-focus = true' recently fired for this
        // window. Refuse to adopt its native focus grab (adoption is what flips the visible
        // workspace via setFocus -> setActiveWorkspace) and push native focus back to the window
        // the user was working in.
        if let nativeFocused, let entry = noFocusSuppression[nativeFocused.windowId] {
            if entry.deadline <= now {
                noFocusSuppression[nativeFocused.windowId] = nil // Lazily drop expired entries
            } else {
                focusLog("[focus-cache] no-focus suppressed: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(nativeWs)' (focusWs: '\(currentWs)', prev: \(oldId))")
                // Intentionally memorize the SUPPRESSED id (not the restore id), mirroring the
                // window-destroy suppression below. The async bounce lands later; the next refresh
                // then adopts the restore window through the normal path, where setFocus is a
                // no-op because the model never left it. Memorizing the restore id instead would
                // re-enter this branch (and re-issue nativeFocus) on every refresh until the
                // bounce lands - a focus war with the app.
                lastKnownNativeFocusedWindowId = nativeFocused.windowId
                (nativeFocused.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused.windowId
                // The user may have re-focused another window since detection: the live model
                // focus (never contaminated, since we refuse adoption) beats the remembered id.
                let bounceTarget: Window? = focus.windowOrNil
                    ?? entry.restoreWindowId.flatMap { Window.get(byId: $0) }
                if let bounceTarget, bounceTarget.windowId != nativeFocused.windowId {
                    _ = bounceTarget.focusWindow()
                    bounceTarget.nativeFocus() // Model + native pair, see deadWindowFocus in MacWindow
                    focusLog("[focus-cache] no-focus bounce: native focus pushed back to window \(bounceTarget.windowId)")
                }
                return
            }
        }
        // macOS auto-activates same-app windows on other workspaces when the last window
        // of that app is closed on the current workspace. Don't follow it.
        if let nativeFocusedWs = nativeFocused?.toLiveFocusOrNil()?.workspace,
           nativeFocusedWs != focus.workspace,
           lastWindowDestroyedDate.distance(to: .now) < 0.5
        {
            focusLog("[focus-cache] suppressed cross-ws switch: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(nativeWs)' — recent window destroy (focusWs: '\(currentWs)', prev: \(oldId))")
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
            (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
            return
        }
        if nativeWs != currentWs {
            focusLog("[focus-cache] CROSS-WS: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) — switching ws '\(currentWs)' → '\(nativeWs)' (prev: \(oldId))")
        } else {
            focusLog("[focus-cache] native focus changed: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(currentWs)' (prev: \(oldId))")
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    // Safe cast (was macAppUnsafe) so unit tests can drive updateFocusCache with TestWindow.
    // In production, real windows always belong to a MacApp.
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}

// MARK: - 'no-focus' suppression ([[on-window-detected]] rules with no-focus = true)

struct NoFocusSuppressionEntry {
    let restoreWindowId: UInt32?
    let pid: pid_t
    let deadline: Date
}

let noFocusSuppressionTtl: TimeInterval = 1.0
/// windowId of the detected window -> suppression entry.
/// Expired entries are dropped lazily in updateFocusCache.
@MainActor var noFocusSuppression: [UInt32: NoFocusSuppressionEntry] = [:]

/// Called from onWindowDetected when a matched rule has 'no-focus = true'.
/// For noFocusSuppressionTtl seconds, native focus grabs by `window` are refused and bounced
/// back to the remembered window (see updateFocusCache).
/// Re-arming (multiple matched rules, or AX re-registration re-firing on-window-detected for an
/// old window) is harmless: the entry is simply refreshed.
@MainActor func armNoFocusSuppression(for window: Window, now: Date = Date()) {
    let modelFocusedId = focus.windowOrNil?.windowId
    // If the detected window has already grabbed the model focus (activation raced detection),
    // the pre-steal focus lives in prevFocus. Otherwise the current focus is the restore target.
    let restoreWindowId: UInt32? = modelFocusedId == window.windowId
        ? prevFocus?.windowOrNil?.windowId
        : modelFocusedId
    noFocusSuppression[window.windowId] = NoFocusSuppressionEntry(
        restoreWindowId: restoreWindowId,
        pid: window.app.pid,
        deadline: now.addingTimeInterval(noFocusSuppressionTtl),
    )
    focusLog("[focus-cache] no-focus armed for window \(window.windowId) (app: \(window.app.name ?? "?")), restore target: \(restoreWindowId.map(String.init) ?? "nil")")
    // The steal already happened before the rule armed. updateFocusCache won't re-fire for this
    // window (lastKnownNativeFocusedWindowId already adopted it), so undo the grab right away.
    if modelFocusedId == window.windowId, let restore = restoreWindowId.flatMap({ Window.get(byId: $0) }) {
        _ = restore.focusWindow()
        restore.nativeFocus()
        focusLog("[focus-cache] no-focus immediate bounce: window \(window.windowId) -> restore window \(restore.windowId)")
    }
}

/// Fast-path bounce, called straight from the notification handlers (per-app AX
/// kAXFocusedWindowChangedNotification and NSWorkspace didActivateApplicationNotification)
/// WITHOUT waiting for a refresh session. The refresh path still bounces via updateFocusCache,
/// but it first does an AX round-trip to the stealing app (getNativeFocusedWindow) which can
/// take hundreds of ms on a busy app — this path reacts in the notification itself.
/// Match by windowId when the AX event carries the window, or by pid on app activation.
@MainActor func fastBounceNoFocusSuppression(windowId: UInt32?, pid: pid_t?, now: Date = Date()) {
    let suppressedWindowId: UInt32? = if let windowId, noFocusSuppression[windowId] != nil {
        windowId
    } else if let pid {
        noFocusSuppression.first { $0.value.pid == pid }?.key
    } else {
        nil
    }
    guard let suppressedWindowId, let entry = noFocusSuppression[suppressedWindowId] else { return }
    if entry.deadline <= now {
        noFocusSuppression[suppressedWindowId] = nil
        return
    }
    // Same target selection as the updateFocusCache bounce: live model focus beats the remembered
    // id — unless the model already adopted the suppressed window, then fall back to the memory.
    let modelFocus = focus.windowOrNil
    let bounceTarget: Window? = (modelFocus?.windowId != suppressedWindowId ? modelFocus : nil)
        ?? entry.restoreWindowId.flatMap { Window.get(byId: $0) }
    guard let bounceTarget, bounceTarget.windowId != suppressedWindowId else { return }
    _ = bounceTarget.focusWindow()
    bounceTarget.nativeFocus()
    focusLog("[focus-cache] no-focus fast bounce: window \(suppressedWindowId) -> restore window \(bounceTarget.windowId)")
}

/// Test-only. Resets focusCache module state between unit tests.
@MainActor func resetFocusCacheState() {
    lastKnownNativeFocusedWindowId = nil
    noFocusSuppression = [:]
    lastWindowDestroyedDate = .distantPast
}
