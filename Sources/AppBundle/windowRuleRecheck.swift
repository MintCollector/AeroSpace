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

/// Notes a title-changed notification. Returns whether the title changed: apps send repeats.
@MainActor
@discardableResult
func recordTitleEvent(_ window: Window, _ title: String) -> Bool {
    window.hasTitleEvents = true
    if window.lastKnownTitle == title { return false }
    window.lastKnownTitle = title
    return true
}

enum RuleRecheckOutcome {
    /// Not tracked, in a macOS native state, or nothing it watches changed
    case unchanged
    /// Its rules are running: check it again later
    case busy
    /// The watched state changed but no rule fires: the state to save
    case changed(RuleRecheckState)
    /// These rules fire, in order; the state is saved once they ran
    case fires([WindowDetectedCallback], RuleRecheckState)
}

/// Checks the window's `recheck` rules against its newest state, without changing anything
@MainActor
func checkRuleRecheck(_ window: Window, monitorValues: [String]) async -> RuleRecheckOutcome {
    guard var state = window.ruleRecheck else { return .unchanged }
    if state.isBusy { return .busy }
    // Minimized, hidden or in macOS fullscreen: its rules wait until it's back
    guard window.layoutReason == .standard else { return .unchanged }
    let title = window.lastKnownTitle ?? ""
    let snapshot = ruleSnapshot(window, title: title, monitorValues: monitorValues)
    if snapshot == state.baseline { return .unchanged }
    state.title = title
    state.baseline = snapshot
    var matched: Set<Int> = []
    var toRun: [WindowDetectedCallback] = []
    var chainStopped = false
    for (index, rule) in config.onWindowDetected.enumerated() {
        guard let recheck = rule.recheck, await rule.matches(window, knownTitle: title) else { continue }
        matched.insert(index)
        let fires = switch recheck {
            case .untilMatched: !state.spent.contains(index)
            case .everyMatch: !state.matched.contains(index)
            case .everyChange: true
        }
        if recheck == .untilMatched { state.spent.insert(index) }
        // Same order and `check-further-callbacks` as at detection. A rule that fires behind one
        // that stopped the chain is shadowed, and counts as matched, as it would at detection.
        if fires && !chainStopped {
            toRun.append(rule)
            chainStopped = !rule.checkFurtherCallbacks
        }
    }
    state.matched = matched
    return toRun.isEmpty ? .changed(state) : .fires(toRun, state)
}

@MainActor
func saveRuleRecheck(_ window: Window, _ state: RuleRecheckState) {
    // A reload started the window over meanwhile: its state refers to newer rule numbers
    guard state.generation == ruleRecheckGeneration else { return }
    window.ruleRecheck = state
}

/// Runs the rules a check found, then takes the result as the new baseline: a rule's own changes
/// don't count as changes, so rules can't bounce a window back and forth. The baseline keeps the
/// check's title: rule commands don't retitle windows, so a newer title is a change still to check.
@MainActor
private func runRuleRecheck(_ window: Window, _ rules: [WindowDetectedCallback], _ checked: RuleRecheckState) async {
    var running = checked
    running.isBusy = true
    saveRuleRecheck(window, running)
    for rule in rules {
        _ = await rule.run.run(.defaultEnv.withWindowId(window.windowId), CmdIoImpl.emptyStdinIgnoringOut)
    }
    guard checked.generation == ruleRecheckGeneration else { return }
    window.ruleRecheck = await seededRuleRecheckState(window, title: checked.title, alreadySpent: checked.spent)
}

/// The check pass at the end of a heavy refresh: checks the `recheck` rules of each window whose
/// watched state changed, and runs the ones that fire. Returns whether any rule ran.
@MainActor
func recheckWindowRules(_ windows: [Window]) async -> Bool {
    guard config.hasRecheckRules else { return false }
    var ranAny = false
    var monitorValuesByWorkspace: [String: [String]] = [:]
    for window in windows.sorted(by: { $0.windowId < $1.windowId }) {
        let key = window.nodeWorkspace?.name ?? ""
        let monitorValues = monitorValuesByWorkspace[key] ?? ruleMonitorValues(window.nodeWorkspace)
        monitorValuesByWorkspace[key] = monitorValues
        switch await checkRuleRecheck(window, monitorValues: monitorValues) {
            case .unchanged, .busy: continue
            case .changed(let state): saveRuleRecheck(window, state)
            case .fires(let rules, let state):
                await runRuleRecheck(window, rules, state)
                ranAny = true
        }
    }
    return ranAny
}
