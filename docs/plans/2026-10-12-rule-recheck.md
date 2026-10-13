# Rule Recheck Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Let an `[[on-window-detected]]` rule opt into being checked again after detection (`recheck = 'until-matched' | 'every-match' | 'every-change'`), whenever something its `if` can test changes: the window's title, workspace, monitor, layout or fullscreen state.

**Architecture:** One check, two triggers, and rules only ever run at one point: the end of a heavy refresh. (1) A new per-window `kAXTitleChangedNotification` keeps `Window.lastKnownTitle` current and does a quick in-memory check; if a rule would fire, it starts a refresh (at most one per 250 ms). (2) At the end of every heavy refresh, each tracked window's watched state (a few `%{...}` values, in memory) is compared with its baseline; changed windows are checked and firing rules run. Matchers get the known title through a task-local, so checks never ask the app. After rules run, the post-run state becomes the baseline, so a rule's own changes never count as changes.

**Tech Stack:** Swift 6 (AeroSpace fork), XCTest (`swift test`), AppKit Accessibility (AXObserver), AsciiDoc docs; aero-helper's AeroProfile Swift package for the TOML generator.

**Worktree:** already in worktree `rule-changes` (`.claude/worktrees/rule-changes`); Task 1 renames its branch to `feature/rule-recheck`.

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

**Commits:** every `git commit` below ends with
`--trailer "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" --trailer "Claude-Session: https://claude.ai/code/session_0159WQUDtgTGQa3rGKLb8six"`
(written as `<TRAILERS>`). No heredocs or compound shell: this worktree session refuses them; put anything longer in a scratchpad script.

---

## Context

Rules in `on-window-detected` run once, when AeroSpace first sees a window (`onWindowDetected`, `Sources/AppBundle/tree/MacWindow.swift:288`). Apps that set their title after the window appears (browser popouts like the `bitwarden` rule's, PWAs, Electron apps) slip past title rules; the guide warns about it ("Some windows initialize their title after the window appears"). Upstream has it open as nikitabobko/AeroSpace#177. James wants rules that keep applying after discovery, chosen per rule, re-checked on any change to what a rule can test, not only the title (agreed 2026-10-12). A review of the first draft against the code found the fixes folded in below.

## Design

- **Key:** `recheck` on a rule. Absent: checked once at detection (today). `until-matched`: checked on every change until it matches once, then never again for that window. `every-match`: runs each time the whole `if` goes from false to true. `every-change`: runs on every change while the `if` matches (for `exec-and-forget` hooks). At detection these rules behave like any rule.
- **No condition restrictions:** a change re-evaluates the rule's whole `if` (legacy `if.*` or `if = 'test ...'`).
- **Watched state:** `%{window-title}`, `%{window-is-fullscreen}`, `%{window-layout}`, `%{window-parent-container-orientation}`, `%{workspace}`, `%{monitor-name}`, `%{monitor-id}`. Not watched: `%{window-x/y/width/height}` (rules *can* test them with `test ... =`, but they change on every layout and a floating window's would need the app), `%{workspace-is-focused/visible}` (every workspace switch), `%{window-tree-index}` (siblings). Finding a workspace's monitor goes through `NSScreen` each time, so a pass works it out once per workspace.
- **Where rules run:** only in the check pass at the end of `runHeavyCompleteRefreshSession` (after `normalizeLayoutReason`, before `layoutWorkspaces`), like detection rules run inside a refresh. A refresh follows every command, keybinding, AX event and mouse drag. Never per raw moved/resized event.
- **Title path:** record the title (repeats ignored), then check in memory. Nothing fires: save the new state, no refresh. A rule fires (or the window's rules are mid-run): start a refresh, at most one per 250 ms; the pending one reads the newest titles. A spinner retitling 10×/s therefore can't starve or flood refreshes.
- **Never ask the app during a check:** matchers read the title through `Window.titleForRules`, which returns the task-local known title while a check runs.
- **Anti-bounce:** after rules run, the post-run state becomes the baseline; rules matching it count as applied. The baseline keeps the title the check used (rule commands don't retitle), so a title that changed during the run is still a change to check.
- **Order:** opted-in rules keep config order and `check-further-callbacks`; a rule that fires behind one that stopped the chain is shadowed and counts as matched (as at detection).
- **Skipped:** windows in a macOS native state (minimized, hidden app, native fullscreen: `layoutReason != .standard`) wait until they're back; otherwise a move rule would bind a minimized window into a tiling tree. Windows claimed by `expect-window` and popups are never tracked. `run-callback on-window-detected` re-seeds only windows already tracked. `no-focus` only applies at detection.
- **Reload:** bumps a generation counter and starts every tracked window over against the new rules (rules matching right then count as applied). A check or run that straddles a reload doesn't write back.
- **Closed-windows-cache restores** (sleep/lock): a new object whose rules don't run again; tracked from where it is.
- **Title subscription is best effort**, kept apart from `bulkSubscribe`'s all-or-nothing set in `AxWindow.new` (`MacApp.swift:573`): there, one refused key leaves the window unmanaged.
- **Known trade-offs:** each title change costs two AX reads (role, title) on that app's AX thread, even with no `recheck` rules (measured: 10 windows, 0 title changes in 10 s). An `every-change` script that changes its own window through the `aerospace` CLI sets the rule off again (documented).
- **aero-helper** generates `aerospace.toml`'s rules: its `TOMLGenerator` must emit `recheck`, and also string `if` (today it only writes table `if`, so `if = 'test ...'` rules lose their condition).

## Files

- Create: `Sources/AppBundle/windowRuleRecheck.swift` (all recheck logic), `Sources/AppBundleTests/tree/RuleRecheckTest.swift`
- Modify: `Sources/AppBundle/config/parseOnWindowDetected.swift`, `Sources/AppBundle/tree/MacWindow.swift`, `Sources/AppBundle/tree/Window.swift`, `Sources/AppBundle/command/format.swift`, `Sources/AppBundle/tree/MacApp.swift`, `Sources/AppBundle/layout/refresh.swift`, `Sources/AppBundle/command/impl/ReloadConfigCommand.swift`, `Sources/AppBundleTests/config/ConfigTest.swift`, `Sources/AppBundleTests/command/{FormatTest,ListWindowsTest,ScrollCommandTest}.swift` (rename only), `docs/guide.adoc`, `CLAUDE.md`
- aero-helper: `SharedCode/Sources/AeroProfile/TOMLGenerator.swift`, `SharedCode/Tests/AeroProfileTests/TOMLGeneratorTests.swift`

---

### Task 1: Set Up Worktree

**Step 1: Validate you are in a worktree**

Run: `git rev-parse --show-toplevel` and `git branch --show-current`
Expected: `/Users/jedwards/code/aero/AeroSpace/.claude/worktrees/rule-changes` and `worktree-rule-changes`. If not in a worktree, use `EnterWorktree` with `name: "rule-recheck"`.

**Step 2: Rename the branch**

Run: `git branch -m feature/rule-recheck`
Expected: `git branch --show-current` prints `feature/rule-recheck`.

**Step 3: Save the plan to the repo**

Call `mcp__project-tools__write_plan` with feature name `rule-recheck`, this plan's content and project dir `/Users/jedwards/code/aero/AeroSpace/.claude/worktrees/rule-changes`. Then `git add docs/plans` and `git commit -m "docs(plans): rule recheck plan" <TRAILERS>`.

**Step 4: Verify clean baseline**

Run: `make check`
Expected: `Build complete!`. If not, investigate before proceeding.

---

### Task 2: Parse `recheck`

**Files:**
- Modify: `Sources/AppBundle/config/parseOnWindowDetected.swift`
- Test: `Sources/AppBundleTests/config/ConfigTest.swift` (after `testParseOnWindowDetectedNoFocus`)

**Step 1: Write the failing tests**

```swift
    func testParseOnWindowDetectedRecheck() {
        let result = parseConfig(
            """
            on-window-detected = [
                { if.window-title-regex-substring = 'bitwarden', recheck = 'until-matched', run = [] },
                { if = 'true', recheck = 'every-match', run = [] },
                { if = 'true', recheck = 'every-change', run = [] },
                { if = 'true', run = [] },
            ]
            """,
        )
        assertEquals(result.strErrors, [])
        assertEquals(result.config.onWindowDetected.map(\.recheck), [.untilMatched, .everyMatch, .everyChange, nil])

        // recheck participates in equality
        assertNotEquals(
            WindowDetectedCallback(matcher: .command(.empty), recheck: .everyMatch, rawRun: .empty),
            WindowDetectedCallback(matcher: .command(.empty), rawRun: .empty),
        )
    }

    func testParseOnWindowDetectedRecheckRejectsUnknownValues() {
        let result = parseConfig(
            """
            [[on-window-detected]]
                if = 'true'
                recheck = 'always'
                run = []
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] on-window-detected[0].recheck: Can't parse recheck 'always'. Possible values: until-matched, every-match, every-change",
        ])
        assertEquals(result.config.onWindowDetected, [])
    }
```

**Step 2: Run to verify they fail**

Run: `swift test --filter ConfigTest/testParseOnWindowDetectedRecheck`
Expected: build FAILS: `extra argument 'recheck' in call` / `has no member 'recheck'`.

**Step 3: Implement**

In `parseOnWindowDetected.swift`, add `recheck` to `WindowDetectedCallback` between `noFocus` and `rawRun` (memberwise init order: `matcher, checkFurtherCallbacks, noFocus, recheck, rawRun`):

```swift
    var noFocus: Bool = false
    var recheck: RuleRecheck? = nil
    var rawRun: Shell<any Command>? = nil
```

In `debugJson`, after the `no-focus` lines:

```swift
        if let recheck {
            result["recheck"] = .string(recheck.rawValue)
        }
```

In `==`:

```swift
        lhs.matcher == rhs.matcher && lhs.checkFurtherCallbacks == rhs.checkFurtherCallbacks &&
            lhs.noFocus == rhs.noFocus && lhs.recheck == rhs.recheck && lhs.run.strictEquals(rhs.run)
```

After `WindowDetectedCallback`:

```swift
/// When a rule is checked again after its window was detected. Without it, a rule is checked once,
/// at detection. See windowRuleRecheck.swift.
enum RuleRecheck: String, CaseIterable, Equatable, Sendable {
    /// On every change until the rule matches once, then never again for that window
    case untilMatched = "until-matched"
    /// Each time the rule's `if` goes from not matching to matching
    case everyMatch = "every-match"
    /// On every change while the rule's `if` matches
    case everyChange = "every-change"
}
```

In `windowDetectedParser`, after `"no-focus"`:

```swift
    "recheck": Parser(\.recheck, upcast(parseRuleRecheck)),
```

After `parseCaseInsensitiveRegex`:

```swift
private func parseRuleRecheck(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<RuleRecheck> {
    parseString(raw, backtrace).flatMap {
        RuleRecheck(rawValue: $0).toResult(.init(
            backtrace,
            "Can't parse recheck '\($0)'. Possible values: \(RuleRecheck.allCases.map(\.rawValue).joined(separator: ", "))",
        ))
    }
}
```

**Step 4: Run to verify they pass**

Run: `swift test --filter ConfigTest`
Expected: PASS (all ConfigTest cases).

**Step 5: Commit**

`git add Sources/AppBundle/config/parseOnWindowDetected.swift Sources/AppBundleTests/config/ConfigTest.swift` then `git commit -m "feat(rules): parse the recheck key" <TRAILERS>`

---

### Task 3: Matchers can use a known title

**Files:**
- Create: `Sources/AppBundle/windowRuleRecheck.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift:316-335` (`WindowDetectedCallback.matches`, legacy title read), `Sources/AppBundle/command/format.swift:43` (`resolveWindow`)
- Test: Create `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing test**

Create `RuleRecheckTest.swift`:

```swift
@testable import AppBundle
import Common
import XCTest

private let testAppId = "bobko.AeroSpace.test-app"

@MainActor
final class RuleRecheckTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheState()
    }

    private func rule(_ recheck: RuleRecheck?, if matcher: String, run: String, checkFurther: Bool = false) -> WindowDetectedCallback {
        WindowDetectedCallback(
            matcher: .command(parseCommand(matcher).cmdOrDie),
            checkFurtherCallbacks: checkFurther,
            recheck: recheck,
            rawRun: parseCommand(run).cmdOrDie,
        )
    }

    func testMatchersUseTheKnownTitleInsteadOfAskingTheApp() async {
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "from the app")
        let command = rule(nil, if: "test %{window-title} ~= known", run: "layout floating")
        let legacy = WindowDetectedCallback(
            matcher: .legacy(LegacyWindowDetectedCallbackMatcher(windowTitleRegexSubstring: CaseInsensitiveRegex.new("known").getOrDie())),
            rawRun: .empty,
        )

        assertEquals(await command.matches(window), false)
        assertEquals(await command.matches(window, knownTitle: "known title"), true)
        assertEquals(await legacy.matches(window), false)
        assertEquals(await legacy.matches(window, knownTitle: "known title"), true)
    }
}
```

**Step 2: Run to verify it fails**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `extra argument 'knownTitle' in call`.

**Step 3: Implement**

Create `Sources/AppBundle/windowRuleRecheck.swift`:

```swift
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
```

In `MacWindow.swift`, replace the `extension WindowDetectedCallback { ... }` block with:

```swift
extension WindowDetectedCallback {
    /// - Parameter knownTitle: the title to match against instead of asking the app
    @MainActor
    func matches(_ window: Window, knownTitle: String? = nil) async -> Bool {
        if let knownTitle {
            return await $knownRuleTitle.withValue(KnownWindowTitle(windowId: window.windowId, title: knownTitle)) {
                await matches(window)
            }
        }
        switch self.matcher {
            case .legacy(let matcher):
                return await matcher.matches(window)
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}
```

In `LegacyWindowDetectedCallbackMatcher.matches` (same file), change `window.getTitle(.nonCancellable)` to `window.titleForRules(.nonCancellable)`.

In `format.swift` `resolveWindow(_:needsTitle:needsRect:_:)`, change `try await window.getTitle(cm)` to `try await window.titleForRules(cm)`. This is where `test %{window-title}` gets its title; outside a check the task-local is nil, so list-windows and friends are unchanged.

**Step 4: Run to verify it passes**

Run: `swift test --filter "RuleRecheckTest|OnWindowDetectedTest|WindowExpectationTest|FormatTest"`
Expected: PASS.

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundle/tree/MacWindow.swift Sources/AppBundle/command/format.swift Sources/AppBundleTests/tree/RuleRecheckTest.swift` then `git commit -m "feat(rules): let rule matchers use a known window title" <TRAILERS>`

---

### Task 4: Watched-state snapshot

**Files:**
- Modify: `Sources/AppBundle/command/format.swift:78` (rename `forTest` → `prefetched`), its callers in `Sources/AppBundleTests/command/{FormatTest,ListWindowsTest,ScrollCommandTest}.swift`, `Sources/AppBundle/windowRuleRecheck.swift`
- Test: `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing test**

```swift
    func testSnapshotChangesWithTitleLayoutAndWorkspace() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let snapshot = { ruleSnapshot(window, title: $0, monitorValues: ruleMonitorValues(window.nodeWorkspace)) }
        let tiled = snapshot("a")
        assertEquals(snapshot("a"), tiled)
        assertNotEquals(snapshot("b"), tiled)

        window.bindAsFloatingWindow(to: workspace)
        let floating = snapshot("a")
        assertNotEquals(floating, tiled)

        window.bindAsFloatingWindow(to: Workspace.get(byName: "other"))
        assertNotEquals(snapshot("a"), floating)
    }
```

**Step 2: Run to verify it fails**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `cannot find 'ruleSnapshot' in scope`.

**Step 3: Implement**

In `format.swift`, rename the constructor (it isn't test-only any more):

```swift
    /// A window whose title (and rect) the caller already has
    static func prefetched(window: Window, title: String?, rect: Rect? = nil) -> Self {
        .init(window: window, title: title, rect: rect)
    }
```

Update every caller (three test files):
`sed -i '' 's/\.forTest(window:/.prefetched(window:/g' Sources/AppBundleTests/command/FormatTest.swift Sources/AppBundleTests/command/ListWindowsTest.swift Sources/AppBundleTests/command/ScrollCommandTest.swift`
Then `grep -rn "forTest(window" Sources` must print nothing.

Append to `windowRuleRecheck.swift`:

```swift
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
```

**Step 4: Run to verify it passes**

Run: `swift test --filter "RuleRecheckTest|FormatTest|ListWindowsTest|ScrollCommandTest"`
Expected: PASS.

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundle/command/format.swift Sources/AppBundleTests` then `git commit -m "feat(rules): snapshot the window state rules can test" <TRAILERS>`

---

### Task 5: Track windows from detection

**Files:**
- Modify: `Sources/AppBundle/tree/Window.swift:14` (new fields after `isAwaitingOnWindowDetected`), `Sources/AppBundle/windowRuleRecheck.swift`, `Sources/AppBundle/tree/MacWindow.swift:272-303` (`tryOnWindowDetected`, `onWindowDetected`)
- Test: `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing tests**

```swift
    private func detect(id: UInt32, title: String) async -> TestWindow {
        let window = TestWindow.new(id: id, parent: Workspace.get(byName: name).rootTilingContainer, title: title)
        await tryOnWindowDetected(window)
        return window
    }

    func testDetectionStartsTrackingTheWindow() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Untitled")

        assertEquals(window.nodeWorkspace?.name, name)
        assertEquals(window.lastKnownTitle, "Untitled")
        assertEquals(window.ruleRecheck?.title, "Untitled")
        assertEquals(window.ruleRecheck?.matched, [])
        assertEquals(window.ruleRecheck?.spent, [])
    }

    func testAnUntilMatchedRuleThatRunsAtDetectionIsSpent() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Bitwarden")

        assertEquals(window.nodeWorkspace?.name, "B")
        assertEquals(window.ruleRecheck?.spent, [0])
    }

    func testDetectionUsesTheTitleFromTitleEvents() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "stale")
        window.hasTitleEvents = true
        window.lastKnownTitle = "Meet"

        await tryOnWindowDetected(window)

        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testRunCallbackLeavesUntrackedWindowsUntracked() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "layout floating")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)

        assertNil(window.ruleRecheck)
    }
```

**Step 2: Run to verify they fail**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `value of type 'TestWindow' has no member 'lastKnownTitle'`.

**Step 3: Implement**

In `Window.swift`, after `var isAwaitingOnWindowDetected: Bool = false`:

```swift
    /// The latest title from the app's title-changed notifications, else from the last read. Rule
    /// rechecks match against it, so they never ask the app. See windowRuleRecheck.swift.
    var lastKnownTitle: String? = nil
    /// Title-changed notifications have arrived for this window, so `lastKnownTitle` is current
    var hasTitleEvents: Bool = false
    /// State of this window's `recheck` rules. nil: not tracked (claimed by expect-window, a popup,
    /// or its `on-window-detected` callbacks haven't run yet)
    var ruleRecheck: RuleRecheckState? = nil
```

Append to `windowRuleRecheck.swift`:

```swift
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
```

In `MacWindow.swift`, `tryOnWindowDetected`: change the call to
`_ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window, isDetection: true)`.

Replace `onWindowDetected`:

```swift
/// - Parameter isDetection: the window was just detected, not handed over by `run-callback`. Its
///   `recheck` rules start following it then; `run-callback` re-seeds only windows already followed,
///   so popups and windows claimed by expect-window stay untracked.
@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window, isDetection: Bool = false) async -> Int32ExitCode {
    broadcastWindowDetected(window)
    let tracks = isDetection || window.ruleRecheck != nil
    // With `recheck` rules in the config, read the title once: these rules and the baseline for
    // later checks then see the same title, so a change that lands meanwhile still counts as one.
    let title = tracks && config.hasRecheckRules ? await window.titleForRuleSeed() : nil
    var lastExitCode = Int32ExitCode.succ
    var ran: Set<Int> = []
    for (index, callback) in config.onWindowDetected.enumerated() {
        guard await callback.matches(window, knownTitle: title) else { continue }
        ran.insert(index)
        if callback.noFocus {
            // Arm before (and regardless of) the run commands, so the suppression is active
            // even if a run command fails or moves the window.
            armNoFocusSuppression(for: window)
        }
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks { break }
    }
    if tracks {
        window.ruleRecheck = await seededRuleRecheckState(window, title: title ?? window.lastKnownTitle ?? "", alreadySpent: ran)
    }
    return lastExitCode
}
```

**Step 4: Run to verify they pass**

Run: `swift test --filter "RuleRecheckTest|OnWindowDetectedTest|WindowExpectationTest|AutoTilingTest"`
Expected: PASS.

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundle/tree/Window.swift Sources/AppBundle/tree/MacWindow.swift Sources/AppBundleTests/tree/RuleRecheckTest.swift` then `git commit -m "feat(rules): start tracking recheck rules at detection" <TRAILERS>`

---

### Task 6: The check and the run

**Files:**
- Modify: `Sources/AppBundle/windowRuleRecheck.swift`
- Test: `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing tests**

```swift
    private func move(_ window: Window, to workspace: String) {
        window.bind(to: Workspace.get(byName: workspace).rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    /// A title-changed notification followed by the refresh's check pass
    private func retitle(_ window: Window, _ title: String) async -> Bool {
        recordTitleEvent(window, title)
        return await recheckWindowRules([window])
    }

    func testTitleEventsIgnoreRepeatsOfTheSameTitle() async {
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(recordTitleEvent(window, "a"), true)
        assertEquals(recordTitleEvent(window, "a"), false)
        assertEquals(recordTitleEvent(window, "b"), true)
        assertEquals(window.lastKnownTitle, "b")
        assertEquals(window.hasTitleEvents, true)
    }

    func testUntilMatchedCatchesALateTitleOnce() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Untitled")
        assertEquals(window.nodeWorkspace?.name, name)

        assertEquals(await retitle(window, "Bitwarden"), true)
        assertEquals(window.nodeWorkspace?.name, "B")

        move(window, to: name)
        assertEquals(await retitle(window, "Untitled"), false)
        assertEquals(await retitle(window, "Bitwarden"), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testEveryMatchRunsEachTimeTheIfStartsMatching() async {
        config.onWindowDetected = [rule(.everyMatch, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet - standup"), true)
        assertEquals(window.nodeWorkspace?.name, "M")

        move(window, to: name)
        assertEquals(await retitle(window, "Meet - standup (2)"), false) // still matching: not a new match
        assertEquals(await retitle(window, "Inbox"), false)
        assertEquals(await retitle(window, "Meet - retro"), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testEveryChangeRunsOnEveryChangeWhileMatching() async {
        config.onWindowDetected = [rule(.everyChange, if: "test %{app-bundle-id} = \(testAppId)", run: "layout floating tiling")]
        let window = await detect(id: 2, title: "a") // a recheck rule runs at detection like any rule
        assertEquals(window.parent is FloatingWindowsContainer, true)

        assertEquals(await retitle(window, "b"), true)
        assertEquals(window.parent is TilingContainer, true)
        assertEquals(await retitle(window, "c"), true)
        assertEquals(window.parent is FloatingWindowsContainer, true)

        assertEquals(await recheckWindowRules([window]), false) // nothing changed
    }

    func testOtherCriteriaAreCheckedWhenTheyChange() async {
        config.onWindowDetected = [rule(.everyMatch, if: "test %{workspace} = W", run: "layout floating")]
        let window = await detect(id: 2, title: "a")
        assertEquals(window.parent is TilingContainer, true)

        move(window, to: "W")
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.parent is FloatingWindowsContainer, true)
    }

    func testARulesOwnMoveDoesNotSetOffOtherRules() async {
        config.onWindowDetected = [
            rule(.everyMatch, if: "test %{workspace} = A", run: "move-node-to-workspace B"),
            rule(.everyMatch, if: "test %{workspace} = B", run: "move-node-to-workspace A"),
        ]
        let window = await detect(id: 2, title: "a")

        move(window, to: "A")
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.nodeWorkspace?.name, "B")
        assertEquals(await recheckWindowRules([window]), false)
        assertEquals(window.nodeWorkspace?.name, "B")
    }

    func testTheFirstRuleToFireShadowsTheRest() async {
        config.onWindowDetected = [
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace X"),
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace Y"),
        ]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "X")

        move(window, to: name)
        assertEquals(await recheckWindowRules([window]), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testCheckFurtherCallbacksLetsLaterRulesRun() async {
        config.onWindowDetected = [
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace X", checkFurther: true),
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "layout floating"),
        ]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "X")
        assertEquals(window.parent is FloatingWindowsContainer, true)
    }

    func testRulesWithoutRecheckOnlyRunAtDetection() async {
        config.onWindowDetected = [rule(nil, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testWindowsInAMacosNativeStateWait() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")
        window.layoutReason = .macos(prevParentKind: .tilingContainer) // minimized, say

        assertEquals(await retitle(window, "Meet"), false)
        window.layoutReason = .standard
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testWindowsClaimedByExpectWindowAreLeftAlone() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        armWindowExpectation(
            matcher: LegacyWindowDetectedCallbackMatcher(appId: testAppId),
            commands: parseCommand("move-node-to-workspace X").cmdOrDie,
            timeout: 10,
        )
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, title: "Inbox")

        await tryOnWindowDetected(window)
        assertEquals(window.nodeWorkspace?.name, "X")
        assertNil(window.ruleRecheck)

        assertEquals(await retitle(window, "Meet"), false)
        assertEquals(window.nodeWorkspace?.name, "X")
    }
```

**Step 2: Run to verify they fail**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `cannot find 'recordTitleEvent' in scope` / `cannot find 'recheckWindowRules' in scope`.

**Step 3: Implement**

Append to `windowRuleRecheck.swift`:

```swift
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
```

**Step 4: Run to verify they pass**

Run: `swift test --filter RuleRecheckTest`
Expected: PASS (all cases).

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundleTests/tree/RuleRecheckTest.swift` then `git commit -m "feat(rules): check recheck rules against the window's watched state" <TRAILERS>`

---

### Task 7: Title-changed notifications

**Files:**
- Modify: `Sources/AppBundle/windowRuleRecheck.swift`, `Sources/AppBundle/tree/MacApp.swift:573-581` (`AxWindow.new`)
- Test: `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing tests** (only paths that don't start a refresh: a scheduled refresh would run real AX code in the test process)

```swift
    func testATitleEventForAnUntrackedWindowOnlyUpdatesItsTitle() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        await windowTitleChanged(windowId: 2, title: "Meet")

        assertEquals(window.lastKnownTitle, "Meet")
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testATitleChangeThatSetsOffNoRuleIsSavedRightAway() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        await windowTitleChanged(windowId: 2, title: "Inbox (1)")

        assertEquals(window.ruleRecheck?.title, "Inbox (1)")
        assertEquals(window.nodeWorkspace?.name, name)
    }
```

**Step 2: Run to verify they fail**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `cannot find 'windowTitleChanged' in scope`.

**Step 3: Implement**

Append to `windowRuleRecheck.swift`:

```swift
@MainActor private var titleRecheckTask: Task<(), Never>? = nil
@MainActor private var lastTitleRecheckAt: ContinuousClock.Instant? = nil
/// A window can retitle many times a second (a spinner): title changes start a refresh at most this often
private let titleRecheckInterval: Duration = .milliseconds(250)

/// A title-changed notification. Most end at the in-memory check here; only one that makes a rule
/// fire starts a refresh, whose check pass runs the rules in a session with a layout after it.
@MainActor
func windowTitleChanged(windowId: UInt32, title: String) async {
    guard let window = Window.get(byId: windowId), recordTitleEvent(window, title) else { return }
    guard TrayMenuModel.shared.isEnabled, config.hasRecheckRules else { return }
    switch await checkRuleRecheck(window, monitorValues: ruleMonitorValues(window.nodeWorkspace)) {
        case .unchanged: break
        case .changed(let state): saveRuleRecheck(window, state)
        case .busy, .fires: scheduleTitleRecheck()
    }
}

@MainActor
private func scheduleTitleRecheck() {
    guard titleRecheckTask == nil else { return } // one is coming, and it reads the newest titles
    let wait = lastTitleRecheckAt.map { titleRecheckInterval - $0.duration(to: .now) } ?? .zero
    titleRecheckTask = Task.startUnstructured { @MainActor in
        if wait > .zero { try? await Task.sleep(for: wait) }
        titleRecheckTask = nil
        lastTitleRecheckAt = .now
        scheduleCancellableCompleteRefreshSession(.ax(kAXTitleChangedNotification))
    }
}

/// kAXTitleChangedNotification, on the app's AX thread
func titleChangedObs(_: AXObserver, _ element: AXUIElement, _: CFString, _: UnsafeMutableRawPointer?) {
    // Rules see the window's title, not the titles of the elements inside it
    guard element.get(Ax.roleAttr) == kAXWindowRole, let windowId = element.containingWindowId() else { return }
    let title = element.get(Ax.titleAttr) ?? ""
    Task.startUnstructured { @MainActor in
        await windowTitleChanged(windowId: windowId, title: title)
    }
}
```

In `MacApp.swift`, replace `AxWindow.new` with:

```swift
    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let pid = nsApp.resolvedProcessIdentifier
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(pid, ax, job, handlers)
        if subscriptions.isEmpty { return nil }
        // Apart from the ones above, and allowed to fail: bulkSubscribe drops them all when the app
        // refuses one notification, and refusing this one mustn't leave the window unmanaged.
        let titleSubscriptions = try unsafe AxSubscription.bulkSubscribe(pid, ax, job, [(titleChangedObs, [kAXTitleChangedNotification])])
        return AxWindow(windowId: windowId, ax, subscriptions + titleSubscriptions)
    }
```

**Step 4: Run to verify they pass**

Run: `swift test --filter RuleRecheckTest` then `make check`
Expected: PASS; `Build complete!`.

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundle/tree/MacApp.swift Sources/AppBundleTests/tree/RuleRecheckTest.swift` then `git commit -m "feat(rules): follow window title changes" <TRAILERS>`

---

### Task 8: Refresh, reload and restored windows

**Files:**
- Modify: `Sources/AppBundle/windowRuleRecheck.swift`, `Sources/AppBundle/layout/refresh.swift:56-57`, `Sources/AppBundle/command/impl/ReloadConfigCommand.swift:54-55`, `Sources/AppBundle/tree/MacWindow.swift:76-78`
- Test: `Sources/AppBundleTests/tree/RuleRecheckTest.swift`

**Step 1: Write the failing tests**

```swift
    func testReloadStartsTrackedWindowsOverAgainstTheNewRules() async {
        config.onWindowDetected = []
        let matching = await detect(id: 2, title: "Meet")
        let other = await detect(id: 3, title: "Inbox")

        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        await reseedRuleRechecks([matching, other])

        // Already matching when the rule arrived: counts as applied, as at detection
        assertEquals(await retitle(matching, "Meet (2)"), false)
        assertEquals(matching.nodeWorkspace?.name, name)
        assertEquals(await retitle(other, "Meet"), true)
        assertEquals(other.nodeWorkspace?.name, "M")
    }

    func testAStateFromBeforeAReloadIsNotSaved() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")
        let stale = window.ruleRecheck!

        await reseedRuleRechecks([window])
        saveRuleRecheck(window, stale)

        assertEquals(window.ruleRecheck?.generation, ruleRecheckGeneration)
    }

    func testARestoredWindowIsTrackedWithoutRunningItsRules() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        await restartRuleRecheck(window)
        assertEquals(window.nodeWorkspace?.name, name)

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }
```

**Step 2: Run to verify they fail**

Run: `swift test --filter RuleRecheckTest`
Expected: build FAILS: `cannot find 'reseedRuleRechecks' in scope`.

**Step 3: Implement**

Append to `windowRuleRecheck.swift`:

```swift
/// Starts tracking the window over from its state now, without running anything
@MainActor
func restartRuleRecheck(_ window: Window) async {
    let title = config.hasRecheckRules ? await window.titleForRuleSeed() : window.lastKnownTitle ?? ""
    window.ruleRecheck = await seededRuleRecheckState(window, title: title)
}

/// The config's rules changed, and their numbers with them: starts every tracked window over
/// against the new rules
@MainActor
func reseedRuleRechecks(_ windows: [Window]) async {
    ruleRecheckGeneration += 1
    for window in windows where window.ruleRecheck != nil {
        await restartRuleRecheck(window)
    }
}
```

`refresh.swift`, in `runHeavyCompleteRefreshSession`:

```swift
            try await normalizeLayoutReason()
            // After detection and normalization: the check sees where this refresh left every window
            if await recheckWindowRules(MacWindow.allWindows) {
                await refreshModel_nonCancellable()
                updateTrayText()
            }
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
```

`ReloadConfigCommand.swift`, right after `config = parseResult.config` and `configUrl = result.configUrl`:

```swift
        await reseedRuleRechecks(MacWindow.allWindows)
```

`MacWindow.swift`, in `getOrRegister`:

```swift
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await tryOnWindowDetected(window)
        } else {
            await restartRuleRecheck(window) // a new object back from the cache: its rules don't run again
        }
```

**Step 4: Run to verify they pass**

Run: `swift test --filter RuleRecheckTest` then `make check`
Expected: PASS; `Build complete!`.

**Step 5: Commit**

`git add Sources/AppBundle/windowRuleRecheck.swift Sources/AppBundle/layout/refresh.swift Sources/AppBundle/command/impl/ReloadConfigCommand.swift Sources/AppBundle/tree/MacWindow.swift Sources/AppBundleTests/tree/RuleRecheckTest.swift` then `git commit -m "feat(rules): run recheck rules after every refresh; reseed on reload and restore" <TRAILERS>`

---

### Task 9: Docs

**Files:**
- Modify: `docs/guide.adoc` (on-window-detected section, ~lines 616-725), `CLAUDE.md` (Key architecture)

**Step 1: Guide**

In the first example block, after `no-focus = true` add `    recheck = 'until-matched'`.

After the `no-focus` paragraphs (before "To keep a single window that a script is about to open..."), add:

```adoc
Additionally, `recheck` checks a rule again after the window was detected, whenever something its `if`
can test changes: the window's title, workspace, monitor, layout or fullscreen state.
Without `recheck`, a rule is checked once, when the window is detected.
At detection, a rule with `recheck` behaves like any other rule.

* `recheck = 'until-matched'` checks the rule on every change until it matches once, then never again for that window.
Use it for windows that set their title after they appear.
* `recheck = 'every-match'` runs the rule each time its `if` goes from not matching to matching.
* `recheck = 'every-change'` runs the rule on every change while its `if` matches.
It suits `exec-and-forget` scripts. With a move command, a window you move by hand goes back at its next change.
A script that changes the same window through `aerospace` sets the rule off again, so don't toggle anything from one.

[source,toml]
----
[[on-window-detected]]
    if.window-title-regex-substring = 'bitwarden'
    recheck = 'until-matched'
    run = 'layout floating'
----

Rules with `recheck` are checked in the order of the list, and `check-further-callbacks` works as at detection.
A rule's own commands don't count as changes, so two rules can't move a window back and forth.
Position and size aren't watched: they change on every layout.
A minimized or hidden window, or one in macOS fullscreen, is checked once it's back.
`no-focus` only applies at detection, and windows claimed by xref:./commands.adoc#expect-window[expect-window] are never rechecked.
```

Change the IMPORTANT note to:

```adoc
IMPORTANT: Some windows initialize their title after the window appears.
`window-title-regex-substring` may not work as expected for such windows, unless the rule has `recheck = 'until-matched'`.
```

**Step 2: CLAUDE.md** — under "Key architecture", after the `expect-window` bullet:

```markdown
- `recheck` rules (fork-only, `recheck = until-matched|every-match|every-change` on an `on-window-detected` rule):
  `Sources/AppBundle/windowRuleRecheck.swift`. Rules run only in the check pass at the end of
  `runHeavyCompleteRefreshSession`; title notifications (`AxWindow.new`, best effort) check in memory and start a
  refresh (at most every 250 ms) only when a rule would fire. Checks match against `Window.lastKnownTitle` through the
  `knownRuleTitle` task-local, never asking the app.
```

**Step 3: Commit**

`git add docs/guide.adoc CLAUDE.md` then `git commit -m "docs: recheck rules" <TRAILERS>`

---

### Task 10: aero-helper emits `recheck` and string `if`

**Files (aero-helper repo, `/Users/jedwards/code/aero/aero-helper`):**
- Modify: `SharedCode/Sources/AeroProfile/TOMLGenerator.swift:17-35`
- Test: `SharedCode/Tests/AeroProfileTests/TOMLGeneratorTests.swift`

**Step 1: Branch**

Run: `git -C /Users/jedwards/code/aero/aero-helper switch -c feature/rule-recheck`
Expected: `Switched to a new branch 'feature/rule-recheck'` (the repo is on a clean `main`).

**Step 2: Write the failing tests** (after `testEmitsNoFocusOnWindowRules`)

```swift
    func testEmitsRecheckOnWindowRules() {
        let config: [String: Any] = ["on-window-detected": [
            [
                "if": ["window-title-regex-substring": "bitwarden"],
                "run": "layout floating",
                "recheck": "until-matched",
            ] as [String: Any],
        ]]
        let toml = TOMLGenerator.generateTOML(from: config)
        XCTAssertTrue(toml.contains("recheck = \"until-matched\""), "recheck missing from:\n\(toml)")
        assertRoundTrips(config)
    }

    func testEmitsCommandStyleIf() {
        let config: [String: Any] = ["on-window-detected": [
            [
                "if": "test %{workspace} = W",
                "run": "layout floating",
            ] as [String: Any],
        ]]
        let toml = TOMLGenerator.generateTOML(from: config)
        XCTAssertTrue(toml.contains("if = \"test %{workspace} = W\""), "if missing from:\n\(toml)")
        assertRoundTrips(config)
    }
```

**Step 3: Run to verify they fail**

Run: `swift test --package-path /Users/jedwards/code/aero/aero-helper/SharedCode --filter TOMLGeneratorTests`
Expected: FAIL: `recheck missing from:` and `if missing from:`.

**Step 4: Implement** — in `TOMLGenerator.generateTOML`, extend the `if` block and add `recheck` after `no-focus`:

```swift
                if let ifClause = rule["if"] as? [String: Any] {
                    for (key, value) in ifClause.sorted(by: { $0.key < $1.key }) {
                        output += "if.\(key) = \(formatValue(value))\n"
                    }
                } else if let ifCommand = rule["if"] as? String {
                    output += "if = \(formatValue(ifCommand))\n"
                }
```

```swift
                if let recheck = rule["recheck"] as? String {
                    output += "recheck = \(formatValue(recheck))\n"
                }
```

**Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/jedwards/code/aero/aero-helper/SharedCode --filter TOMLGeneratorTests`
Expected: PASS.

**Step 6: Commit**

`git -C /Users/jedwards/code/aero/aero-helper add SharedCode/Sources/AeroProfile/TOMLGenerator.swift SharedCode/Tests/AeroProfileTests/TOMLGeneratorTests.swift` then `git -C /Users/jedwards/code/aero/aero-helper commit -m "feat(profiles): emit recheck and command-style if on window rules" <TRAILERS>`

---

### Task 11: Format, lint, full suite

**Step 1:** Run `./format.sh`, then `git status --short`. Expected: only files this plan touched; commit any formatting changes (`git commit -am "style: swiftformat" <TRAILERS>`).

**Step 2:** Run `./lint.sh > <scratchpad>/lint.log 2>&1` and read the log. Expected: no `Task.init` error, no swiftlint or periphery findings (periphery runs `--strict`: anything unused fails).

**Step 3:** Run `./build-debug.sh -Xswiftc -warnings-as-errors`, then `./swift-test.sh`. Expected: `✅ Swift tests have passed successfully`.

---

### Task 12: Live check (ask James first)

**Step 1:** Ask James before installing (the restart shuffles windows for ~15 s). On his OK: `make -C /Users/jedwards/code/aero/AeroSpace/.claude/worktrees/rule-changes deploy > <scratchpad>/deploy.log 2>&1`. Read the log: the release build succeeded and keep-windows reports every window back.

**Step 2:** Prove the installed binary is new: `grep -c until-matched /Applications/AeroSpace.app/Contents/MacOS/AeroSpace` prints ≥ 1. `aerospace list-windows --all --count` matches the count taken before the install (the title subscription didn't drop windows).

**Step 3:** Add a temporary rule to `~/.config/aerospace/aerospace.toml` (temporary, so not in profiles.toml) and `aerospace reload-config`:

```toml
[[on-window-detected]]
if.app-id = 'com.apple.TextEdit'
if.window-title-regex-substring = 'recheck-test'
recheck = 'until-matched'
run = 'layout floating'
```

**Step 4:** Tell James what will happen and wait for his go-ahead ("I'll open a TextEdit window: it should tile, then float a moment after I save it as recheck-test.txt"). Then `open -a TextEdit`, create a document, and check it tiles (`aerospace list-windows --focused --format '%{window-layout}'`). Save it: `osascript -e 'tell application "TextEdit" to save document 1 in POSIX file "<scratchpad>/recheck-test.txt"'`. Expected: within ~0.3 s `%{window-layout}` is `floating`. Retile it by hand (`aerospace layout tiling`), save it under another name and back: it stays tiled (spent).

**Step 5:** Remove the temporary rule, `aerospace reload-config`, close the TextEdit window. Offer James `recheck = 'until-matched'` on his real `bitwarden` rule (profiles.toml and aerospace.toml together, per CLAUDE.md), only if he wants it.

---

### Task 13: Pull requests (ask James first)

**Step 1:** On James's OK: `git push -u origin feature/rule-recheck`, then `gh pr create --repo MintCollector/AeroSpace --base main` (title `feat(rules): recheck on-window-detected rules after detection`; body ends with the Claude Code attribution lines).

**Step 2:** Same for aero-helper: `git -C /Users/jedwards/code/aero/aero-helper push -u origin feature/rule-recheck`, then a PR against its `main`.

---

## Verification

- Unit: `swift test --filter "RuleRecheckTest|ConfigTest|OnWindowDetectedTest|WindowExpectationTest|FormatTest|ListWindowsTest|ScrollCommandTest|AutoTilingTest"` covers parsing, the known-title override, the snapshot, detection seeding, `run-callback` on untracked windows, all three modes, non-title criteria, anti-bounce, shadowing and `check-further-callbacks`, rules without `recheck`, macOS-native-state skipping, expect-window exemption, title events (dedupe, untracked, saved without refresh), reload reseed and generation, restored windows.
- Full: `./swift-test.sh`, `./lint.sh` (swiftformat, Task lint, swiftlint, periphery), `./build-debug.sh -Xswiftc -warnings-as-errors`.
- aero-helper: `swift test --package-path /Users/jedwards/code/aero/aero-helper/SharedCode --filter TOMLGeneratorTests`.
- Live (Task 12): TextEdit window floats after its title changes to match; window count unchanged after install.

---

## Executive Summary

**What exists today:**
- `on-window-detected` rules run exactly once per window, from `tryOnWindowDetected` → `onWindowDetected` (`Sources/AppBundle/tree/MacWindow.swift:273-303`), inside the heavy refresh that registers the window.
- AeroSpace never listens for title changes: per-window AX subscriptions (`AxWindow.new`, `MacApp.swift:573`) cover close, minimize, move and resize. A title rule that misses at detection never gets another chance, and the guide warns about it.
- Rule matchers read the title with an AX round trip per rule (`window.getTitle`), which can block up to 1 s on a busy app.
- aero-helper's `TOMLGenerator` writes only table-style `if`, `run`, `check-further-callbacks` and `no-focus`.

**What we're moving to:**
- A rule can say `recheck = 'until-matched' | 'every-match' | 'every-change'`; without it nothing changes.
- Each tracked window keeps a baseline of the state rules can test (`ruleSnapshot`, from `%{...}` values) plus which `recheck` rules matched and which `until-matched` rules are spent (`Window.ruleRecheck`).
- Rules run only in a check pass at the end of each heavy refresh, for windows whose state changed; title notifications check in memory and start a refresh (at most every 250 ms) only when a rule would fire. Checks use `Window.lastKnownTitle` through the `knownRuleTitle` task-local and never ask the app. The post-run state becomes the new baseline.
- aero-helper writes `recheck` and string `if`, so profiles keep both.

**Why:**
- Late-titled windows (browser popouts such as Bitwarden's, PWAs, Electron) can now be caught, and rules can route windows by any testable state over their whole life, chosen per rule.
- It reuses the existing rule matcher, runner, `%{...}` expansion and refresh cycle: one new file plus small hooks, costing a few in-memory comparisons per window per refresh.
