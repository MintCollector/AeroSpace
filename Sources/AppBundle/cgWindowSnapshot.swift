import Common
import CoreGraphics
import Foundation

/// Physical attributes of a single window as reported by the WindowServer, keyed elsewhere by
/// CGWindowID (== AeroSpace `windowId`). `title` requires Screen Recording permission (nil
/// without it); `rect` (geometry) needs no permission. Used to replace per-window AX title/rect
/// reads on the `list-tree` read path so the display path never blocks on a busy app.
struct CgWindowInfo {
    let title: String?
    let rect: Rect?
}

/// One WindowServer snapshot of every window's physical attributes, keyed by CGWindowID.
/// Intentionally omits `.optionOnScreenOnly` — we MUST include windows on hidden workspaces,
/// which AeroSpace parks off-screen. (Contrast `windowLevelCache.swift`, which keeps
/// `.optionOnScreenOnly` for its always-on-top heuristic.)
@MainActor
func readCgWindowSnapshot() -> [UInt32: CgWindowInfo] {
    let options = CGWindowListOption([.excludeDesktopElements])
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [NSDictionary] else { return [:] }
    return parseCgWindowSnapshot(cfArray)
}

/// Pure join/parse step (testable without the live CG call). `kCGWindowBounds` is already in
/// global, top-left-origin points — the same space as AeroSpace's `Rect` — so no flip is needed.
func parseCgWindowSnapshot(_ dicts: [NSDictionary]) -> [UInt32: CgWindowInfo] {
    var result: [UInt32: CgWindowInfo] = [:]
    for dict in dicts {
        guard let num = dict[kCGWindowNumber] as? NSNumber else { continue }
        let id = num.uint32Value
        let title = dict[kCGWindowName] as? String
        result[id] = CgWindowInfo(title: title, rect: parseCgWindowBounds(dict))
    }
    return result
}

private func parseCgWindowBounds(_ dict: NSDictionary) -> Rect? {
    guard let b = dict[kCGWindowBounds] as? NSDictionary,
          let x = (b["X"] as? NSNumber)?.doubleValue,
          let y = (b["Y"] as? NSNumber)?.doubleValue,
          let w = (b["Width"] as? NSNumber)?.doubleValue,
          let h = (b["Height"] as? NSNumber)?.doubleValue
    else { return nil }
    return Rect(topLeftX: CGFloat(x), topLeftY: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
}

/// Whether a normal (layer 0) window is under `point`. A click there isn't a click on the desktop, even when the
/// window reaches into another monitor, such as the next column of a split screen (split-monitors)
@MainActor
func isNormalWindowUnderMouse(_ point: CGPoint) -> Bool {
    let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] else { return false }
    return isNormalWindow(at: point, windows)
}

/// Pure part of `isNormalWindowUnderMouse`: `windows` as CGWindowListCopyWindowInfo returns them
func isNormalWindow(at point: CGPoint, _ windows: [NSDictionary]) -> Bool {
    windows.contains { window in
        (window[kCGWindowLayer] as? NSNumber)?.intValue == 0 && parseCgWindowBounds(window)?.contains(point) == true
    }
}
