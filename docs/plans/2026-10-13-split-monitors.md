# Split Monitors Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Split a monitor into side-by-side columns that each act as their own monitor (own visible workspace,
focus-monitor, pins, back-and-forth), with a key to toggle the split. For James: the 5120x1440 C49RG9x as
1280 | 2560 | 1280 with the center column main.

**Architecture:** The split happens where the monitor list is built (`Sources/AppBundle/model/MonitorInfo.swift`):
`screenInfos` are the physical screens, `monitorInfos` replaces each screen matched by a `[split-monitors]` rule with
its columns (`SplitMonitorInfo`). Everything keyed by a monitor's top-left corner (visible workspaces, history,
focus-monitor, pins) then works per column. The few places that really mean the physical screen (coordinate flips,
hiding windows, gaps at the screen's edges, macOS Spaces, UI panels) use `screenInfos` / `mainScreenInfo` /
`MonitorInfo.screen`.

**Tech Stack:** Swift 6.2 (strict concurrency), XCTest, AsciiDoc docs, Python 3 (keep-windows).

**Worktree:** `EnterWorktree` with name `split-monitors` (branch: `feature/split-monitors`)

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

---

## Context

AeroSpace shows exactly one workspace per monitor, so James's 5120x1440 ultrawide (main display at the origin, Dock on
the right, built-in display directly below its middle) shows one workspace at a time. He wants several side by side.
Upstream has nothing for it (nikitabobko/AeroSpace#465 "Partition display into multiple workspace containers", open
since 2024-08, no maintainer reply) and no surveyed fork implements it.

Decisions made with James:
- **Shape:** `1:2:1` columns (1280 | 2560 | 1280), configurable per screen.
- **Columns are monitors** in every respect, like separate physical monitors today: a workspace shows on its own
  (last) column, pins (`workspace-to-monitor-force-assignment`) target one column, by name (`'C49RG9x 3'`) or role.
- **`main` is the center column** (`main = 2` in the rule): new workspaces open there, `--monitor main` acts on it.
- **Gaps belong to the physical screen:** per-monitor gap values (`{ monitor.main = 75 }`) name screens, so the 75px
  side-panel gap stays at the ultrawide's left edge; seams between columns get half the inner gap on each side.
- **Toggle:** `split-monitors on|off|toggle`, bound to a key. Off shows the focused column's workspace on the whole
  screen (else the main column's); on puts every column back.

Out of scope here (separate aero-helper plan, see Appendix): aero-helper's panels, overview and Claude-monitor logic,
which assume one AeroSpace monitor per NSScreen.

Reused, not rebuilt: `Rect.sliced(along:weights:)` (`Sources/AppBundle/model/Rect.swift`) cuts the columns;
`getStubWorkspace(for:)`, `setActiveWorkspace`, `rearrangeWorkspacesOnMonitors` (`Sources/AppBundle/tree/Workspace.swift`)
handle visible workspaces; `parseMonitorDescription`, `parseTable`, `parseInt`, `parseTomlArray`
(`Sources/AppBundle/config/`) parse the config; `EnableCmdArgs`/`EnableCommand` are the model for the toggle.

Test helpers you'll use (all exist): `setUpWorkspacesForTests()` (`Sources/AppBundleTests/testUtil.swift`),
`parseConfig(_:)` with `.errors`/`.strErrors`/`.config`, `parseCommand(_:).cmdOrDie.run(.defaultEnv, .emptyStdin)`
(returns `CmdResult` with `exitCode`, `stdout`, `stderr` as `[String]` lines), `testParseSingleCommandSucc`,
`TestWindow.new(id:parent:rect:)`, `workspace.layoutWorkspace()`, `window.getAxRect(.nonCancellable)`, `assertEquals`,
`assertTrue`, `assertFalse`, `assertNil`, `assertNotNil`. `Rect` is not `Equatable`: compare its fields.
The unit-test monitor is "Test Monitor", 1920x1080 at the origin, main.

Commands: one test class `swift test --filter AppBundleTests.<Class>`; everything `./test.sh` (debug build with
warnings as errors, all tests, lint, generate, uncommitted-files check). Format with `./format.sh`. Run them from the
worktree root.

---

### Task 1: Set Up Worktree

**Step 1: Validate You Are In A Worktree**
Validate work is being done in a worktree. If not use the `EnterWorktree` tool with `name: "split-monitors"` to create
an isolated worktree. Then name the branch: `git branch -m feature/split-monitors` (the remote has a `docs` branch, so
never use a `docs/...` branch name).

**Step 2: Verify clean baseline**
```bash
make check
```
Expected: `Build complete!`. If not, investigate before proceeding.

**Step 3: Save this plan into the repo**
Call `mcp__project-tools__write_plan` with `feature_name: "split-monitors"`, this plan as `content`, and the worktree
root as `project_dir` (it writes `docs/plans/<date>-split-monitors.md`).
```bash
git add docs/plans && git commit -m "docs(plans): split monitors plan"
```

---

### Task 2: Parse `[split-monitors]`

**Files:**
- Create: `Sources/AppBundle/config/parseSplitMonitors.swift`
- Modify: `Sources/AppBundle/config/Config.swift` (struct `Config`, after `workspaceToMonitorForceAssignment`)
- Modify: `Sources/AppBundle/config/parseConfig.swift` (`configParser`, after `"workspace-to-monitor-force-assignment"`)
- Test: `Sources/AppBundleTests/config/ConfigTest.swift`

**Step 1: Write the failing tests** (append to `ConfigTest`)

```swift
    func testParseSplitMonitors() {
        let result = parseConfig(
            """
            [split-monitors.C49RG9x]
                columns = [1, 2, 1]
                main = 2
            [split-monitors.dell]
                columns = [1, 1]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.splitMonitors.map(\.pattern.origin), ["C49RG9x", "dell"])
        assertEquals(result.config.splitMonitors.map(\.columns), [[1, 2, 1], [1, 1]])
        assertEquals(result.config.splitMonitors.map(\.main), [2, 1])
        assertEquals(defaultConfig.splitMonitors, [])
    }

    func testParseSplitMonitorsErrors() {
        let result = parseConfig(
            """
            [split-monitors.main]
                columns = [1, 1]
            [split-monitors.a]
                columns = [1]
            [split-monitors.b]
                columns = [1, 0]
            [split-monitors.c]
                columns = [1, 1]
                main = 3
            [split-monitors.d]
                main = 1
            [split-monitors.e]
                columns = [1, 1]
                foo = 1
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] split-monitors.main: Expected a monitor name pattern. 'main', 'secondary' and monitor numbers would split whichever monitor has that role",
            "[ERROR] split-monitors.a.columns: Expected at least two column widths",
            "[ERROR] split-monitors.b.columns[1]: Expected a positive width",
            "[ERROR] split-monitors.c.main: Expected a column number from 1 to 2",
            "[ERROR] split-monitors.d.columns: Expected at least two column widths",
            "[ERROR] split-monitors.e.foo: Unknown key",
        ])
        assertEquals(result.config.splitMonitors, [])
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.ConfigTest`
Expected: compile error, `value of type 'Config' has no member 'splitMonitors'`.

**Step 3: Implement**

`Sources/AppBundle/config/parseSplitMonitors.swift`:
```swift
import Common

/// `[split-monitors.<pattern>]`: the screens whose name matches `pattern` show as side-by-side columns,
/// each of them a monitor of its own
struct SplitMonitorRule: ConvenienceMutable, Equatable, Sendable {
    /// Case insensitive regex substring of the screen's name, like the monitor patterns of
    /// workspace-to-monitor-force-assignment
    var pattern: CaseInsensitiveRegex
    /// Relative widths, left to right
    var columns: [Int] = []
    /// 1-based. The screen's primary column: it's the main monitor when the screen is the main one, and the column
    /// the screen's workspace moves to when the split turns on
    var main: Int = 1
}

private let splitMonitorRuleParser: [String: any ParserProtocol<SplitMonitorRule>] = [
    "columns": Parser(\.columns, parseColumnWidths),
    "main": Parser(\.main, parseInt),
]

func parseSplitMonitors(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [SplitMonitorRule] {
    guard let table = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return []
    }
    var result: [SplitMonitorRule] = []
    for (key, rawRule) in table {
        let ruleBacktrace = backtrace + .key(key)
        let pattern: CaseInsensitiveRegex
        switch parseMonitorDescription(key) {
            case .success(.pattern(let regex)): pattern = regex
            case .success:
                // 'main' would split the laptop whenever the ultrawide is unplugged
                c.errors.append(.init(ruleBacktrace, "Expected a monitor name pattern. 'main', 'secondary' and monitor numbers would split whichever monitor has that role"))
                continue
            case .failure(let msg):
                c.errors.append(.init(ruleBacktrace, msg))
                continue
        }
        let errorsBefore = c.errors.count
        let rule = parseTable(rawRule, SplitMonitorRule(pattern: pattern), splitMonitorRuleParser, ruleBacktrace, &c)
        if c.errors.count > errorsBefore { continue }
        if rule.columns.count < 2 {
            c.errors.append(.init(ruleBacktrace + .key("columns"), "Expected at least two column widths"))
        } else if !(1 ... rule.columns.count).contains(rule.main) {
            c.errors.append(.init(ruleBacktrace + .key("main"), "Expected a column number from 1 to \(rule.columns.count)"))
        } else {
            result.append(rule)
        }
    }
    return result
}

private func parseColumnWidths(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[Int]> {
    parseTomlArray(raw, backtrace).flatMap { array in
        array.enumerated().mapAllOrFailure { index, value in
            parseInt(value, backtrace + .index(index))
                .filter(.init(backtrace + .index(index), "Expected a positive width")) { $0 > 0 }
        }
    }
}
```

`Config.swift`, after `var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]`:
```swift
    var splitMonitors: [SplitMonitorRule] = []
```

`parseConfig.swift`, after the `"workspace-to-monitor-force-assignment"` entry:
```swift
    "split-monitors": Parser(\.splitMonitors, parseSplitMonitors),
```

If `mapAllOrFailure` doesn't take the `enumerated()` tuple, map the indices instead:
`array.indices.mapAllOrFailure { index in parseInt(array[index], ...) ... }`. If an error string differs only in
backtrace formatting, fix the expectation, not the message.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.ConfigTest`
Expected: `Executed N tests, with 0 failures`.

**Step 5: Commit**
```bash
git add Sources/AppBundle/config Sources/AppBundleTests/config/ConfigTest.swift
git commit -m "feat(config): parse split-monitors"
```

---

### Task 3: Columns are the monitors

**Files:**
- Create: `Sources/AppBundle/model/SplitMonitorInfo.swift`
- Modify: `Sources/AppBundle/model/MonitorInfo.swift`
- Modify (physical screen, not a column): `Sources/AppBundle/model/Rect.swift:30,83`,
  `Sources/AppBundle/util/appBundleUtil.swift:102,106`, `Sources/AppBundle/ui/FocusedWindowBorder.swift:43`,
  `Sources/AppBundle/ui/SecureInputView.swift:26,39`, `Sources/AppBundle/ui/OverviewView.swift:26-37`,
  `Sources/AppBundle/ui/VolumeView.swift:20-21`, `Sources/AppBundle/tree/MacApp.swift:213`,
  `Sources/Common/util/commonUtil.swift:153` (comment)
- Create: `Sources/AppBundleTests/splitMonitorsTestUtil.swift`, `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing tests**

`Sources/AppBundleTests/splitMonitorsTestUtil.swift`:
```swift
@testable import AppBundle
import Common

@MainActor
func splitMonitorRule(_ pattern: String, columns: [Int] = [1, 2, 1], main: Int = 2) -> SplitMonitorRule {
    SplitMonitorRule(pattern: try! CaseInsensitiveRegex.new(pattern).get(), columns: columns, main: main)
}

/// The 1920x1080 test monitor as columns 480 | 960 | 480 with the middle one main, like James's 1280 | 2560 | 1280
@MainActor
func splitTestMonitor(columns: [Int] = [1, 2, 1], main: Int = 2) {
    config.splitMonitors = [splitMonitorRule("test monitor", columns: columns, main: main)]
    gcMonitors()
}

/// The test monitor's three columns, left to right
@MainActor
var testColumns: (left: MonitorInfo, center: MonitorInfo, right: MonitorInfo) {
    let columns = sortedMonitorInfos
    check(columns.count == 3, "\(columns.map(\.name))")
    return (columns[0], columns[1], columns[2])
}
```

`Sources/AppBundleTests/SplitMonitorsTest.swift`:
```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class SplitMonitorsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testColumnsOfAScreen() {
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen())
        assertEquals(columns.map(\.rect.topLeftX), [0, 1280, 3840])
        assertEquals(columns.map(\.rect.width), [1280, 2560, 1280])
        assertEquals(columns.map(\.rect.height), [1440, 1440, 1440])
        assertEquals(columns.map(\.name), ["C49RG9x 1", "C49RG9x 2", "C49RG9x 3"])
        assertEquals(columns.map(\.isMain), [false, true, false])
        assertEquals(columns.map(\.monitorAppKitNsScreenScreensId), [1, 1, 1])
        assertEquals(columns.map(\.screen.rect.width), [5120, 5120, 5120])
    }

    func testColumnsKeepTheScreensVisibleArea() {
        // The menu bar on top and the Dock on the right of the screen
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen())
        assertEquals(columns.map(\.visibleRect.minX), [0, 1280, 3840])
        assertEquals(columns.map(\.visibleRect.maxX), [1280, 3840, 5057])
        assertEquals(columns.map(\.visibleRect.minY), [30, 30, 30])
        assertEquals(columns.map(\.visibleRect.height), [1410, 1410, 1410])
    }

    func testOnlyTheMainScreenHasAMainColumn() {
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen(isMain: false))
        assertEquals(columns.map(\.isMain), [false, false, false])
        assertEquals(columns.map(\.isPrimaryColumn), [false, true, false])
    }

    func testMonitorsAreTheColumnsOfSplitScreens() {
        assertEquals(monitorInfos.map(\.name), ["Test Monitor"])
        splitTestMonitor()
        assertEquals(monitorInfos.map(\.name), ["Test Monitor 1", "Test Monitor 2", "Test Monitor 3"])
        assertEquals(mainMonitorInfo.name, "Test Monitor 2")
        assertEquals(screenInfos.map(\.name), ["Test Monitor"])
        assertEquals(mainScreenInfo.width, 1920) // coordinates still convert through the whole screen

        splitMonitorsEnabled = false
        assertEquals(monitorInfos.map(\.name), ["Test Monitor"])
        assertEquals(mainMonitorInfo.name, "Test Monitor")
    }
}

/// James's C49RG9x: menu bar on top, Dock on the right
private struct UltrawideScreen: MonitorInfo {
    var isMain = true
    let rect = Rect(topLeftX: 0, topLeftY: 0, width: 5120, height: 1440)
    let visibleRect = Rect(topLeftX: 0, topLeftY: 30, width: 5057, height: 1410)
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let monitorAppKitNsScreenScreensId = 1
    let name = "C49RG9x"
}
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: compile errors (`columnMonitors(of:)`, `screenInfos`, `mainScreenInfo`, `splitMonitorsEnabled` don't exist).

**Step 3: Implement**

`Sources/AppBundle/model/SplitMonitorInfo.swift`:
```swift
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
```

`Sources/AppBundle/model/MonitorInfo.swift`:
- In `protocol MonitorInfo`, after `var isMain: Bool { get }`, add:
```swift
    /// The physical screen the monitor is on: the whole screen for a column of a split screen (split-monitors),
    /// otherwise the monitor itself
    var screen: MonitorInfo { get }
```
  and after the protocol:
```swift
extension MonitorInfo {
    var screen: MonitorInfo { self }
}
```
- Replace everything from `var mainMonitorInfo: MonitorInfo {` to the end of the file with:
```swift
/// The physical main screen (at the origin, with the menu bar), never one of its columns. Coordinate conversions
/// use its height, so it must not depend on `monitorInfos`, whose rects are converted through it
var mainScreenInfo: MonitorInfo {
    if isUnitTest { return testMonitorInfo }
    let screens = NSScreen.screens
    // Fallback: If main screen can't be found (e.g., during display reconfiguration),
    // return screens.first or testMonitor to avoid crash
    let screen = screens.withIndex.singleOrNil(where: \.value.isMainScreen) ?? screens.first.map { (0, $0) }
    guard let screen else { return testMonitorInfo }
    return LazyMonitorInfo(monitorAppKitNsScreenScreensId: screen.index + 1, isMain: true, screen.value)
}

/// The physical screens, unsplit
var screenInfos: [MonitorInfo] {
    isUnitTest
        ? [testMonitorInfo]
        : NSScreen.screens.enumerated().map { $0.element.toMonitorInfo(monitorAppKitNsScreenScreensId: $0.offset + 1) }
}

/// The monitors workspaces show on: the screens, each split screen as its columns (split-monitors)
@MainActor var monitorInfos: [MonitorInfo] { splitScreens(screenInfos) }

/// The main screen, or its primary column when it's split
@MainActor var mainMonitorInfo: MonitorInfo {
    let monitors = monitorInfos
    return monitors.first(where: \.isMain) ?? monitors.first ?? mainScreenInfo
}

@MainActor var sortedMonitorInfos: [MonitorInfo] {
    monitorInfos.sortedBy([\.rect.minX, \.rect.minY])
}

var sortedScreenInfos: [MonitorInfo] {
    screenInfos.sortedBy([\.rect.minX, \.rect.minY])
}
```
- `Sources/AppBundle/model/Rect.swift:30` and `:83`: `mainMonitorInfo.height` → `mainScreenInfo.height`
  (rename the local at :30 to `mainScreenHeight`).
- `Sources/AppBundle/util/appBundleUtil.swift:106` (`withYAxisFlipped`): `mainMonitorInfo.height` → `mainScreenInfo.height`.
  At `:102` mark `monitorApproximation` `@MainActor` (it reads `monitorInfos`).
- `Sources/AppBundle/ui/FocusedWindowBorder.swift:43`, `SecureInputView.swift:26,39`, `OverviewView.swift:26,30,36,37`,
  `VolumeView.swift:20,21`: `mainMonitorInfo` → `mainScreenInfo` (they position Cocoa panels on the physical screen).
- `Sources/AppBundle/tree/MacApp.swift:213`: `monitorInfos.count == 1` → `screenInfos.count == 1` (macOS Spaces are
  per physical display, issue #101).
- `Sources/Common/util/commonUtil.swift:153`: comment `mainMonitorInfo` / `monitorInfos` → `mainScreenInfo` / `screenInfos`.
- Everything else that calls `mainMonitorInfo` keeps it on purpose (the main column hosts workspaces):
  `Workspace.swift:114`, `MacWindow.swift:50`, `focus.swift:56`, `appBundleUtil.swift:33`,
  `MonitorDescriptionEx.swift`, `WorkspaceBackAndForthCommand.swift:28`.
- `Sources/AppBundle/model/MonitorEx.swift:21`: mark `monitorId_oneBased` `@MainActor` (it reads `sortedMonitorInfos`).
- `Sources/AppBundleTests/testUtil.swift`, in `setUpWorkspacesForTests()` right after `config = defaultConfig`:
  `splitMonitorsEnabled = true` (a test may turn the split off).
- Build: `swift build`. Where the compiler says another caller of `monitorInfos` / `mainMonitorInfo` /
  `sortedMonitorInfos` / `monitorApproximation` isn't on the main actor, mark that function `@MainActor` (they all run
  on it already).

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `Executed 4 tests, with 0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(monitors): split screens into column monitors"
```

---

### Task 4: Each column shows its own workspace

`gcMonitors()` only rearranges when the monitor *count* changes: re-splitting `[1, 2, 1]` → `[1, 1, 2]` would keep
stale column corners. Compare the corners instead; re-sync after a config reload and in test setup.

**Files:**
- Modify: `Sources/AppBundle/tree/Workspace.swift:137-142` (`gcMonitors`), and new `activeWorkspaceOrNil` next to `activeWorkspace`
- Modify: `Sources/AppBundle/command/impl/ReloadConfigCommand.swift:54` (after `config = parseResult.config`)
- Modify: `Sources/AppBundleTests/testUtil.swift` (`setUpWorkspacesForTests`)
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing tests** (append to `SplitMonitorsTest`)

```swift
    func testEachColumnShowsItsOwnWorkspace() {
        splitTestMonitor()
        let (left, center, right) = testColumns
        assertTrue(Workspace.get(byName: "a").focusWorkspace()) // A new workspace opens on the main monitor
        assertEquals(center.activeWorkspace.name, "a")
        assertTrue(left.setActiveWorkspace(Workspace.get(byName: "b")))
        assertTrue(right.setActiveWorkspace(Workspace.get(byName: "c")))
        assertEquals(sortedMonitorInfos.map(\.activeWorkspace.name), ["b", "a", "c"])
        assertEquals(Workspace.get(byName: "b").workspaceMonitor.name, "Test Monitor 1")
    }

    func testFocusMonitorMovesBetweenColumns() async {
        splitTestMonitor()
        let (left, _, right) = testColumns
        assertTrue(left.setActiveWorkspace(Workspace.get(byName: "b")))
        assertTrue(right.setActiveWorkspace(Workspace.get(byName: "c")))
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        assertEquals(await runCommand("focus-monitor right").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "c")
        assertEquals(await runCommand("focus-monitor left").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "a")
    }

    func testPinToAColumn() {
        splitTestMonitor()
        config.workspaceToMonitorForceAssignment["pinned"] = [.pattern("test monitor 3")!, .main]
        assertTrue(Workspace.get(byName: "pinned").focusWorkspace())
        assertEquals(focus.workspace.workspaceMonitor.name, "Test Monitor 3")
        assertFalse(testColumns.center.setActiveWorkspace(Workspace.get(byName: "pinned")))
    }

    func testSplittingDifferentlyRearranges() {
        splitTestMonitor()
        _ = monitorInfos.map(\.activeWorkspace) // Every column shows a workspace
        config.splitMonitors = [splitMonitorRule("test monitor", columns: [1, 1, 2], main: 1)]
        gcMonitors() // Same count, other corners
        assertEquals(sortedMonitorInfos.map(\.rect.topLeftX), [0, 480, 960])
        // Without the rearrange, the new column at 960 has no workspace and one is still visible at the old 1440
        assertEquals(sortedMonitorInfos.map { $0.activeWorkspaceOrNil != nil }, [true, true, true])
        assertEquals(Workspace.all.filter(\.isVisible).count, 3)
    }

    private func runCommand(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: compile error, `activeWorkspaceOrNil` doesn't exist. After adding it (first part of Step 3),
`testSplittingDifferentlyRearranges` fails: `[true, true, false]`. The other three may already pass: they pin
behaviour the next tasks must keep.

**Step 3: Implement**

`Workspace.swift`, inside `extension MonitorInfo` (next to `activeWorkspace`):
```swift
    /// The visible workspace, or nil: unlike `activeWorkspace`, never rearranges the monitors
    @MainActor
    var activeWorkspaceOrNil: Workspace? { screenPointToVisibleWorkspace[rect.topLeftCorner] }
```

`Workspace.swift`, replace `gcMonitors()`:
```swift
@MainActor
func gcMonitors() {
    // Not only the count: splitting a monitor differently (split-monitors) moves columns, the count can stay
    if Set(screenPointToVisibleWorkspace.keys) != Set(monitorInfos.map(\.rect.topLeftCorner)) {
        rearrangeWorkspacesOnMonitors()
    }
}
```

`ReloadConfigCommand.swift`, right after `config = parseResult.config`:
```swift
        gcMonitors() // A changed [split-monitors] changes the monitors (Task 9 replaces this line)
```

`testUtil.swift`, in `setUpWorkspacesForTests()` right after the Task 3 line `splitMonitorsEnabled = true`:
```swift
    gcMonitors() // Drop the columns a previous test split the test monitor into
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `Executed 8 tests, with 0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(monitors): rearrange workspaces when the columns change"
```

---

### Task 5: Gaps belong to the screen

Per-monitor gap values name screens (`main` = the main display), so the 75px side-panel gap stays at the ultrawide's
left edge, which is the left column's. A seam between columns gets half the inner gap on each side, like two windows.
`MonitorDescription.resolveMonitor` stops reading the global `mainMonitorInfo` so it can resolve against either list.

**Files:**
- Modify: `Sources/AppBundle/model/MonitorDescriptionEx.swift`
- Modify: `Sources/AppBundle/config/DynamicConfigValue.swift:16-30`
- Modify: `Sources/AppBundle/model/MonitorEx.swift:4-19` (`visibleRectPaddedByOuterGaps`)
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing tests** (append to `SplitMonitorsTest`)

```swift
    func testSeamsGetHalfTheInnerGap() {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 75, bottom: 5, top: 5, right: 5))
        splitTestMonitor()
        let (left, center, right) = testColumns
        assertEquals(left.visibleRectPaddedByOuterGaps().minX, 75)
        assertEquals(left.visibleRectPaddedByOuterGaps().maxX, 475)
        assertEquals(center.visibleRectPaddedByOuterGaps().minX, 485)
        assertEquals(center.visibleRectPaddedByOuterGaps().maxX, 1435)
        assertEquals(right.visibleRectPaddedByOuterGaps().minX, 1445)
        assertEquals(right.visibleRectPaddedByOuterGaps().maxX, 1915)
        assertEquals(center.visibleRectPaddedByOuterGaps().minY, 5)
        assertEquals(center.visibleRectPaddedByOuterGaps().maxY, 1075)
    }

    func testPerMonitorGapsNameTheScreen() {
        // `main` is the main screen, whose left edge is the left column's, not the main column (the center one)
        let leftGap: DynamicConfigValue<Int> = .perMonitor([PerMonitorValue(description: .main, value: 75)], default: 5)
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: leftGap, bottom: .constant(5), top: .constant(5), right: .constant(5)))
        splitTestMonitor()
        let (left, center, _) = testColumns
        assertEquals(left.visibleRectPaddedByOuterGaps().minX, 75)
        assertEquals(center.visibleRectPaddedByOuterGaps().minX, 485)
    }

    func testMainAndSecondaryResolveInTheGivenList() {
        splitTestMonitor()
        assertEquals(MonitorDescription.main.resolveMonitor(sortedMonitors: sortedMonitorInfos)?.name, "Test Monitor 2")
        assertEquals(MonitorDescription.main.resolveMonitor(sortedMonitors: sortedScreenInfos)?.name, "Test Monitor")
        assertNil(MonitorDescription.secondary.resolveMonitor(sortedMonitors: sortedMonitorInfos)) // Three monitors
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: the seam asserts fail (center minX is 485 only after the fix; today outer gaps apply on every column edge),
and `main` against `sortedScreenInfos` returns nil (today it returns the global main monitor, the center column).

**Step 3: Implement**

`MonitorDescriptionEx.swift`:
```swift
import Common

extension MonitorDescription {
    /// `sortedMonitors`: left to right, `monitorInfos` for pins and commands, `screenInfos` for gaps
    @MainActor func resolveMonitor(sortedMonitors: [MonitorInfo]) -> MonitorInfo? {
        switch self {
            case .sequenceNumber(let number): sortedMonitors.getOrNil(atIndex: number - 1)
            case .main: sortedMonitors.first(where: \.isMain)
            case .pattern(let regex): sortedMonitors.first { $0.name.contains(caseInsensitiveRegex: regex) }
            case .secondary: sortedMonitors.takeIf { $0.count == 2 }?.first { !$0.isMain }
        }
    }
}
```

`DynamicConfigValue.swift`, replace `getValue(for:)`:
```swift
    /// Per-monitor values are gaps, which belong to the physical screen: their `monitor` patterns, `main` and
    /// `secondary` name screens, and every column of a split screen (split-monitors) gets its screen's value
    @MainActor func getValue(for monitor: any MonitorInfo) -> Value {
        switch self {
            case .constant(let value): return value
            case .perMonitor(let array, let defaultValue):
                let screens = sortedScreenInfos
                let screen = monitor.screen.rect.topLeftCorner
                return array
                    .lazy
                    .compactMap { $0.description.resolveMonitor(sortedMonitors: screens)?.rect.topLeftCorner == screen ? $0.value : nil }
                    .first ?? defaultValue
        }
    }
```

`MonitorEx.swift`, replace `visibleRectPaddedByOuterGaps`:
```swift
    @MainActor
    func visibleRectPaddedByOuterGaps(forWorkspace workspaceName: String? = nil) -> Rect {
        let gapsConfig: Gaps = if let workspaceName, let wsGaps = config.workspaceGaps[workspaceName] {
            wsGaps
        } else {
            config.gaps
        }
        let gaps = ResolvedGaps(gaps: gapsConfig, monitor: self)
        // A seam between two columns of a split screen (split-monitors) looks like the gap between two windows
        let seam = gaps.inner.horizontal.toDouble() / 2
        let left = rect.minX > screen.rect.minX ? seam : gaps.outer.left.toDouble()
        let right = rect.maxX < screen.rect.maxX ? seam : gaps.outer.right.toDouble()
        let topLeft = visibleRect.topLeftCorner
        return Rect(
            topLeftX: topLeft.x + left,
            topLeftY: topLeft.y + gaps.outer.top.toDouble(),
            width: visibleRect.width - left - right,
            height: visibleRect.height - gaps.outer.top.toDouble() - gaps.outer.bottom.toDouble(),
        )
    }
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest` then `swift test --filter AppBundleTests.ConfigTest`
Expected: both `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(gaps): gaps belong to the screen, seams get half the inner gap"
```

---

### Task 6: Hidden windows park at the screen's corner

A column's own corner is inside the screen: a window parked at the left column's bottom-right corner shows along the
bottom of the next column, and its body lands on the laptop below. Park at the physical screen's corner, picked among
the physical screens.

**Files:**
- Modify: `Sources/AppBundle/tree/Window.swift:110-132` (`hideInCorner`)
- Modify: `Sources/AppBundle/tree/WorkspaceEx.swift` (new `hideCorner`)
- Modify: `Sources/AppBundle/layout/refresh.swift:243`, `Sources/AppBundle/layout/tabHeaders.swift:45-48`
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing tests** (append to `SplitMonitorsTest`)

```swift
    func testHiddenWindowsParkAtTheScreensCorner() async throws {
        splitTestMonitor()
        let workspace = Workspace.get(byName: "hidden")
        assertTrue(testColumns.left.setActiveWorkspace(workspace))
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200))
        try await window.hideInCorner(.bottomRightCorner)
        let hidden = try await window.getAxRect(.nonCancellable).orDie()
        // The screen's corner: the left column's (480, 1080) is inside the center column
        assertEquals(hidden.topLeftCorner, CGPoint(x: 1919, y: 1079))
    }

    func testHideCornerIsPickedForTheScreen() {
        splitTestMonitor()
        let workspace = Workspace.get(byName: "hidden")
        assertTrue(testColumns.left.setActiveWorkspace(workspace))
        // Scored as a monitor of its own, the left column would pick bottom-left, away from the center column
        assertEquals(workspace.hideCorner, .bottomRightCorner)
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `hideCorner` doesn't exist (compile error). After adding it in Step 3 first, the corner test fails with
`bottomLeftCorner` until the screen is scored.

**Step 3: Implement**

`WorkspaceEx.swift`, inside `extension Workspace`:
```swift
    /// Where windows of this workspace hide while it's invisible: a corner of the physical screen, never a column's
    /// (split-monitors), whose corners are inside the screen
    @MainActor var hideCorner: OptimalHideCorner {
        workspaceMonitor.screen.optimalHideCorner(monitors: screenInfos)
    }
```

`refresh.swift` (in `layoutWorkspaces`), replace
`let corner = workspace.workspaceMonitor.optimalHideCorner(monitors: monitors)` with `let corner = workspace.hideCorner`.

`tabHeaders.swift` `init(_ workspace:asTiles:)`, replace
`self.hideCorner = monitor.optimalHideCorner(monitors: monitors)` with `self.hideCorner = workspace.hideCorner`
(keep `monitors` for `hasMonitorInRightSpillBand`: a column with another to its right must not peek into it).

`Window.swift` `hideInCorner`, in both `case` branches: `nodeMonitor.visibleRect` → `nodeMonitor.screen.visibleRect`.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest` then `swift test --filter AppBundleTests.WindowVisibilityTest`
Expected: both `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(monitors): park hidden windows at the physical screen's corner"
```

---

### Task 7: A floating window in the wrong column centers in its own

Apps center dialogs on the physical screen. When that lands a dialog in a neighbouring column, `layoutFloatingWindow`
maps it proportionally from that column to its workspace's, which throws it to the far edge. Between columns of one
screen, center it horizontally in its workspace's column and keep its y (the columns share the y range).

**Files:**
- Modify: `Sources/AppBundle/layout/layoutRecursive.swift:79-95` (`layoutFloatingWindow`)
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing test** (append to `SplitMonitorsTest`)

```swift
    func testFloatingWindowInAnotherColumnCentersInItsOwn() async throws {
        splitTestMonitor()
        let (_, center, right) = testColumns
        let workspace = Workspace.get(byName: "a")
        assertTrue(center.setActiveWorkspace(workspace))
        assertTrue(right.setActiveWorkspace(Workspace.get(byName: "b")))
        // Most of this dialog fell in the right column
        let dialog = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 1300, topLeftY: 300, width: 400, height: 200))
        _ = try await workspace.layoutWorkspace()
        let rect = try await dialog.getAxRect(.nonCancellable).orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 760, y: 300)) // 480 + (960 - 400) / 2
    }
```

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: FAIL, actual `(480.0, 300.0)` (the proportional mapping, clamped to the column's left edge).

**Step 3: Implement**

In `layoutFloatingWindow`, replace the two lines
```swift
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height
```
with
```swift
            let workspaceMonitor = workspace.workspaceMonitor
            // Another column of the same screen (split-monitors): the app centered its window on the screen
            let isOtherColumn = currentMonitor.screen.rect.topLeftCorner == workspaceMonitor.screen.rect.topLeftCorner &&
                currentMonitor.rect.topLeftCorner != workspaceMonitor.rect.topLeftCorner
            var newX = isOtherColumn
                ? workspaceRect.topLeftX + (workspaceRect.width - windowRect.width) / 2
                : workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = isOtherColumn ? windowTopLeftCorner.y : workspaceRect.topLeftY + yProportion * workspaceRect.height
```

**Step 4: Run to see it pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(monitors): center a floating window that lands in another column"
```

---

### Task 8: A click on a window isn't a click on the desktop

On mouse-up, AeroSpace focuses the clicked monitor's workspace when the click is inside that monitor and it isn't the
focused one: that's how a click on another monitor's empty desktop focuses it. Windows reach into neighbouring
columns (floating windows across a seam, minimum widths, a native fullscreen window over the whole screen), so a click
on such a window would switch workspaces. Only treat it as a desktop click when no normal (layer 0) window is there.

**Files:**
- Modify: `Sources/AppBundle/cgWindowSnapshot.swift` (append)
- Modify: `Sources/AppBundle/GlobalObserver.swift:111` (the `case` condition)
- Test: `Sources/AppBundleTests/CgWindowSnapshotTest.swift`

**Step 1: Write the failing test** (append to `CgWindowSnapshotTest`)

```swift
    func testANormalWindowUnderTheMouseIsntTheDesktop() {
        func window(layer: Int, x: Int, y: Int, width: Int, height: Int) -> NSDictionary {
            [kCGWindowLayer as String: layer, kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height]] as NSDictionary
        }
        let dialog = window(layer: 0, x: 1300, y: 300, width: 400, height: 200)
        let panel = window(layer: 3, x: 0, y: 0, width: 1920, height: 1080) // above everything, e.g. a helper's overlay
        assertTrue(isNormalWindow(at: CGPoint(x: 1500, y: 400), [panel, dialog]))
        assertFalse(isNormalWindow(at: CGPoint(x: 1800, y: 900), [panel, dialog]))
        assertFalse(isNormalWindow(at: CGPoint(x: 1500, y: 400), []))
    }
```

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.CgWindowSnapshotTest`
Expected: compile error, `cannot find 'isNormalWindow' in scope`.

**Step 3: Implement**

Append to `cgWindowSnapshot.swift`:
```swift
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
        guard (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
              let b = window[kCGWindowBounds] as? NSDictionary,
              let x = (b["X"] as? NSNumber)?.doubleValue,
              let y = (b["Y"] as? NSNumber)?.doubleValue,
              let w = (b["Width"] as? NSNumber)?.doubleValue,
              let h = (b["Height"] as? NSNumber)?.doubleValue
        else { return false }
        return Rect(topLeftX: x, topLeftY: y, width: w, height: h).contains(point)
    }
}
```

`GlobalObserver.swift`, the desktop-click case becomes:
```swift
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.activeWorkspace != focus.workspace &&
                        !isNormalWindowUnderMouse(mouseLocation):
```

**Step 4: Run to see it pass**
Run: `swift test --filter AppBundleTests.CgWindowSnapshotTest`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "fix(mouse): a click on a window isn't a click on another monitor's desktop"
```

---

### Task 9: Workspaces land where you'd expect when a screen splits or merges

`rearrangeWorkspacesOnMonitors` maps old corners to the nearest new ones, so splitting puts the whole screen's
workspace in the left column and merging shows the left column's. `changeMonitorSplit` wraps any change of the split
(the toggle, a config reload) and then: on split, the screen's workspace goes back to the column it was in before the
last merge, else its pinned column, else the primary column, and the other columns get back what they showed;
on merge, the screen shows the focused workspace if it was on one of its columns, else the primary column's.

**Files:**
- Modify: `Sources/AppBundle/model/SplitMonitorInfo.swift` (append)
- Modify: `Sources/AppBundle/command/impl/ReloadConfigCommand.swift` (the Task 4 line)
- Modify: `Sources/AppBundleTests/testUtil.swift` (`setUpWorkspacesForTests`)
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing tests** (append to `SplitMonitorsTest`)

```swift
    func testMergeShowsTheFocusedColumnsWorkspace() {
        splitTestMonitor()
        let (left, center, right) = testColumns
        assertTrue(left.setActiveWorkspace(Workspace.get(byName: "l")))
        assertTrue(center.setActiveWorkspace(Workspace.get(byName: "c")))
        assertTrue(right.setActiveWorkspace(Workspace.get(byName: "r")))
        assertTrue(Workspace.get(byName: "r").focusWorkspace())
        changeMonitorSplit { splitMonitorsEnabled = false }
        assertEquals(monitorInfos.map(\.activeWorkspace.name), ["r"])
        assertEquals(focus.workspace.name, "r")

        changeMonitorSplit { splitMonitorsEnabled = true }
        assertEquals(sortedMonitorInfos.map(\.activeWorkspace.name), ["l", "c", "r"]) // Every column back
        assertEquals(focus.workspace.name, "r")
    }

    func testMergeShowsThePrimaryColumnWhenFocusIsElsewhere() {
        splitTestMonitor()
        let (left, center, _) = testColumns
        assertTrue(left.setActiveWorkspace(Workspace.get(byName: "l")))
        assertTrue(center.setActiveWorkspace(Workspace.get(byName: "c")))
        changeMonitorSplit { config.splitMonitors = [] } // A reload that drops the rule
        assertEquals(monitorInfos.map(\.activeWorkspace.name), ["c"])
    }

    func testSplitPutsTheScreensWorkspaceInThePrimaryColumn() {
        assertTrue(Workspace.get(byName: "w").focusWorkspace())
        changeMonitorSplit { config.splitMonitors = [splitMonitorRule("test monitor")] } // A reload that adds the rule
        let (left, center, right) = testColumns
        assertEquals(center.activeWorkspace.name, "w")
        assertEquals(focus.workspace.name, "w")
        assertTrue(left.activeWorkspace != right.activeWorkspace)
        assertTrue(left.activeWorkspace != center.activeWorkspace)
    }

    func testSplitPutsAPinnedWorkspaceInItsColumn() {
        config.workspaceToMonitorForceAssignment["pinned"] = [.pattern("test monitor 3")!, .main]
        assertTrue(Workspace.get(byName: "pinned").focusWorkspace()) // Unsplit, the pin falls back to main
        changeMonitorSplit { config.splitMonitors = [splitMonitorRule("test monitor")] }
        assertEquals(testColumns.right.activeWorkspace.name, "pinned")
        assertEquals(focus.workspace.name, "pinned")
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: compile error, `cannot find 'changeMonitorSplit' in scope`.

**Step 3: Implement**

Append to `SplitMonitorInfo.swift`:
```swift
/// What each column showed when its screen merged, by column corner, so splitting it again puts them back
@MainActor private var workspacesOfMergedColumns: [CGPoint: String] = [:]

@MainActor func resetSplitMonitorsForTests() {
    splitMonitorsEnabled = true
    workspacesOfMergedColumns = [:]
}

/// Runs `change`, which may split, merge or re-split screens (the toggle, a config reload), then puts the workspaces
/// where you'd expect them. A re-split (columns before and after) keeps rearrangeWorkspacesOnMonitors's nearest match
@MainActor func changeMonitorSplit(_ change: () -> Void) {
    let focused = focus.workspace
    let before = monitorInfos.map { (monitor: $0, workspace: $0.activeWorkspace) }
    change()
    gcMonitors()
    let after = monitorInfos
    for screen in screenInfos {
        let corner = screen.rect.topLeftCorner
        let was = before.filter { $0.monitor.screen.rect.topLeftCorner == corner }
        let now = after.filter { $0.screen.rect.topLeftCorner == corner }
        switch (was.count, now.count) {
            case (1, 2...): split(was[0].workspace, into: now.compactMap { $0 as? SplitMonitorInfo })
            case (2..., 1): merge(was, into: now[0], focused: focused)
            default: break
        }
    }
}

@MainActor private func split(_ workspace: Workspace, into columns: [SplitMonitorInfo]) {
    let pinned = workspace.forceAssignedMonitor?.rect.topLeftCorner
    let home = columns.first { workspacesOfMergedColumns[$0.rect.topLeftCorner] == workspace.name }
        ?? columns.first { $0.rect.topLeftCorner == pinned }
        ?? columns.first(where: \.isPrimaryColumn)
        ?? columns[0]
    _ = home.setActiveWorkspace(workspace)
    for column in columns where column.rect.topLeftCorner != home.rect.topLeftCorner {
        if let name = workspacesOfMergedColumns.removeValue(forKey: column.rect.topLeftCorner), name != workspace.name {
            let shown = Workspace.get(byName: name)
            if !shown.isVisible { _ = column.setActiveWorkspace(shown) }
        }
        if column.activeWorkspaceOrNil == nil {
            _ = column.setActiveWorkspace(getStubWorkspace(for: column))
        }
    }
    workspacesOfMergedColumns.removeValue(forKey: home.rect.topLeftCorner)
}

@MainActor private func merge(_ columns: [(monitor: MonitorInfo, workspace: Workspace)], into screen: MonitorInfo, focused: Workspace) {
    for (column, workspace) in columns {
        workspacesOfMergedColumns[column.rect.topLeftCorner] = workspace.name
    }
    let primary = columns.first { ($0.monitor as? SplitMonitorInfo)?.isPrimaryColumn == true }?.workspace
    if let shown = columns.first(where: { $0.workspace == focused })?.workspace ?? primary {
        _ = screen.setActiveWorkspace(shown)
    }
}
```

`ReloadConfigCommand.swift`: replace `config = parseResult.config` and the Task 4 `gcMonitors()` line after it with:
```swift
        changeMonitorSplit { config = parseResult.config }
```

`testUtil.swift`: replace the Task 3 line `splitMonitorsEnabled = true` with `resetSplitMonitorsForTests()`.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(monitors): keep workspaces in place when a screen splits or merges"
```

---

### Task 10: `split-monitors on|off|toggle`

**Files:**
- Create: `Sources/Common/cmdArgs/impl/SplitMonitorsCmdArgs.swift`
- Modify: `Sources/Common/cmdArgs/cmdArgsManifest.swift` (`CmdKind`: `case splitMonitors = "split-monitors"` after
  `case split`; parser: `case .splitMonitors: result[kind.rawValue] = SubCommandParser(parseSplitMonitorsCmdArgs)`
  after `.split`)
- Create: `Sources/AppBundle/command/impl/SplitMonitorsCommand.swift`
- Modify: `Sources/AppBundle/command/cmdManifest.swift` (`case .splitMonitors: command = SplitMonitorsCommand(args: self as! SplitMonitorsCmdArgs)` after `.split`)
- Create: `docs/aerospace-split-monitors.adoc`; Modify: `docs/commands.adoc` (entry after `== split`)
- Generated: `Sources/Common/cmdHelpGenerated.swift`, `Sources/Cli/subcommandDescriptionsGenerated.swift`
- Test: `Sources/AppBundleTests/command/SplitMonitorsCommandTest.swift`

**Step 1: Write the failing tests**

```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class SplitMonitorsCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("split-monitors toggle", SplitMonitorsCmdArgs(rawArgs: [], targetState: .toggle))
        testParseSingleCommandSucc("split-monitors off", SplitMonitorsCmdArgs(rawArgs: [], targetState: .off))
        testParseSingleCommandSucc("split-monitors on --fail-if-noop", SplitMonitorsCmdArgs(rawArgs: [], targetState: .on).copy(\.failIfNoop, true))
        assertNotNil(parseCommand("split-monitors").errorOrNil)
        assertNotNil(parseCommand("split-monitors toggle --fail-if-noop").errorOrNil)
    }

    func testToggle() async {
        splitTestMonitor()
        assertEquals(await runCommand("split-monitors toggle").exitCode.rawValue, 0)
        assertEquals(monitorInfos.count, 1)
        assertEquals(await runCommand("split-monitors toggle").exitCode.rawValue, 0)
        assertEquals(monitorInfos.count, 3)
    }

    func testNoop() async {
        let result = await runCommand("split-monitors on")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, ["Already split. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(await runCommand("split-monitors on --fail-if-noop").exitCode.rawValue, 2)
    }

    private func runCommand(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsCommandTest`
Expected: compile error, `cannot find 'SplitMonitorsCmdArgs' in scope`.

**Step 3: Implement**

`Sources/Common/cmdArgs/impl/SplitMonitorsCmdArgs.swift`:
```swift
public struct SplitMonitorsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .splitMonitors,
        help: split_monitors_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
        ],
        posArgs: [newMandatoryPosArgParser(\.targetState, parseState, placeholder: SplitMonitorsCmdArgs.State.unionLiteral)],
    )
    public var targetState: Lateinit<State> = .uninitialized
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], targetState: State) {
        self.commonState = .init(rawArgs.slice)
        self.targetState = .initialized(targetState)
    }

    public enum State: String, CaseIterable, Sendable {
        case on, off, toggle
    }
}

func parseSplitMonitorsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SplitMonitorsCmdArgs> {
    parseSpecificCmdArgs(SplitMonitorsCmdArgs(rawArgs: args), args)
        .filterNot("--fail-if-noop is incompatible with 'toggle' argument") { $0.targetState.val == .toggle && $0.failIfNoop }
}

private func parseState(i: PosArgParserInput) -> ParsedCliArgs<SplitMonitorsCmdArgs.State> {
    .init(parseEnum(i.arg, SplitMonitorsCmdArgs.State.self), advanceBy: 1)
}
```

`Sources/AppBundle/command/impl/SplitMonitorsCommand.swift`:
```swift
import AppKit
import Common

struct SplitMonitorsCommand: Command {
    let args: SplitMonitorsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !splitMonitorsEnabled
        }
        if newState == splitMonitorsEnabled {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already split. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not split. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        changeMonitorSplit { splitMonitorsEnabled = newState }
        return .succ
    }
}
```

`docs/aerospace-split-monitors.adoc`:
```asciidoc
= aerospace-split-monitors(1)
include::util/man-attributes.adoc[]
:manname: aerospace-split-monitors
// tag::purpose[]
:manpurpose: Turn the split of monitors into columns on or off
// end::purpose[]

// =========================================================== Synopsis
== Synopsis
[verse]
// tag::synopsis[]
aerospace split-monitors [-h|--help] toggle
aerospace split-monitors [-h|--help] on [--fail-if-noop]
aerospace split-monitors [-h|--help] off [--fail-if-noop]

// end::synopsis[]

// =========================================================== Description
== Description

// tag::body[]
{manpurpose}

`[split-monitors]` in the config splits a monitor into side-by-side columns, each of them a monitor of its own.
`split-monitors off` shows every split monitor whole again: it shows the focused column's workspace,
or the `main` column's when the focus is on another monitor.
`split-monitors on` splits them again and puts back what each column showed.

The split is on when AeroSpace starts. Reloading the config doesn't change it.

// =========================================================== Options
include::util/conditional-options-header.adoc[]

-h, --help:: Print help
--fail-if-noop:: Exit with non-zero exit code if already in the requested state

// end::body[]

// =========================================================== Footer
include::util/man-footer.adoc[]
```

`docs/commands.adoc`, after the `== split` entry:
```asciidoc
== split-monitors
----
include::aerospace-split-monitors.adoc[tags=synopsis]
----
include::aerospace-split-monitors.adoc[tags=purpose]
include::aerospace-split-monitors.adoc[tags=body]
```

Generate help (creates `split_monitors_help_generated` and the CLI's subcommand list): `./generate.sh --ignore-xcodeproj`

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsCommandTest`
Expected: `Executed 3 tests, with 0 failures`.

**Step 5: Commit**
```bash
git add Sources docs
git commit -m "feat(split-monitors): toggle the split with a command"
```

---

### Task 11: list-monitors and list-tree tell where a column is

aero-helper draws per monitor and joins on `monitor-appkit-nsscreen-screens-id` (columns keep their screen's), so it
needs each column's origin. Add `monitor-x` / `monitor-y` (top-left, global top-left-origin points).

**Files:**
- Modify: `Sources/Common/cmdArgs/impl/ListWindowsCmdArgs.swift:275-282` (`MonitorFormatVar`)
- Modify: `Sources/AppBundle/command/format.swift:230-237`
- Modify: `Sources/AppBundle/command/impl/ListTreeCommand.swift:27-30` (`monitorVars`)
- Modify: `Sources/AppBundleTests/command/ListTreeTest.swift:21-23`
- Modify (they pin the list of format variables in an error message): `Sources/AppBundleTests/command/EchoCommandTest.swift:45`,
  `Sources/AppBundleTests/command/TestCommandTest.swift:25,31` — insert `|monitor-x|monitor-y` right after `monitor-height`
- Modify: `docs/aerospace-list-monitors.adoc:60-63`
- Test: `Sources/AppBundleTests/command/ListMonitorsTest.swift`

**Step 1: Write the failing test** (append to `ListMonitorsTest`)

```swift
    @MainActor
    func testColumnsAreMonitors() async {
        setUpWorkspacesForTests()
        splitTestMonitor()
        let result = await parseCommand("list-monitors --format '%{monitor-id} %{monitor-name} %{monitor-x} %{monitor-y} %{monitor-width} %{monitor-is-main}'")
            .cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, [
            "1 Test Monitor 1 0 0 480 false",
            "2 Test Monitor 2 480 0 960 true",
            "3 Test Monitor 3 1440 0 480 false",
        ])
    }
```
and in `ListTreeTest`, the expected `monitorVars` set gains `"monitor-x", "monitor-y"`.

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.ListMonitorsTest`
Expected: FAIL, unknown `%{monitor-x}` interpolation variable.

**Step 3: Implement**

`MonitorFormatVar`, after `monitorHeight`:
```swift
        case monitorX = "monitor-x"
        case monitorY = "monitor-y"
```
`format.swift`, after the `.monitorHeight` case:
```swift
                    case .monitorX: .success(.int(Int(m.rect.topLeftX)))
                    case .monitorY: .success(.int(Int(m.rect.topLeftY)))
```
`ListTreeCommand.monitorVars`: append `.monitor(.monitorX), .monitor(.monitorY)`.
`docs/aerospace-list-monitors.adoc`, after the `%{monitor-is-main}` line:
```asciidoc
%{monitor-width}:: Number. Width of the monitor in points
%{monitor-height}:: Number. Height of the monitor in points
%{monitor-x}:: Number. X of the monitor's top-left corner, in points from the main monitor's top-left corner
%{monitor-y}:: Number. Y of the monitor's top-left corner, downwards
```
and after the `%{monitor-appkit-nsscreen-screens-id}` line's sentence, add: `The columns of a split monitor (split-monitors) share their screen's index.`

**Step 4: Run to see it pass**
Run: `swift test --filter 'AppBundleTests.(ListMonitorsTest|ListTreeTest|EchoCommandTest|TestCommandTest)'`
Expected: `0 failures` (Echo/Test fail until their variable lists gain `|monitor-x|monitor-y`).

**Step 5: Commit**
```bash
git add Sources docs
git commit -m "feat(list-monitors): monitor-x and monitor-y"
```

---

### Task 12: On quit, windows center on their screen

`AppServerTerminationHandler.beforeTermination` centers each window in its monitor's visible size but forgets the
monitor's origin (existing bug: every window ends up near the main screen's top-left), and with columns it would size
windows to a column. Center on the screen, origin included.

**Files:**
- Modify: `Sources/AppBundle/util/appBundleUtil.swift:28-40`
- Test: `Sources/AppBundleTests/SplitMonitorsTest.swift`

**Step 1: Write the failing test** (append to `SplitMonitorsTest`)

```swift
    func testQuitCentersOnTheScreen() {
        let laptop = Rect(topLeftX: 1764, topLeftY: 1440, width: 1800, height: 1169)
        assertEquals(terminationTopLeft(size: CGSize(width: 800, height: 600), screenVisibleRect: laptop), CGPoint(x: 2264, y: 1724.5))
    }
```

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: compile error, `cannot find 'terminationTopLeft' in scope`.

**Step 3: Implement**

In `appBundleUtil.swift`, add at file level:
```swift
/// Where a window goes when AeroSpace quits: centered on its screen
func terminationTopLeft(size: CGSize, screenVisibleRect r: Rect) -> CGPoint {
    CGPoint(x: r.topLeftX + (r.width - size.width) / 2, y: r.topLeftY + (r.height - size.height) / 2)
}
```
and in `beforeTermination` replace from `let monitorVisibleRect = monitor.visibleRect` through the `let point = CGPoint(...)`
statement with:
```swift
            let screenVisibleRect = monitor.screen.visibleRect
            let windowSize = window.lastFloatingSize ?? CGSize(width: screenVisibleRect.width, height: screenVisibleRect.height)
            let point = terminationTopLeft(size: windowSize, screenVisibleRect: screenVisibleRect)
```

**Step 4: Run to see it pass**
Run: `swift test --filter AppBundleTests.SplitMonitorsTest`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "fix(quit): center windows on their screen, origin included"
```

---

### Task 13: keep-windows keeps the split state

After a restart the split is on. A snapshot saved with it off has other monitor ids, so restore must turn it off
first. The split is on when two monitors share `monitor-appkit-nsscreen-screens-id`.

**Files:**
- Modify: `script/keep-windows.py` (`Tree.__init__`, `save`, `restore`)
- Modify: `script/keep-windows-test.py` (fake `list-tree`, fake `split-monitors`, new test)

**Step 1: Write the failing test**

In `keep-windows-test.py`:
- fake `list-tree`: each monitor dict gets
  `"monitor-appkit-nsscreen-screens-id": 1 if s.get("split") else m` (split: the fake's monitors are columns of one screen).
- fake commands, before the final `else`:
```python
    elif args[0] == "split-monitors":
        s["split"] = args[1] == "on"
```
- new test, added to `TESTS` as `("saved with the split off: restore turns it off first", test_split_state)`:
```python
def test_split_state(root):
    s = copy.deepcopy(BASE)  # no "split": off
    env = Env(root, s)
    env.run("save")
    r = restart(s)
    r["split"] = True  # split-monitors is on after a restart
    env.put(r)
    code, out = env.run("restore")
    log = env.log()
    problems = [] if log[:1] == ["aerospace split-monitors off"] else [f"didn't turn the split off first: {log}"]
    return problems + differences(env, s)[0] + exit_ok(code, out)
```

**Step 2: Run to see it fail**
Run: `./script/keep-windows-test.py`
Expected: `FAIL saved with the split off: restore turns it off first`; every other test `PASS`.

**Step 3: Implement**

`keep-windows.py`:
- `Tree.__init__`, after the monitors loop:
```python
        screens = [m["monitor-appkit-nsscreen-screens-id"] for m in raw["monitors"]]
        self.split = len(set(screens)) < len(screens)  # columns of one screen (split-monitors)
```
- `save()`, in `snapshot`: `"split": tree.split,`
- `restore()`, right after the `if tree is None:` block that follows `wait_for_windows`:
```python
    if "split" in snapshot and tree.split != snapshot["split"]:
        # The split is on after a restart: a snapshot saved with it off has other monitor ids
        change("split-monitors", "on" if snapshot["split"] else "off")
```

**Step 4: Run to see it pass**
Run: `./script/keep-windows-test.py`
Expected: every line `PASS`.

**Step 5: Commit**
```bash
git add script
git commit -m "feat(keep-windows): restore the split state before the workspaces"
```

---

### Task 14: Document it

**Files:**
- Modify: `docs/guide.adoc` (new section after `=== Assign workspaces to monitors`, which ends near line 905)
- Modify: `CLAUDE.md` (Key architecture)

**Step 1: Write the guide section**

```asciidoc
[#split-monitors]
=== Split a monitor into columns

An ultrawide monitor can show several workspaces side by side: `split-monitors` cuts it into columns,
and each column is a monitor of its own.
It shows its own workspace, `focus-monitor left|right` moves between columns,
and workspaces are assigned to columns like to any monitor.

[source,toml]
----
[split-monitors.C49RG9x]   # Case insensitive regex substring of the monitor's name
    columns = [1, 2, 1]    # Relative widths, left to right: 1280 | 2560 | 1280 on a 5120 wide monitor
    main = 2               # Optional, default 1. The column that is the main monitor
----

* Columns are named after their monitor and number, left to right: `C49RG9x 1`, `C49RG9x 2`, `C49RG9x 3`.
Assign workspaces to them by name, with a fallback for when the split is off:
`CC3 = ['C49RG9x 3', 'main']`
* `main` makes the column the main monitor when its monitor is the main one:
new workspaces open there, and `main` in `workspace-to-monitor-force-assignment` and `--monitor main` mean it.
* `secondary` needs exactly two monitors, and every column counts
* Gaps belong to the whole monitor: `monitor` patterns in `gaps` name monitors, not columns,
the outer gaps are at the monitor's edges, and two columns meet with half the inner gap on each side
* The key is a monitor name pattern. `main`, `secondary` and monitor numbers aren't allowed:
they'd split whichever monitor has that role (the laptop, with the ultrawide unplugged)
* xref:commands.adoc#split-monitors[split-monitors] turns the split off and on
```

**Step 2: CLAUDE.md**, add to Key architecture:
```markdown
- `split-monitors` (fork-only, `[split-monitors.<name pattern>]` + `split-monitors on|off|toggle`): columns of a screen
  are monitors (`SplitMonitorInfo`, `Sources/AppBundle/model/SplitMonitorInfo.swift`). `monitorInfos` = `screenInfos`
  split; `mainScreenInfo` / `screenInfos` / `MonitorInfo.screen` are the physical screen, for coordinate flips, hiding
  windows (`Workspace.hideCorner`), gaps (resolved per screen, seams = half the inner gap), macOS Spaces and UI panels.
  Splitting or merging goes through `changeMonitorSplit` (toggle and config reload). User doc: `docs/guide.adoc#split-monitors`.
```

**Step 3: Commit**
```bash
git add docs/guide.adoc CLAUDE.md
git commit -m "docs: split monitors"
```

---

### Task 15: Full check and PR

**Step 1:** `./format.sh` then `git diff --stat` (commit any formatting as `style: swiftformat`).
**Step 2:** `./test.sh`
Expected: ends with `✅ All tests have passed successfully` (it also fails on uncommitted generated files: commit them).
**Step 3:** `./script/keep-windows-test.py` — every line `PASS`.
**Step 4:** Push `feature/split-monitors` and open a PR against `MintCollector/AeroSpace` (not upstream), body ending with
the attribution from the session's system reminder.

---

### Task 16: Deploy and split James's ultrawide (ask James first)

Installing restarts AeroSpace and shuffles the screen for ~15s, and the live check opens/moves windows: **ask James and
wait for his go-ahead before Step 1 and before Step 4.** Do the config edits only after the new build is installed:
`auto-reload-config` would make the old build reject the unknown `split-monitors` key.

**Step 1:** After the PR is merged and the main checkout is updated (or from the worktree, if James prefers):
`make -C /Users/jedwards/code/aero/AeroSpace deploy`
**Step 2:** Prove the installed app has the feature: `aerospace split-monitors --help` prints the usage, and
`aerospace list-monitors --format '%{monitor-name} %{monitor-x}'` accepts `%{monitor-x}`.
**Step 3:** Add to `~/.config/aerospace/aerospace.toml` (after `[gaps.outer]`):
```toml
[split-monitors.C49RG9x]
columns = [1, 2, 1]
main = 2
```
and to `[mode.main.binding]`: `cmd-ctrl-alt-c = 'split-monitors toggle'`. Add the same two things to
`/Users/jedwards/code/aero/aero-helper/profiles.toml` — both files change together: the same `[split-monitors.C49RG9x]`
table in the shared settings (after the `[gaps]` table, before `[profiles.glove]`), and next to the other
`cmd-ctrl-alt-*` bindings:
```toml
[keybindings."cmd-ctrl-alt-c"]
all = 'split-monitors toggle'
```
Leave the `'main'` pins alone: they now mean the center column. Tell James how to pin to a side column
(`CC3 = ['C49RG9x 3', 'main']`). profiles.toml is in the aero-helper repo: leave the commit to him or the aero-helper session.
**Step 4 (James watching):** `aerospace list-monitors --format '%{monitor-id} %{monitor-name} %{monitor-x} %{monitor-width} %{monitor-is-main}'`
→ `C49RG9x 1/2/3` at x 0/1280/3840, widths 1280/2560/1280, `C49RG9x 2` main. Then with James: `cmd-ctrl-alt-c` merges
(focused workspace full width) and splits back (columns restored); `focus-monitor left/right` crosses columns; a
workspace switched to on a side column stays there; hidden windows don't peek at the column seams or on the laptop;
the 75px side-panel gap is at the screen's left edge only.

---

## Appendix: aero-helper follow-up (separate plan, in the aero-helper repo)

Found while planning; each assumes one AeroSpace monitor per NSScreen:
- `App/Models/MonitorModel.swift:24-29` `==` compares only `displayID`: columns compare equal, so
  `AeroStateStore.swift:125` drops updates. Compare all fields.
- `App/AeroSpace/AeroStateStore.swift:316-341` sets each monitor's frame to its NSScreen's and sorts by screen x:
  use `monitor-x/y/width/height` for the frame and sort by `monitor-x`.
- Overview (`App/Config/OverviewPanelController.swift:61-66,144`, `App/Views/OverviewView.swift:166-167,785,813-819`),
  Claude dashboard (`ClaudeDashboardPanelController.swift:50-55,74`), accordion strip
  (`AccordionStripPanelController.swift:138-150`), wallpaper crop (`WallpaperSnapshotService.swift`), toast: size and
  place from the column's rect, not `screen.frame` / `NSScreen.main`.
- `SharedCode/Sources/AeroSocket/ClaudeMonitor.swift:69-71` needs exactly two monitors: count screens, or decide what
  Claude-monitor mode means with columns.
- CLI floats (`CLI/ToggleFloatCommand.swift:42-45`, `WindowPositioning.swift`, `CenterWindowCommand.swift`): size and
  center on the focused workspace's column.
- Main-only logic (`CLI/WorkspaceRules.swift:42-51`, `WorkspaceCallbackCommand.swift`, `MainOverlay.swift:102-118`):
  decide main column vs the whole screen. `proj` (`~/jarvis/dev-environment/scripts/proj:188-191,263-271,457-476`)
  finds main by name and hops by monitor id.

---

## Executive Summary

**What exists today:**
- One workspace per monitor, and a monitor is an `NSScreen` (`monitorInfos` in `Sources/AppBundle/model/MonitorInfo.swift`).
  Visible workspaces, pins, history and focus-monitor are keyed by the monitor's top-left corner.
- On the 5120x1440 ultrawide that means one workspace across 5120 points; `max-window-width = 3840` only stops one
  window from getting too wide.

**What we're moving to:**
- `[split-monitors.<name>] columns = [1, 2, 1], main = 2` makes the ultrawide three monitors, `C49RG9x 1/2/3`, the
  center one main. Every monitor feature works per column because the columns are `MonitorInfo`s with their own corners.
- What really means the physical screen uses it: coordinate flips and UI panels (`mainScreenInfo`), hiding windows at
  the screen's corner, gaps per screen with half-inner-gap seams, macOS Spaces (`screenInfos.count`), quit placement.
- `split-monitors toggle` (bound to `cmd-ctrl-alt-c`) merges the screen showing the focused column's workspace and splits
  it back with every column restored; `list-monitors` gains `monitor-x/y`; keep-windows restores the split state.

**Why:**
- James can see several workspaces side by side on the ultrawide (e.g. two Claude sessions and a reference
  workspace) and still have the one-wide-workspace view a key away.
- Upstream's request (#465) is unanswered, and only an external-observer fork like this one has the monitor-keyed model
  and tests to do it cleanly. aero-helper's per-monitor panels follow in their own plan.

---

## Amendments (design stress-test, reported after approval)

Applied during implementation. Items 1–4 have tests in `SplitMonitorsTest`; each failed (or crashed, for 1) against
the plan's code. Items 5–7 have no test of their own: the unit tests can't start AeroSpace without a visible
workspace (5), the old detection gives the same answer for every real hide position (6), and 7 is a constant.

1. **No infinite recursion on a stale monitor (Task 4).** `layoutWorkspaces` captures `monitorInfos` and awaits
   between monitors, so a toggle can run in between. `activeWorkspace` on a column that no longer exists rearranged and
   then recursed forever. Now, after rearranging, it returns the workspace of the monitor that is now at that place.
2. **The focused workspace stays visible (Task 9).** `changeMonitorSplit` ends by showing the focused workspace on its
   monitor if the change hid it. A re-split like `[1,2,1]` → `[1,1]` maps the center column nowhere, and a pin can
   resolve elsewhere after a merge.
3. **Pins first (Task 9).** On split, a workspace pinned to one of the columns goes there before its remembered column.
   On merge, the primary column's workspace shows when the focused one may not show on the merged screen.
4. **The merged screen and its left column share the corner (0,0) (Task 9).** Without handling:
   - a workspace last shown on the merged screen would come back in the left column after the split. Now it comes back
     in the column it was in before the merge, else in the primary column.
   - while merged, back-and-forth would use the left column's history. Now the merged screen uses the history of the
     column it shows, and on split each column gets its own history back. The column of the merged screen's workspace
     continues the merged screen's history. The toggle itself isn't recorded as a workspace change.
5. **Startup stays as before (Task 9).** The config loads before the first workspace shows, so while no workspace is
   visible, `changeMonitorSplit` only runs `change()`.
6. **Hide-corner detection (Task 6).** `saveFloatingPositionIfNeeded` checks the screen's visible rect, where Task 6
   parks hidden windows.
7. **Closed-windows cache (Task 10).** `SplitMonitorsCommand.shouldResetClosedWindowsCache = true`, because the cache
   remembers monitors by corner.

Noted, not changed:
- Vertical `focus-monitor` sorts candidates by x (upstream), so with the laptop under the center column, `up` from the
  right column picks the laptop. Three physical monitors would behave the same way.
- Monitor ids follow x: the laptop's id comes between the center and right columns.
- aero-helper gets no event when the split toggles (that belongs in the aero-helper plan).
- `recheck` rules that test the monitor name or id re-check after a toggle.
