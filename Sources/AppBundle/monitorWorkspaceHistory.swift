import AppKit
import Common

// Each monitor's own previous workspaces, for workspace-back-and-forth (and workspace --auto-back-and-forth).
// The history changes only when the monitor shows another workspace: focusing a workspace on another
// monitor, or another monitor, doesn't count, so going back stays on the monitor.

/// Keyed by the monitor's top-left corner, like the visible workspaces in Workspace.swift.
/// The workspaces the monitor showed before its current one, most recent first
@MainActor var monitorWorkspaceHistory: [CGPoint: [String]] = [:]
@MainActor private var lastKnownVisibleWorkspaces: [CGPoint: String] = [:]

/// Called in every refresh session (checkOnFocusChangedCallbacks_nonCancellable), so a workspace shown only
/// in the middle of a command sequence doesn't count; and by workspace-back-and-forth before it goes back
@MainActor func trackVisibleWorkspaces() {
    var visible: [CGPoint: String] = [:]
    for monitor in monitorInfos {
        visible[monitor.rect.topLeftCorner] = monitor.activeWorkspace.name
    }
    recordVisibleWorkspaces(visible)
}

/// `visible`: the workspace each monitor shows now
@MainActor func recordVisibleWorkspaces(_ visible: [CGPoint: String]) {
    for (point, name) in visible {
        // Dot workspaces (.scratchpad) hold stashed windows. One shows only for the moment
        // aero-helper takes a window out of it, and is never a place to go back to
        guard let old = lastKnownVisibleWorkspaces[point], old != name, !old.starts(with: ".") else { continue }
        monitorWorkspaceHistory[point] = [old] + (monitorWorkspaceHistory[point] ?? []).filter { $0 != old }
    }
    lastKnownVisibleWorkspaces = visible
}

@MainActor func resetMonitorWorkspaceHistory() {
    monitorWorkspaceHistory = [:]
    lastKnownVisibleWorkspaces = [:]
}

extension MonitorInfo {
    /// The last workspace this monitor showed that isn't on a screen now and may be shown here
    /// (workspace-to-monitor-force-assignment)
    @MainActor var backAndForthWorkspace: Workspace? {
        let point = rect.topLeftCorner
        return (monitorWorkspaceHistory[point] ?? []).lazy
            .map { Workspace.get(byName: $0) }
            .first { ws in !ws.isVisible && (ws.forceAssignedMonitor.map { $0.rect.topLeftCorner == point } ?? true) }
    }
}
