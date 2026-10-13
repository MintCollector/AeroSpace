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

/// A split screen as it was when it merged, so that splitting it again puts it back
private struct MergedScreen {
    /// By column corner: the workspace each column showed
    let shownWorkspaces: [CGPoint: String]
    /// By column corner: each column's back-and-forth history
    let histories: [CGPoint: [String]]
    /// By workspace name: the column of every workspace on the screen, visible or not
    let columnOfWorkspace: [String: CGPoint]
}

/// By screen corner
@MainActor private var mergedScreens: [CGPoint: MergedScreen] = [:]

@MainActor func resetSplitMonitorsForTests() {
    splitMonitorsEnabled = true
    mergedScreens = [:]
}

/// Runs `change`, which may split, merge or re-split screens (the toggle, a config reload), then puts the workspaces
/// where you'd expect them. A re-split (columns before and after) keeps rearrangeWorkspacesOnMonitors's nearest match
@MainActor func changeMonitorSplit(_ change: () -> Void) {
    // At startup the config loads before any workspace shows: the monitors get theirs as usual
    guard Workspace.all.contains(where: \.isVisible) else { return change() }
    let focused = focus.workspace
    let before = monitorInfos.map { (monitor: $0, workspace: $0.activeWorkspace) }
    // Once merged, the screen covers all its columns: which column each workspace was in is lost
    let monitorOfWorkspace = Dictionary(uniqueKeysWithValues: Workspace.all.map { ($0.name, $0.workspaceMonitor.rect.topLeftCorner) })
    change()
    if Set(before.map(\.monitor.rect.topLeftCorner)) == Set(monitorInfos.map(\.rect.topLeftCorner)) { return } // Same monitors
    gcMonitors()
    let after = monitorInfos
    for screen in screenInfos {
        let corner = screen.rect.topLeftCorner
        let was = before.filter { $0.monitor.screen.rect.topLeftCorner == corner }
        let now = after.filter { $0.screen.rect.topLeftCorner == corner }
        switch (was.count, now.count) {
            case (1, 2...): split(screen, was[0].workspace, into: now.compactMap { $0 as? SplitMonitorInfo })
            case (2..., 1): merge(screen, was, focused: focused, monitorOfWorkspace: monitorOfWorkspace)
            default: break
        }
    }
    // A re-split can map the focused column nowhere, and a pin can resolve to another monitor after the change
    if before.contains(where: { $0.workspace == focused }) && !focused.isVisible {
        _ = focused.workspaceMonitor.setActiveWorkspace(focused)
    }
    // Nobody went to the workspaces that the monitors show now: they don't go into the back-and-forth history
    forgetVisibleWorkspaceChanges()
}

@MainActor private func split(_ screen: MonitorInfo, _ workspace: Workspace, into columns: [SplitMonitorInfo]) {
    let screenCorner = screen.rect.topLeftCorner
    let merged = mergedScreens.removeValue(forKey: screenCorner)
    func column(at corner: CGPoint?) -> SplitMonitorInfo? { columns.first { $0.rect.topLeftCorner == corner } }
    let primary = columns.first(where: \.isPrimaryColumn) ?? columns[0]
    // The screen and its first column share a corner, so the workspaces last shown on the screen would all belong to
    // the first column: they go back to the column they were in when the screen merged, else to the primary column
    for invisible in Workspace.all where !invisible.isVisible && invisible.forceAssignedMonitor == nil &&
        invisible.workspaceMonitor.rect.topLeftCorner == screenCorner
    {
        invisible.assignMonitor(column(at: merged?.columnOfWorkspace[invisible.name]) ?? primary)
    }
    // The screen's workspace goes to its pinned column, else to the column it was in, else to the primary column
    let home = column(at: workspace.forceAssignedMonitor?.rect.topLeftCorner)
        ?? column(at: merged?.columnOfWorkspace[workspace.name])
        ?? primary
    _ = home.setActiveWorkspace(workspace)
    // The other columns show what they showed when the screen merged
    for column in columns where column.rect.topLeftCorner != home.rect.topLeftCorner {
        if let name = merged?.shownWorkspaces[column.rect.topLeftCorner], name != workspace.name {
            let shown = Workspace.get(byName: name)
            if !shown.isVisible { _ = column.setActiveWorkspace(shown) }
        }
        if column.activeWorkspaceOrNil == nil {
            _ = column.setActiveWorkspace(getStubWorkspace(for: column))
        }
    }
    // Each column gets its back-and-forth history back, and the screen's history stays with the screen's workspace
    let screenHistory = monitorWorkspaceHistory[screenCorner] ?? []
    for column in columns {
        monitorWorkspaceHistory[column.rect.topLeftCorner] = merged?.histories[column.rect.topLeftCorner] ?? []
    }
    monitorWorkspaceHistory[home.rect.topLeftCorner] = screenHistory
}

@MainActor private func merge(
    _ screen: MonitorInfo,
    _ columns: [(monitor: MonitorInfo, workspace: Workspace)],
    focused: Workspace,
    monitorOfWorkspace: [String: CGPoint],
) {
    let corners = columns.map(\.monitor.rect.topLeftCorner)
    // Taken before the screen's history replaces the first column's: they share a corner
    let histories = Dictionary(uniqueKeysWithValues: corners.map { ($0, monitorWorkspaceHistory[$0] ?? []) })
    mergedScreens[screen.rect.topLeftCorner] = MergedScreen(
        shownWorkspaces: Dictionary(uniqueKeysWithValues: columns.map { ($0.monitor.rect.topLeftCorner, $0.workspace.name) }),
        histories: histories,
        columnOfWorkspace: monitorOfWorkspace.filter { corners.contains($0.value) },
    )
    // The focused workspace if it was on one of the columns, else the primary column's: the first that may show there
    let focusedColumn = columns.first(where: { $0.workspace == focused })
    let primaryColumn = columns.first(where: { ($0.monitor as? SplitMonitorInfo)?.isPrimaryColumn == true })
    let shown = [focusedColumn, primaryColumn].compactMap { $0 }.first { screen.setActiveWorkspace($0.workspace) }
    // The screen goes back and forth like the column whose workspace it shows
    if let shown {
        monitorWorkspaceHistory[screen.rect.topLeftCorner] = histories[shown.monitor.rect.topLeftCorner]
    }
}
