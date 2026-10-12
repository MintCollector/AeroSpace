import AppKit
import Common

// `recheck` rules (fork-only): `on-window-detected` rules that are checked again after detection,
// whenever something their `if` can test changes. User doc: docs/guide.adoc, on-window-detected.

/// While set, rule matchers read this window's title from here instead of asking the app: an AX
/// round trip, which can wait out the 1s timeout on a busy app.
@TaskLocal var knownRuleTitle: KnownWindowTitle? = nil

struct KnownWindowTitle: Sendable {
    let windowId: UInt32
    let title: String
}

extension Window {
    /// The title as rule matchers see it: the known one while it's set for this window, else the app's
    func titleForRules(_ cm: CancellationMode) async throws -> String {
        if let known = knownRuleTitle, known.windowId == windowId { return known.title }
        return try await getTitle(cm)
    }
}

/// What a rule check compares: the window state a rule can test that changes over the window's life
/// and that AeroSpace knows without asking the app. Left out: window-x/y/width/height (they change on
/// every layout, and a floating window's would need the app), workspace-is-focused/visible (they
/// change on every workspace switch) and window-tree-index (it changes with the siblings).
private let watchedWindowVars: [FormatVar] = [
    .window(.windowTitle), .window(.windowIsFullscreen), .window(.windowLayout),
    .window(.windowParentContainerOrientation), .workspace(.workspaceName),
]
private let watchedMonitorVars: [FormatVar] = [.monitor(.monitorName), .monitor(.monitorId_oneBased)]

/// The watched values, as the rules' `test` sees them
typealias WindowRuleSnapshot = [String]

@MainActor
func ruleSnapshot(_ window: Window, title: String, monitorValues: [String]) -> WindowRuleSnapshot {
    let obj = AeroObj.window(.prefetched(window: window, title: title))
    return watchedWindowVars.map { $0.expandedForRules(obj) } + monitorValues
}

/// The watched monitor values of a workspace's windows. Finding a workspace's monitor goes through
/// NSScreen each time, so a pass over many windows works it out once per workspace.
@MainActor
func ruleMonitorValues(_ workspace: Workspace?) -> [String] {
    guard let workspace else { return [] }
    let obj = AeroObj.monitor(workspace.workspaceMonitor)
    return watchedMonitorVars.map { $0.expandedForRules(obj) }
}

extension FormatVar {
    @MainActor
    fileprivate func expandedForRules(_ obj: AeroObj) -> String {
        switch expandFormatVar(obj: obj) {
            case .success(let value): value.toString()
            case .failure(let error): error.description
        }
    }
}
