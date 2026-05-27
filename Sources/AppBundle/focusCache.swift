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
