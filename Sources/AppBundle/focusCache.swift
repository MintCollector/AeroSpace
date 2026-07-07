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
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
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
        // macOS auto-activates same-app windows on other workspaces when the last window
        // of that app is closed on the current workspace. Don't follow it.
        if let nativeFocusedWs = nativeFocused?.toLiveFocusOrNil()?.workspace,
           nativeFocusedWs != focus.workspace,
           lastWindowDestroyedDate.distance(to: .now) < 0.5
        {
            focusLog("[focus-cache] suppressed cross-ws switch: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(nativeWs)' — recent window destroy (focusWs: '\(currentWs)', prev: \(oldId))")
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
            nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
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
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

// MARK: - 'no-focus' suppression ([[on-window-detected]] rules with no-focus = true)

struct NoFocusSuppressionEntry {
    let restoreWindowId: UInt32?
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

/// Test-only. Resets focusCache module state between unit tests.
@MainActor func resetFocusCacheState() {
    lastKnownNativeFocusedWindowId = nil
    noFocusSuppression = [:]
    lastWindowDestroyedDate = .distantPast
}
