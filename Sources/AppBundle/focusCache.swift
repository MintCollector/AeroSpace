import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil
@MainActor var lastWindowDestroyedDate: Date = .distantPast

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // macOS auto-activates same-app windows on other workspaces when the last window
        // of that app is closed on the current workspace. Don't follow it.
        if let nativeFocusedWs = nativeFocused?.toLiveFocusOrNil()?.workspace,
           nativeFocusedWs != focus.workspace,
           lastWindowDestroyedDate.distance(to: .now) < 0.5 {
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
            nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
            return
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
