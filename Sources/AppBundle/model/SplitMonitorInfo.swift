import AppKit
import Common

/// `split-monitors on|off|toggle`. Reloading the config leaves it alone
@MainActor var splitMonitorsEnabled = true

/// A column of a screen that a `[split-monitors]` rule splits: a monitor of its own in every other respect
struct SplitMonitorInfo: MonitorInfo {
    let screen: MonitorInfo
    /// 1-based, left to right
    let column: Int
    let rect: Rect
    let visibleRect: Rect
    /// The rule's `main` column, on any screen. Only the main screen's is the main monitor
    let isPrimaryColumn: Bool

    var monitorAppKitNsScreenScreensId: Int { screen.monitorAppKitNsScreenScreensId }
    var name: String { "\(screen.name) \(column)" }
    var isMain: Bool { screen.isMain && isPrimaryColumn }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

extension SplitMonitorRule {
    /// `screen`'s columns, left to right. Each keeps the part of the screen's visible area (menu bar, Dock) above it
    func columnMonitors(of screen: MonitorInfo) -> [SplitMonitorInfo] {
        let visible = screen.visibleRect
        return screen.rect.sliced(along: .h, weights: columns.map { CGFloat($0) }).enumerated().map { index, rect in
            let minX = max(rect.minX, visible.minX)
            let maxX = min(rect.maxX, visible.maxX)
            return SplitMonitorInfo(
                screen: screen,
                column: index + 1,
                rect: rect,
                visibleRect: Rect(topLeftX: minX, topLeftY: visible.topLeftY, width: maxX - minX, height: visible.height),
                isPrimaryColumn: index + 1 == main,
            )
        }
    }
}

/// `screens`, with every screen that a `[split-monitors]` rule matches replaced by its columns
@MainActor func splitScreens(_ screens: [MonitorInfo]) -> [MonitorInfo] {
    guard splitMonitorsEnabled else { return screens }
    return screens.flatMap { screen -> [MonitorInfo] in
        config.splitMonitors.first { screen.name.contains(caseInsensitiveRegex: $0.pattern) }?.columnMonitors(of: screen) ?? [screen]
    }
}
