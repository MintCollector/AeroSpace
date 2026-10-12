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

extension Config {
    var hasRecheckRules: Bool { onWindowDetected.contains { $0.recheck != nil } }
}

/// Bumped on every reload: rule numbers in a window's state refer to the config of their generation
@MainActor var ruleRecheckGeneration = 0

/// Rule numbers index `config.onWindowDetected` of `generation`
struct RuleRecheckState {
    let generation: Int
    /// The title the baseline was taken with; a newer known title is a change
    var title: String
    /// The watched state at the last check. The rules are checked again only once it changes.
    var baseline: WindowRuleSnapshot
    /// `recheck` rules whose `if` matched at the last check. `every-match` fires on false → true.
    var matched: Set<Int>
    /// `until-matched` rules that have matched once. They never run again for this window.
    var spent: Set<Int>
    /// The rules are running. An overlapping check leaves the window for later.
    var isBusy: Bool = false
}

extension Window {
    /// The title to start tracking from: the latest title event's, else the app's title right now,
    /// which also becomes the known title
    @MainActor
    func titleForRuleSeed() async -> String {
        if hasTitleEvents, let lastKnownTitle { return lastKnownTitle }
        let title = (try? await getTitle(.nonCancellable)) ?? ""
        // A title event that landed while the app answered is at least as new
        if hasTitleEvents, let lastKnownTitle { return lastKnownTitle }
        lastKnownTitle = title
        return title
    }
}

/// Takes the window's state as it is now as the starting point, without running anything. Rules that
/// match now count as applied, as at detection: `until-matched` ones are spent, `every-match` ones
/// have to stop matching before they fire again.
/// - Parameter alreadySpent: rules that ran just before; the `until-matched` ones among them are spent
@MainActor
func seededRuleRecheckState(_ window: Window, title: String, alreadySpent: Set<Int> = []) async -> RuleRecheckState {
    let generation = ruleRecheckGeneration
    let rules = config.onWindowDetected
    var matched: Set<Int> = []
    for (index, rule) in rules.enumerated() where rule.recheck != nil {
        if await rule.matches(window, knownTitle: title) { matched.insert(index) }
    }
    let untilMatched = Set(rules.indices.filter { rules[$0].recheck == .untilMatched })
    return RuleRecheckState(
        generation: generation,
        title: title,
        baseline: ruleSnapshot(window, title: title, monitorValues: ruleMonitorValues(window.nodeWorkspace)),
        matched: matched,
        spent: alreadySpent.union(matched).intersection(untilMatched),
    )
}
