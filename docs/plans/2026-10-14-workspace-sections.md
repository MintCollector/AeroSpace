# Workspace Sections Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Cut each workspace into named side-by-side sections (e.g. left | main | right) that switch together with the
workspace. Rules and commands put windows in a section of the workspace they're on, or of a given workspace
(`1-A` left). An empty section either gives its width away or keeps its slot, per section. Split-monitors (PR #32) is
rolled back: sections replace it.

**Architecture:** Sections are containers in the workspace's own tree, not monitors. The root of a workspace with
sections is a row (h_tiles) whose children are section containers (`TilingContainer.section = "left"`), in config
order, each holding windows. A section exists only while it holds windows, like any container. Layout cuts the row by
the sections' widths and leaves a slot for an absent section that doesn't collapse. A new normalization,
`Workspace.normalizeSections()`, keeps the row in shape after every command and refresh: whatever lands in the root
goes to a section, and flattening never removes a section or its row. Commands that move windows know about sections
where it matters to the user (`move`, `move-node-to-workspace`, insertion of new windows, `layout --root`, flatten).

**Tech Stack:** Swift 6.2 (strict concurrency), XCTest, AsciiDoc docs, Python 3 (keep-windows).

**Worktree:** `EnterWorktree` with name `workspace-sections` (branch: `feature/workspace-sections`)

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

---

## Context

James asked for "subworkspaces". Workspace 1 should have left and right sections that come with it. Rules should put a
window in "Left" or "Right" of whatever workspace it opens on, or of a specific workspace ("1-Left", "2-Right").

Split-monitors (merged as PR #32, deployed, never configured) made columns of a screen into monitors. Each column then
switched workspaces on its own, which isn't what he wants. He chose to roll it back and build sections instead.

**This is AeroSpace's own model.** Whatever switches with a workspace lives in that workspace's tree, and side-by-side
regions are already containers in an h_tiles root. The maintainer's own proposal, upstream
[#260](https://github.com/nikitabobko/AeroSpace/issues/260), is the same mechanism: a declared layout per workspace
with placeholders, where unfilled placeholders collapse. Sections are that, with named slots that rules fill.

What exists and is reused:
- **Tree primitives:** `TreeNode.bind`/`unbindFromParent` (`Sources/AppBundle/tree/TreeNode.swift`) and the
  `TilingContainer` initializer (it binds). `deepMoveIn` (`MoveCommand.swift`) moves a window into a container.
- **Slicing:** `Rect.sliced(along:weights:)` (`Sources/AppBundle/model/Rect.swift`).
- **Layout frames:** `TilingContainer.ChildFrame` and the frame functions `tileFrames`/`accordionFrames`
  (`Sources/AppBundle/layout/layoutRecursive.swift`), which `previewLayout.swift` shares.
- **Insertion:** `prepareTilingWindowInsertion` (`Sources/AppBundle/tree/prepareTilingWindowInsertion.swift`) is where
  new windows go. So do windows that tile again, return from minimized/hidden/native fullscreen, or are orphans of a
  closed-windows cache restore.
- **Moving between workspaces:** `moveWindowToWorkspace` (`MoveNodeToWorkspaceCommand.swift`) serves
  `move-node-to-workspace`, `move-node-to-monitor` and `move --boundaries all-monitors-outer-frame`.
- **Config parsing:** `parseTable`, `Parser`, `parseString`, `parseInt`, `parseBool`, `parseTomlArray` and
  `parseArrayOfStrings` (`Sources/AppBundle/config/parseConfig.swift`).

Research findings the design rests on:
- **Default normalizations break the shape.** Flatten would remove a one-window section and replace a one-section
  root. Opposite-orientation would force every section vertical. (`changeOrientation` flips ancestors too, so
  `layout h_tiles` in a section turns the row vertical. `normalizeSections` puts the row back on every pass.)
- **Tests turn both normalizations off** (`testUtil.swift`). Section tests turn them back on.
- **Weights are points**, normalized additively (`tileFrames`). `[1, 2, 1]` as weights would lay out as near thirds,
  so the row is cut by `Rect.sliced`, not by weights.
- **Code assumes containers are never empty.** `MoveCommand.swift:214` dies on one. So a section exists only while it
  holds windows, and the layout reserves slots for absent sections.
- **`list-tree` is flat** (monitor → workspace → windows). aero-helper and keep-windows parse it, so a new
  `%{window-section}` key is additive and safe.
- **aero-helper's `toggle-accordion`** (cmd-ctrl-alt-backslash) runs `flatten-workspace-tree`, `layout --root` and
  `balance-sizes` on every workspace. It reads `%{workspace-root-container-layout}` to choose tiles or accordion. All
  four must keep working with sections.

## Decisions

Made with James:
- Sections are containers in each workspace's tree (option B, the AeroSpace way), and split-monitors is reverted.
- `collapse` is optional, per section.

Defaults chosen in planning; James can change any at approval:
1. **Where windows go.**
   - A new window goes to the `default` section unless a rule moves it.
   - A window keeps its section when it moves to another workspace or monitor (`move-node-to-workspace`, `alt-1…5`,
     `proj hop`), unless `--section` says otherwise.
   - It also goes back to its section when it tiles again after floating, minimized, a hidden app or native
     fullscreen (`Window.lastSection`).
2. **Collapse** defaults to `true`: an empty section gives its width to the others.
3. **Section widths come from the config.** `resize` doesn't resize sections, and a mouse resize at a section's edge
   snaps back.
4. **`move left/right`** crosses into the next section and starts it if it has no windows. At the outer edge, the
   section is the workspace's edge (the boundaries flags behave as at a workspace's edge, inside the section).
5. **`join-with`** doesn't join windows of different sections (it fails with a message).
6. **`layout --root`, `flatten-workspace-tree`, `balance-sizes`** act on every section; `layout --root` keeps each
   section's orientation. `%{workspace-root-container-layout}` is the default section's layout. Together these keep
   `toggle-accordion` working.
7. **`workspaces = [...]`** is optional and limits which workspaces have sections; without it, every workspace does.
8. **Not combined** with `enable-normalization-binary-tree`, `enable-auto-tiling` or `default-root-container-layout =
   'scrolling'` (config error, sections off). `workspace --view-toggle` refuses workspaces with sections.
9. **Kept from the split-monitors PR:** two fixes for bugs that exist without the split. `activeWorkspace` recursed
   forever on a monitor that was unplugged while a command awaited. On quit, windows were centered without their
   monitor's origin.

Config James will get (deploy task):
```toml
[workspace-sections]
    default = 'main'
    sections = [
        { name = 'left', width = 1 },
        { name = 'main', width = 2, collapse = false },
        { name = 'right', width = 1 }
    ]

[[on-window-detected]]
    if.app-id = 'com.tinyspeck.slackmacgap'
    run = 'move-node-to-section left'                    # left of whatever workspace it opened on

[[on-window-detected]]
    if.app-id = 'com.spotify.client'
    run = 'move-node-to-workspace 2-S --section right'   # 2-S's right (name first: aero-helper parses it)
```

Test helpers you'll use (all exist):
- **Setup and fixtures:**
  - `setUpWorkspacesForTests()` (`Sources/AppBundleTests/testUtil.swift`) sets `config = defaultConfig`, with flatten
    and opposite-orientation normalizations off and a horizontal default orientation.
  - `TestWindow.new(id:parent:)` always appends.
  - `Workspace.get(byName:)`, `workspace.floatingWindowsContainer`, `window.focusWindow()` (returns Bool), and `.apply { }`.
- **Assertions:** `assertEquals`, `assertTrue`, `assertNil`, `assertNotNil`.
- **Running commands:**
  - `parseCommand(_:).cmdOrDie.run(.defaultEnv, .emptyStdin)` returns `CmdResult`, with `exitCode.rawValue` 0 or 2 and
    `stdout`/`stderr` as `[String]`. It runs normalization afterwards.
  - `testParseSingleCommandSucc(_:_:)` checks how a command parses.
- **Tree and geometry:**
  - `workspace.rootTilingContainer.layoutDescription` (helper in `Sources/AppBundleTests/command/MoveCommandTest.swift`).
  - `workspace.previewLayoutRects()` returns `[UInt32: Rect]`.
  - `workspace.layoutWorkspace()` and `window.getAxRect(.nonCancellable)`.
- **The test monitor** is "Test Monitor", 1920x1080 at the origin, main.

Commands:
- One test class: `swift test --filter AppBundleTests.<Class>`.
- Everything: `./test.sh`, which runs a debug build with warnings as errors, all tests, lint, generate, and the
  uncommitted-files check.
- Format with `./format.sh`. Run all of these from the worktree root.

---

### Task 1: Set Up Worktree

**Step 1: Validate You Are In A Worktree**
Validate work is being done in a worktree. If not use the `EnterWorktree` tool with `name: "workspace-sections"` to
create an isolated worktree. Then name the branch: `git branch -m feature/workspace-sections` (the remote has a `docs`
branch, so never use a `docs/...` branch name).

**Step 2: Verify clean baseline**
```bash
make check
```
Expected: `Build complete!`. If not, investigate before proceeding.

**Step 3: Save this plan into the repo**
Call `mcp__project-tools__write_plan` with `feature_name: "workspace-sections"`, this plan as `content`, and the
worktree root as `project_dir` (it writes `docs/plans/<date>-workspace-sections.md`).
```bash
git add docs/plans && git commit -m "docs(plans): workspace sections plan"
```

---

### Task 2: Roll back split-monitors, keep its two upstream fixes

**Files:**
- Revert: merge commit `98a2fcfa` (PR #32). That removes `SplitMonitorInfo`, `parseSplitMonitors`, the
  `split-monitors` command, `%{monitor-x/y}`, its keep-windows state, its docs and plan doc, and the CLAUDE.md entry.
- Modify: `Sources/AppBundle/tree/Workspace.swift` (`MonitorInfo.activeWorkspace`)
- Modify: `Sources/AppBundle/util/appBundleUtil.swift` (`AppServerTerminationHandler.beforeTermination`)
- Create: `Sources/AppBundleTests/tree/ActiveWorkspaceTest.swift`, `Sources/AppBundleTests/TerminationTest.swift`

**Step 1: Revert**
```bash
git revert -m 1 98a2fcfa --no-edit
git diff --stat 98a2fcfa^1 HEAD -- Sources script docs CLAUDE.md
```
Expected: the diff lists only `docs/plans/<date>-workspace-sections.md` (Task 1): the rest is back to before PR #32.
If `git revert` conflicts (main moved on), resolve toward the pre-#32 code, keeping later changes.

Run: `make check` — expected `Build complete!`.

**Step 2: Write the failing tests**

`Sources/AppBundleTests/tree/ActiveWorkspaceTest.swift`:
```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class ActiveWorkspaceTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAMonitorThatIsGoneShowsTheWorkspaceInItsPlace() {
        // A command captured the monitor, then awaited while it was unplugged. This used to recurse forever
        assertEquals(GoneMonitor().activeWorkspace, mainMonitorInfo.activeWorkspace)
    }
}

/// A monitor right of the test monitor, which doesn't exist (any more)
private struct GoneMonitor: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Gone"
    let rect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let visibleRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let isMain = false
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}
```

`Sources/AppBundleTests/TerminationTest.swift`:
```swift
@testable import AppBundle
import XCTest

final class TerminationTest: XCTestCase {
    func testQuitCentersWindowsOnTheirMonitor() {
        // The laptop below the ultrawide: centering used to ignore the monitor's origin
        let laptop = Rect(topLeftX: 1764, topLeftY: 1440, width: 1800, height: 1169)
        assertEquals(terminationTopLeft(size: CGSize(width: 800, height: 600), visibleRect: laptop), CGPoint(x: 2264, y: 1724.5))
    }
}
```

**Step 3: Run to see them fail**
Run: `swift test --filter 'AppBundleTests.(ActiveWorkspaceTest|TerminationTest)'`
Expected: compile error, `cannot find 'terminationTopLeft' in scope`. With that line commented out, ActiveWorkspaceTest
crashes the test process (infinite recursion, signal 11).

**Step 4: Implement**

`Workspace.swift`, in `MonitorInfo.activeWorkspace`, replace
```swift
        // Normally, recursion should happen only once more because we must take the value from the cache
        // (Unless, monitor configuration data race happens)
        return self.activeWorkspace
```
with
```swift
        // Still missing: the monitor was captured before the monitors changed (it was unplugged while its caller
        // awaited). The workspace of the monitor that is in its place now
        return screenPointToVisibleWorkspace[rect.topLeftCorner] ?? rect.center.monitorApproximation.activeWorkspace
```

`appBundleUtil.swift`, add at file level, before `private struct AppServerTerminationHandler`:
```swift
/// Where a window goes when AeroSpace quits: centered on its monitor
func terminationTopLeft(size: CGSize, visibleRect r: Rect) -> CGPoint {
    CGPoint(x: r.topLeftX + (r.width - size.width) / 2, y: r.topLeftY + (r.height - size.height) / 2)
}
```
and in `beforeTermination` replace
```swift
            let point = CGPoint(
                x: (monitorVisibleRect.width - windowSize.width) / 2,
                y: (monitorVisibleRect.height - windowSize.height) / 2,
            )
```
with
```swift
            let point = terminationTopLeft(size: windowSize, visibleRect: monitorVisibleRect)
```

**Step 5: Run to see them pass**
Run: `swift test --filter 'AppBundleTests.(ActiveWorkspaceTest|TerminationTest)'`
Expected: `Executed 2 tests, with 0 failures`.

**Step 6: Commit**
```bash
git add Sources
git commit -m "fix(monitors): a monitor that is gone shows the workspace in its place

Kept from the reverted split-monitors (#32): activeWorkspace recursed forever on a monitor
captured before it was unplugged. Also center windows on their monitor on quit: the monitor's
origin was ignored."
```

---

### Task 3: Parse `[workspace-sections]`

**Files:**
- Create: `Sources/AppBundle/config/parseWorkspaceSections.swift`
- Modify: `Sources/AppBundle/config/Config.swift` (struct `Config`, next to `workspaceToMonitorForceAssignment`)
- Modify: `Sources/AppBundle/config/parseConfig.swift`:
  - `configParser`: add a `"workspace-sections"` entry next to `"workspace-to-monitor-force-assignment"`;
  - `parseArrayOfStrings`: drop `private`;
  - `parseConfig`: add the conflict check after the `split` + flatten check.
- Test: `Sources/AppBundleTests/config/ConfigTest.swift`

**Step 1: Write the failing tests** (append to `ConfigTest`)

```swift
    func testParseWorkspaceSections() {
        let result = parseConfig(
            """
            [workspace-sections]
                default = 'main'
                workspaces = ['1-A', '2-S']
                sections = [
                    { name = 'left', width = 1 },
                    { name = 'main', width = 2, collapse = false },
                    { name = 'right', width = 1 }
                ]
            """,
        )
        assertEquals(result.errors, [])
        let sections = result.config.workspaceSections
        assertEquals(sections?.sections.map(\.name), ["left", "main", "right"])
        assertEquals(sections?.sections.map(\.width), [1, 2, 1])
        assertEquals(sections?.sections.map(\.collapse), [true, false, true])
        assertEquals(sections?.defaultSection, "main")
        assertEquals(sections?.workspaces, ["1-A", "2-S"])
        assertNil(defaultConfig.workspaceSections)
    }

    func testParseWorkspaceSectionsAsArrayOfTables() {
        // How aero-helper writes it from profiles.toml
        let result = parseConfig(
            """
            [workspace-sections]
            default = 'main'
            [[workspace-sections.sections]]
            name = 'main'
            [[workspace-sections.sections]]
            name = 'right'
            collapse = false
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.workspaceSections?.sections.map(\.name), ["main", "right"])
        assertEquals(result.config.workspaceSections?.sections.map(\.collapse), [true, false])
        assertNil(result.config.workspaceSections?.workspaces)
    }

    func testParseWorkspaceSectionsErrors() {
        func errors(_ toml: String) -> [String] {
            let result = parseConfig(toml)
            assertNil(result.config.workspaceSections)
            return result.strErrors
        }
        assertEquals(errors("[workspace-sections]\ndefault = 'main'\nsections = [{ name = 'main' }]"),
                     ["[ERROR] workspace-sections.sections: Expected at least two sections"])
        assertEquals(errors("[workspace-sections]\ndefault = 'middle'\nsections = [{ name = 'left' }, { name = 'main' }]"),
                     ["[ERROR] workspace-sections.default: Expected the name of a section: left, main"])
        assertEquals(errors("[workspace-sections]\ndefault = 'main'\nsections = [{ name = 'left', width = 0 }, { name = 'main' }]"),
                     ["[ERROR] workspace-sections.sections[0].width: Expected a positive width"])
        assertEquals(errors("[workspace-sections]\ndefault = 'main'\nsections = [{ name = 'main' }, { name = 'main' }]"),
                     ["[ERROR] workspace-sections.sections: Expected each section to have its own name"])
        assertEquals(errors("[workspace-sections]\ndefault = 'main'\nsections = [{ name = 'left side' }, { name = 'main' }]"),
                     ["[ERROR] workspace-sections.sections[0].name: Expected a name without spaces"])
        assertEquals(errors("enable-normalization-binary-tree = true\n[workspace-sections]\ndefault = 'main'\nsections = [{ name = 'left' }, { name = 'main' }]"),
                     ["[ERROR] workspace-sections: Sections don't work with enable-normalization-binary-tree = true"])
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.ConfigTest`
Expected: compile error, `value of type 'Config' has no member 'workspaceSections'`.

**Step 3: Implement**

`Sources/AppBundle/config/parseWorkspaceSections.swift`:
```swift
import Common

/// `[workspace-sections]`: workspaces are rows of side-by-side sections, left to right. Sections are containers of the
/// workspace's tree, so they switch with the workspace
struct WorkspaceSections: ConvenienceMutable, Equatable, Sendable {
    /// Left to right
    var sections: [WorkspaceSection] = []
    /// Where new windows go
    var defaultSection: String = ""
    /// The workspaces that have sections. nil: every workspace
    var workspaces: [String]? = nil

    func applies(to workspace: String) -> Bool { workspaces?.contains(workspace) ?? true }
    func index(of section: String) -> Int? { sections.firstIndex { $0.name == section } }
    var totalWidth: Int { sections.reduce(0) { $0 + $1.width } }
}

struct WorkspaceSection: ConvenienceMutable, Equatable, Sendable {
    var name: String = ""
    /// Relative to the other sections' widths
    var width: Int = 1
    /// Without windows, the section gives its width to the others. Otherwise it keeps an empty slot
    var collapse: Bool = true
}

private let workspaceSectionsParser: [String: any ParserProtocol<WorkspaceSections>] = [
    "sections": Parser(\.sections, parseSectionList),
    "default": Parser(\.defaultSection, parseString),
    "workspaces": Parser(\.workspaces, parseWorkspaceNames),
]

private let sectionParser: [String: any ParserProtocol<WorkspaceSection>] = [
    "name": Parser(\.name, parseString),
    "width": Parser(\.width, parsePositiveWidth),
    "collapse": Parser(\.collapse, parseBool),
]

func parseWorkspaceSections(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WorkspaceSections? {
    let errorsBefore = c.errors.count
    let result = parseTable(raw, WorkspaceSections(), workspaceSectionsParser, backtrace, &c)
    if c.errors.count > errorsBefore { return nil }
    let names = result.sections.map(\.name)
    if names.count < 2 {
        c.errors.append(.init(backtrace + .key("sections"), "Expected at least two sections"))
    } else if let index = names.firstIndex(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
        // A section's name is a command argument: move-node-to-section <name>
        c.errors.append(.init(backtrace + .key("sections") + .index(index) + .key("name"), "Expected a name without spaces"))
    } else if Set(names).count != names.count {
        c.errors.append(.init(backtrace + .key("sections"), "Expected each section to have its own name"))
    } else if !names.contains(result.defaultSection) {
        c.errors.append(.init(backtrace + .key("default"), "Expected the name of a section: \(names.joined(separator: ", "))"))
    } else {
        return result
    }
    return nil
}

private func parseSectionList(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [WorkspaceSection] {
    guard let array = parseTomlArray(raw, backtrace).getOrNil(appendErrorTo: &c.errors) else { return [] }
    return array.enumerated().map { index, rawSection in
        parseTable(rawSection, WorkspaceSection(), sectionParser, backtrace + .index(index), &c)
    }
}

private func parsePositiveWidth(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).filter(.init(backtrace, "Expected a positive width")) { $0 > 0 }
}

private func parseWorkspaceNames(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String]?> {
    parseArrayOfStrings(raw, backtrace).map { Optional($0) }
}
```

`Config.swift`, after `var workspaceToMonitorForceAssignment: ...`:
```swift
    var workspaceSections: WorkspaceSections? = nil
```

`parseConfig.swift`, in `configParser` after the `"workspace-to-monitor-force-assignment"` entry:
```swift
    "workspace-sections": Parser(\.workspaceSections, parseWorkspaceSections),
```
`private func parseArrayOfStrings` → `func parseArrayOfStrings`.

In `parseConfig(_:)`, right after the `if config.enableNormalizationFlattenContainers { ... }` block:
```swift
    if config.workspaceSections != nil {
        // Each changes the root, which is the row of sections
        let conflicts = [
            config.enableNormalizationBinaryTree ? "enable-normalization-binary-tree = true" : nil,
            config.enableAutoTiling ? "enable-auto-tiling = true" : nil,
            config.defaultRootContainerLayout == .scrolling ? "default-root-container-layout = 'scrolling'" : nil,
        ].compactMap { $0 }
        if !conflicts.isEmpty {
            c.errors += [.init(.rootKey("workspace-sections"), "Sections don't work with \(conflicts.joined(separator: ", "))")]
            config.workspaceSections = nil
        }
    }
```
If an error string differs only in backtrace formatting, fix the expectation, not the message.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.ConfigTest`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(config): parse workspace-sections"
```

---

### Task 4: The section model

**Files:**
- Modify (stored properties):
  - `Sources/AppBundle/tree/TilingContainer.swift` (class body, after `layout`);
  - `Sources/AppBundle/tree/Window.swift` (class body);
  - `Sources/AppBundle/tree/Workspace.swift` (class body, next to `viewToggledStates`).
- Create: `Sources/AppBundle/tree/workspaceSections.swift`
- Create: `Sources/AppBundleTests/sectionsTestUtil.swift`
- Modify: `Sources/AppBundleTests/command/MoveCommandTest.swift` (`layoutDescription`, `enum LayoutDescription`)
- Create: `Sources/AppBundleTests/tree/WorkspaceSectionsTest.swift`

**Step 1: Write the failing tests**

`Sources/AppBundleTests/sectionsTestUtil.swift`:
```swift
@testable import AppBundle
import Common

/// James's sections: left | main | right as 1 | 2 | 1, new windows in main. With his normalizations, which tests
/// otherwise turn off
@MainActor
func setUpSections(collapse: [String: Bool] = [:], workspaces: [String]? = nil) {
    config.workspaceSections = WorkspaceSections(
        sections: [
            WorkspaceSection(name: "left", width: 1, collapse: collapse["left"] ?? true),
            WorkspaceSection(name: "main", width: 2, collapse: collapse["main"] ?? true),
            WorkspaceSection(name: "right", width: 1, collapse: collapse["right"] ?? true),
        ],
        defaultSection: "main",
        workspaces: workspaces,
    )
    config.enableNormalizationFlattenContainers = true
    config.enableNormalizationOppositeOrientationForNestedContainers = true
    config.gaps = Gaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
}
```

In `MoveCommandTest.swift`, replace `var layoutDescription` with:
```swift
    var layoutDescription: LayoutDescription {
        switch nodeCases {
            case .window(let window): return .window(window.windowId)
            case .workspace(let workspace): return .workspace(workspace.children.map(\.layoutDescription))
            case .floatingWindowsContainer(let container): return .floatingWindowsContainer(container.children.map(\.layoutDescription))
            case .macosMinimizedWindowsContainer: return .macosMinimized
            case .macosFullscreenWindowsContainer: return .macosFullscreen
            case .macosHiddenAppsWindowsContainer: return .macosHiddeAppWindow
            case .macosPopupWindowsContainer: return .macosPopupWindowsContainer
            case .tilingContainer(let container):
                let children = container.children.map(\.layoutDescription)
                let description: LayoutDescription = switch container.layout {
                    case .tiles: container.orientation == .h ? .h_tiles(children) : .v_tiles(children)
                    case .accordion: container.orientation == .h ? .h_accordion(children) : .v_accordion(children)
                    case .scrolling: .scrolling(children)
                    case .tabs: .tabs(children)
                }
                return container.section.map { .section($0, description) } ?? description
        }
    }
```
and add to `enum LayoutDescription`:
```swift
    /// A section of a workspace (workspace-sections) and its layout
    indirect case section(String, LayoutDescription)
```

`Sources/AppBundleTests/tree/WorkspaceSectionsTest.swift`:
```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceSectionsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOnlyTheListedWorkspacesHaveSections() {
        setUpSections(workspaces: ["a"])
        assertNotNil(Workspace.get(byName: "a").sections)
        assertNil(Workspace.get(byName: "b").sections)
        config.workspaceSections = nil
        assertNil(Workspace.get(byName: "a").sections)
    }

    func testASectionTakesItsPlaceInTheRow() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 3, parent: workspace.makeSection("right"))
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        let window = TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        assertEquals(workspace.sectionContainers.map(\.section), ["left", "main", "right"])
        assertEquals(window.sectionName, "main")
        assertEquals(workspace.sectionContainer(named: "right")?.children.count, 1)
    }

    func testWindowsGoToTheDefaultSectionUnlessTheirsExists() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        assertEquals(workspace.sectionForWindows(nil).section, "main")
        assertEquals(workspace.sectionForWindows("right").section, "right")
        assertEquals(workspace.sectionForWindows("gone").section, "main") // A section the config dropped
    }

    func testANewSectionIsOrientedByItsShareOfTheMonitor() {
        setUpSections()
        config.defaultRootContainerOrientation = .auto
        let workspace = Workspace.get(byName: "a")
        assertEquals(workspace.makeSection("main").orientation, .v) // 960 wide on the 1920x1080 test monitor
        config.workspaceSections?.sections[1].width = 3
        assertEquals(workspace.makeSection("main").orientation, .h) // 1152 wide
    }

    func testTheWorkspacesLayoutIsTheDefaultSections() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        assertTrue(workspace.rootLayoutContainer === workspace.rootTilingContainer) // No sections yet
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        assertEquals(workspace.rootLayoutContainer.section, "left")
        TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        assertEquals(workspace.rootLayoutContainer.section, "main")
    }
}
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest`
Expected: compile errors (`section`, `makeSection`, `sectionForWindows`, `rootLayoutContainer` don't exist).

**Step 3: Implement**

`TilingContainer.swift`, in the class body after `var layout: Layout`:
```swift
    /// workspace-sections: the name of the section this container is. Only children of a workspace's root are sections
    var section: String? = nil
```

`Window.swift`, in the class body:
```swift
    /// workspace-sections: the section the window was in when its workspace last normalized. It goes back there when it
    /// tiles again, and to the same section of another workspace
    var lastSection: String? = nil
```

`Workspace.swift`, in the class body after `var viewToggledStates`:
```swift
    /// workspace-sections: the layout `layout --root` gave the sections, for the sections to come.
    /// nil: default-root-container-layout
    var newSectionLayout: Layout? = nil
```

`Sources/AppBundle/tree/workspaceSections.swift`:
```swift
import AppKit
import Common

extension Workspace {
    /// The sections this workspace is a row of (workspace-sections), or nil
    @MainActor var sections: WorkspaceSections? { config.workspaceSections.flatMap { $0.applies(to: name) ? $0 : nil } }

    /// The sections that hold windows, left to right: the root's children
    @MainActor var sectionContainers: [TilingContainer] {
        rootTilingContainer.children.compactMap { ($0 as? TilingContainer)?.takeIf { $0.section != nil } }
    }

    @MainActor func sectionContainer(named name: String) -> TilingContainer? {
        sectionContainers.first { $0.section == name }
    }

    /// An empty container for section `name`, at its place in the row. The caller binds a window to it before
    /// normalization runs: normalization removes empty sections
    @MainActor func makeSection(_ name: String) -> TilingContainer {
        let sections = sections.orDie("\(self.name) has no sections")
        let index = sections.index(of: name).orDie("No section '\(name)'")
        let root = rootTilingContainer
        let position = root.children.firstIndex { child in
            ((child as? TilingContainer)?.section).flatMap(sections.index(of:)).map { $0 > index } ?? false
        } ?? root.children.count
        let container = TilingContainer(
            parent: root,
            adaptiveWeight: WEIGHT_AUTO,
            newSectionOrientation(sections.sections[index], sections),
            newSectionLayout ?? config.defaultRootContainerLayout,
            index: position,
        )
        container.section = name
        return container
    }

    /// The container of section `name`, made if it holds no windows yet. A name that isn't one of this workspace's
    /// sections, or nil, means the default section
    @MainActor func sectionForWindows(_ name: String?) -> TilingContainer {
        let sections = sections.orDie("\(self.name) has no sections")
        let name = name?.takeIf { sections.index(of: $0) != nil } ?? sections.defaultSection
        return sectionContainer(named: name) ?? makeSection(name)
    }

    /// The container whose layout stands for the workspace's: the root, or with sections the default section (else the
    /// first). `layout --root` and %{workspace-root-container-layout} go by it
    @MainActor var rootLayoutContainer: TilingContainer {
        guard let sections else { return rootTilingContainer }
        return sectionContainer(named: sections.defaultSection) ?? sectionContainers.first ?? rootTilingContainer
    }

    /// default-root-container-orientation, with 'auto' going by the section's share of the monitor
    @MainActor private func newSectionOrientation(_ section: WorkspaceSection, _ sections: WorkspaceSections) -> Orientation {
        let monitor = workspaceMonitor.visibleRect
        let width = monitor.width * CGFloat(section.width) / CGFloat(sections.totalWidth)
        return switch config.defaultRootContainerOrientation {
            case .horizontal: .h
            case .vertical: .v
            case .auto: width >= monitor.height ? .h : .v
        }
    }
}

extension TreeNode {
    /// The section this node is in, itself if it is one (workspace-sections)
    var containingSection: TilingContainer? {
        parentsWithSelf.lazy.compactMap { $0 as? TilingContainer }.first { $0.section != nil }
    }

    /// The name of the section this node is in (workspace-sections)
    var sectionName: String? { containingSection?.section }
}

extension TilingContainer {
    /// The workspace's sections when this is the root of a workspace that has them: the row of sections
    @MainActor var rowSections: WorkspaceSections? { (parent as? Workspace)?.sections }
}
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest` then `swift test --filter AppBundleTests.MoveCommandTest`
Expected: both `0 failures` (MoveCommandTest checks the `layoutDescription` refactor).

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): sections are containers of the workspace's row"
```

---

### Task 5: Normalization keeps the row of sections

Without this, the default normalizations destroy sections on the first refresh (see Context).

**Files:**
- Modify: `Sources/AppBundle/tree/workspaceSections.swift` (append `normalizeSections`)
- Modify: `Sources/AppBundle/tree/normalizeContainers.swift`
- Modify: `Sources/AppBundle/tree/TilingContainer.swift` (`normalizeOppositeOrientationForNestedContainers`)
- Test: `Sources/AppBundleTests/tree/WorkspaceSectionsTest.swift`

**Step 1: Write the failing tests** (append to `WorkspaceSectionsTest`)

```swift
    func testWindowsInTheRootGoToASection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer) // e.g. dragged onto the empty part of a monitor
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer).lastSection = "right"
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .h_tiles([.window(1)])),
            .section("right", .h_tiles([.window(2)])),
        ]))
    }

    func testASectionKeepsItsOnlyWindowAndTheRowItsOnlySection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("left", .h_tiles([.window(1)]))]))
    }

    func testAnEmptySectionGoes() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        _ = workspace.makeSection("left")
        TestWindow.new(id: 1, parent: workspace.makeSection("main"))
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("main", .h_tiles([.window(1)]))]))
    }

    func testASectionTakesOverItsOnlyContainer() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .v_tiles([.window(1), .window(2)])),
        ]))
    }

    func testSectionsKeepTheirOrientation() {
        // Opposite orientations would make every section of the side-by-side row vertical
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .h_tiles([.window(1), .window(2)])),
        ]))
    }

    func testSectionsFollowTheConfigOrderAndMerge() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        for (id, name) in [(3, "right"), (1, "left"), (2, "left")] as [(UInt32, String)] {
            // As the closed-windows cache or a view toggle could leave them
            TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
                $0.section = name
                TestWindow.new(id: id, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1), .window(2)])),
            .section("right", .h_tiles([.window(3)])),
        ]))
    }

    func testWithoutSectionsTheyAreOrdinaryContainers() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.makeSection("main").apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        config.workspaceSections = nil
        workspace.normalizeContainers()
        // main was side by side in the side-by-side row: its windows join the row instead of turning vertical
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    func testWindowsRememberTheirSection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.normalizeContainers()
        assertEquals(window.lastSection, "left")
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest`
Expected: the new tests fail. Windows stay in the root, sections get flattened or turn vertical, a dropped config
leaves vertical leftovers, and `lastSection` stays nil.

**Step 3: Implement**

Append to `workspaceSections.swift`:
```swift
extension Workspace {
    /// workspace-sections: the root is a row of sections in config order, and every tiled window is in one. A window or
    /// container that landed in the root goes to the section its window was last in, else to the default one.
    /// Without sections (any more), a section is an ordinary container
    @MainActor func normalizeSections() {
        let root = rootTilingContainer
        root.section = nil
        for child in root.children { (child as? TilingContainer)?.dropNestedSections() }
        guard let sections else {
            for section in sectionContainers { root.dissolve(section) }
            return
        }
        root.layout = .tiles
        root.setOrientation(.h)
        let mruWindow = root.mostRecentWindowRecursive
        var rebound = false
        for child in root.children {
            if let container = child as? TilingContainer, let name = container.section, sections.index(of: name) != nil {
                if let first = sectionContainer(named: name), first != container { // Two of one section: merge
                    for grandchild in container.children {
                        let binding = grandchild.unbindFromParent()
                        grandchild.bind(to: first, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
                    }
                    container.unbindFromParent()
                    rebound = true
                }
                continue
            }
            (child as? TilingContainer)?.section = nil // A section the config dropped
            child.bind(to: sectionForWindows(child.mostRecentWindowRecursive?.lastSection), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            rebound = true
        }
        let ordered = sectionContainers.sorted {
            (sections.index(of: $0.section ?? "") ?? 0) < (sections.index(of: $1.section ?? "") ?? 0)
        }
        if ordered != sectionContainers {
            for (index, section) in ordered.enumerated() {
                let binding = section.unbindFromParent()
                section.bind(to: root, adaptiveWeight: binding.adaptiveWeight, index: index)
            }
            rebound = true
        }
        if rebound {
            // A bind makes what it moved the most recent: the window that was keeps focus history's lead. Only then, or
            // the row would outrank floating windows on every refresh
            mruWindow?.markAsMostRecentChild()
        }
        for section in sectionContainers {
            for window in section.allLeafWindowsRecursive {
                window.lastSection = section.section
            }
        }
    }
}

extension TilingContainer {
    /// A section is only ever a child of the root: one nested deeper is an ordinary container
    fileprivate func dropNestedSections() {
        for case let child as TilingContainer in children {
            child.section = nil
            child.dropNestedSections()
        }
    }

    /// `section` (a child of this root) becomes an ordinary container. A side-by-side section would nest in the
    /// side-by-side row, so its windows join the row instead
    @MainActor fileprivate func dissolve(_ section: TilingContainer) {
        section.section = nil
        guard section.orientation == orientation, section.layout == layout, let index = section.ownIndex else { return }
        for (offset, child) in section.children.enumerated() {
            let binding = child.unbindFromParent()
            child.bind(to: self, adaptiveWeight: binding.adaptiveWeight, index: index + offset)
        }
        section.unbindFromParent()
    }
}
```

`normalizeContainers.swift`:
- `Workspace.normalizeContainers()`: add `normalizeSections()` as its first line.
- In `unbindEmptyAndAutoFlatten`, replace the first `if` condition and add an `else if` branch:
```swift
        // The scrolling root owns the viewport even when only one page remains. Sections and their row stay with one
        // child (workspace-sections)
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && !isScrollingRoot &&
            section == nil && rowSections == nil && (child is TilingContainer || !isRootContainer)
        {
            // ... unchanged body ...
        } else if section != nil, config.enableNormalizationFlattenContainers, let child = children.singleOrNil() as? TilingContainer {
            absorb(child)
            unbindEmptyAndAutoFlatten()
        } else {
            // ... unchanged body ...
        }
```
- Add, in the same `extension TilingContainer`:
```swift
    /// A section with a single container takes its children, layout and orientation instead: the section can't be
    /// replaced (workspace-sections)
    @MainActor private func absorb(_ child: TilingContainer) {
        let mru = parent?.mostRecentChild
        let childMru = child.mostRecentChild
        layout = child.layout
        setOrientation(child.orientation)
        for grandchild in child.children {
            let binding = grandchild.unbindFromParent()
            grandchild.bind(to: self, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
        }
        child.unbindFromParent()
        childMru?.markAsMostRecentChild()
        if mru != self {
            mru?.markAsMostRecentChild()
        }
    }
```

`TilingContainer.swift`, `normalizeOppositeOrientationForNestedContainers`, first line:
```swift
        // A section's orientation is its own: the row of sections is always side by side (workspace-sections)
        if section == nil && orientation == (parent as? TilingContainer)?.orientation {
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest` then `swift test --filter 'AppBundleTests.(TreeNodeTest|LayoutCommandTest|MoveCommandTest|AutoTilingTest)'`
Expected: all `0 failures`. Workspaces without sections behave as before.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): normalization keeps the row of sections"
```

---

### Task 6: Layout cuts the row by the sections' widths

**Files:**
- Modify: `Sources/AppBundle/layout/layoutRecursive.swift`:
  - the `.tilingContainer` case of `layoutRecursive`;
  - a new `sectionFrames` next to `tileFrames`.
- Modify: `Sources/AppBundle/layout/previewLayout.swift` (the `.tilingContainer` case of `preview`)
- Test: `Sources/AppBundleTests/tree/WorkspaceSectionsTest.swift`

**Step 1: Write the failing tests** (append to `WorkspaceSectionsTest`)

```swift
    func testSectionsCutTheRowByTheirWidths() {
        setUpSections()
        let rects = sectionedWorkspace(["left", "main", "right"]).previewLayoutRects()
        assertEquals(ids.map { rects[$0]?.topLeftX }, [0, 480, 1440])
        assertEquals(ids.map { rects[$0]?.width }, [480, 960, 480])
    }

    func testAnEmptySectionGivesItsWidthAway() {
        setUpSections()
        let rects = sectionedWorkspace(["main"]).previewLayoutRects()
        assertEquals(rects[2]?.topLeftX, 0)
        assertEquals(rects[2]?.width, 1920)
    }

    func testAnEmptySectionThatDoesntCollapseKeepsItsSlot() {
        setUpSections(collapse: ["right": false])
        let rects = sectionedWorkspace(["main"]).previewLayoutRects()
        assertEquals(rects[2]?.topLeftX, 0)
        assertEquals(rects[2]?.width, 1280) // main 2, right 1 of the 1920
    }

    func testSectionsAreApartByTheInnerGap() {
        setUpSections()
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
        let rects = sectionedWorkspace(["left", "main", "right"]).previewLayoutRects()
        assertEquals(ids.map { rects[$0]?.topLeftX }, [0, 485, 1445])
        assertEquals(ids.map { rects[$0]?.width }, [475, 950, 475])
    }

    func testLayoutPutsWindowsInTheirSections() async throws {
        setUpSections()
        let workspace = sectionedWorkspace(["main", "right"])
        _ = try await workspace.layoutWorkspace()
        let right = try await Window.get(byId: 3).orDie().getAxRect(.nonCancellable).orDie()
        assertEquals(right.topLeftX, 1280)
        assertEquals(right.width, 640)
    }

    /// Windows 1, 2, 3 in left, main, right
    private let ids: [UInt32] = [1, 2, 3]

    /// Workspace "a" with a window in each of `sections`: 1 in left, 2 in main, 3 in right
    private func sectionedWorkspace(_ sections: [String]) -> Workspace {
        let workspace = Workspace.get(byName: "a")
        for (id, name) in [(1, "left"), (2, "main"), (3, "right")] as [(UInt32, String)] where sections.contains(name) {
            TestWindow.new(id: id, parent: workspace.makeSection(name))
        }
        return workspace
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest`
Expected: all the new layout tests but `testAnEmptySectionGivesItsWidthAway` fail. The row is laid out as tiles, so
the slots are near-equal thirds and an empty section has no slot. A lone section already gets the whole row.

**Step 3: Implement**

`layoutRecursive.swift`, in `extension TilingContainer`, after `tileFrames`:
```swift
    /// Where each section of the row of sections goes (workspace-sections). The row is cut by the sections' widths. An
    /// empty section that collapses gives its width to the others, one that doesn't keeps an empty slot. Slots are apart
    /// by the inner gap, like tiles. The row's width is `virtual`'s. Pure
    @MainActor
    func sectionFrames(_ point: CGPoint, height: CGFloat, virtual: Rect, gaps: ResolvedGaps,
                       sections: WorkspaceSections) -> [ChildFrame]
    {
        var shown: [String: TilingContainer] = [:]
        for case let container as TilingContainer in children where !container.layoutChildren.isEmpty {
            if let name = container.section { shown[name] = container }
        }
        let slots = sections.sections.filter { shown[$0.name] != nil || !$0.collapse }
        let rawGap = gaps.inner.get(.h).toDouble()
        let rects = virtual.sliced(along: .h, weights: slots.map { CGFloat($0.width) })
        return slots.indices.compactMap { i in
            guard let container = shown[slots[i].name] else { return nil }
            let left = i == 0 ? 0 : rawGap / 2
            let right = i == slots.indices.last ? 0 : rawGap / 2
            let slot = rects[i]
            return ChildFrame(
                child: container,
                point: CGPoint(x: point.x + slot.topLeftX - virtual.topLeftX + left, y: point.y),
                width: slot.width - left - right,
                height: height,
                virtual: slot,
                weight: slot.width,
            )
        }
    }
```
In `layoutRecursive`, in `case .tilingContainer(let container):`, right after the two `lastApplied…` lines:
```swift
                if let sections = container.rowSections {
                    for f in container.sectionFrames(point, height: height, virtual: virtual,
                                                     gaps: context.resolvedGaps, sections: sections)
                    {
                        try await f.child.layoutRecursive(f.point, width: f.width, height: f.height, virtual: f.virtual, context)
                    }
                    return
                }
```
`previewLayout.swift`, in `case .tilingContainer(let container):`, replace the `let layout: Layout = …` and
`let frames: … = switch layout { … }` statements with:
```swift
                let frames: [TilingContainer.ChildFrame]
                if let sections = container.rowSections {
                    frames = container.sectionFrames(point, height: height, virtual: virtual,
                                                     gaps: context.resolvedGaps, sections: sections)
                } else {
                    let layout: Layout = if context.asTiles {
                        .tiles
                    } else if !TrayMenuModel.shared.isEnabled && (container.layout == .scrolling || container.layout == .tabs) {
                        .accordion // Same layout substitution as layoutRecursive's .tilingContainer case
                    } else {
                        container.layout
                    }
                    frames = switch layout {
                        case .tiles: container.tileFrames(point, width: width, height: height, virtual: virtual,
                                                          gaps: context.resolvedGaps, maxWindowWidth: context.maxWindowWidth)
                        case .accordion: container.accordionFrames(point, width: width, height: height, virtual: virtual)
                        case .scrolling, .tabs: container.children.map {
                                .init(child: $0, point: point, width: width, height: height, virtual: virtual, weight: 0)
                            }
                    }
                }
```
Section weights in the row are never set: the row ignores them.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest` then `swift test --filter 'AppBundleTests.(PreviewLayoutTest|LayoutCommandTest)'`
Expected: all `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): lay out the row by the sections' widths"
```

---

### Task 7: Where windows go

New windows go to the default section. A window keeps its section across workspaces and when it tiles again.
`move-node-to-workspace --section` picks one.

**Files:**
- Modify: `Sources/AppBundle/tree/prepareTilingWindowInsertion.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift` (`unbindAndGetBindingDataForNewTilingWindow`)
- Modify: `Sources/AppBundle/command/impl/MoveNodeToWorkspaceCommand.swift`
- Modify: `Sources/Common/cmdArgs/impl/MoveNodeToWorkspaceCmdArgs.swift`
- Create: `Sources/AppBundle/command/impl/MoveNodeToSectionCommand.swift` (the shared helpers here; the command in Task 8)
- Modify: `docs/aerospace-move-node-to-workspace.adoc`; generated help
- Test: `Sources/AppBundleTests/command/SectionsCommandsTest.swift`

**Step 1: Write the failing tests**

`Sources/AppBundleTests/command/SectionsCommandsTest.swift`:
```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class SectionsCommandsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testANewWindowGoesToTheDefaultSection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        assertTrue(TestWindow.new(id: 1, parent: workspace.makeSection("left")).focusWindow())
        let data = workspace.prepareTilingWindowInsertion(autoTile: false)
        assertEquals((data.parent as? TilingContainer)?.section, "main")
    }

    func testAWindowTilesAgainInItsSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("main"))
        assertTrue(TestWindow.new(id: 2, parent: workspace.makeSection("left")).focusWindow())
        workspace.normalizeContainers()
        assertEquals(await run("layout floating").exitCode.rawValue, 0)
        assertEquals(await run("layout tiling").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(2)])),
            .section("main", .h_tiles([.window(1)])),
        ]))
    }

    func testMoveNodeToWorkspaceKeepsTheSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("main"))
        assertTrue(TestWindow.new(id: 2, parent: workspace.makeSection("left")).focusWindow())
        assertEquals(await run("move-node-to-workspace b").exitCode.rawValue, 0)
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(2)])),
        ]))
    }

    func testMoveNodeToWorkspaceToASection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("main"))
        assertTrue(TestWindow.new(id: 2, parent: workspace.sectionForWindows("main")).focusWindow())
        assertEquals(await run("move-node-to-workspace b --section right").exitCode.rawValue, 0)
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.layoutDescription, .h_tiles([
            .section("right", .h_tiles([.window(2)])),
        ]))
        assertEquals(await run("move-node-to-workspace --window-id 1 a --section left").exitCode.rawValue, 0) // Same workspace
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("left", .h_tiles([.window(1)]))]))
    }

    func testMoveNodeToWorkspaceToAnUnknownSection() async {
        setUpSections(workspaces: ["a", "b"])
        assertTrue(TestWindow.new(id: 1, parent: Workspace.get(byName: "a").makeSection("main")).focusWindow())
        let result = await run("move-node-to-workspace b --section middle")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Workspace 'b' has no section 'middle'. Its sections: left, main, right"])
        assertEquals(await run("move-node-to-workspace c --section left").stderr,
                     ["Workspace 'c' has no sections (workspace-sections in the config)"])
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest`
Expected: the parse of `--section` fails (`Unknown flag '--section'`), and new windows go next to the focused window.

**Step 3: Implement**

`prepareTilingWindowInsertion.swift`, replace the signature and add the sections branch first:
```swift
    /// - Parameter section: workspace-sections: the section the window goes to (it was in it last); else the default one
    @MainActor
    func prepareTilingWindowInsertion(autoTile: Bool, section: String? = nil) -> BindingData {
        if sections != nil {
            // After that section's most recent window, as without sections after the workspace's
            let container = sectionForWindows(section)
            guard let window = container.mostRecentWindowRecursive, let parent = window.parent as? TilingContainer else {
                return BindingData(parent: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: window.ownIndex.orDie() + 1)
        }
        if autoTile, let split = prepareAutoTilingSplit() { return split }
        // ... the rest unchanged ...
```
(Auto tiling and sections exclude each other: Task 3's config check.)

`MacWindow.swift`, in `unbindAndGetBindingDataForNewTilingWindow`:
```swift
    return workspace.prepareTilingWindowInsertion(autoTile: window == nil || autoTile, section: window?.lastSection)
```

`MoveNodeToWorkspaceCmdArgs.swift`: add the flag and the field:
```swift
            "--section": singleValueSubArgParser(\.section, "<section>", { .success($0) }),
```
```swift
    public var section: String? = nil
```

`Sources/AppBundle/command/impl/MoveNodeToSectionCommand.swift`:
```swift
import Common

/// Why `name` isn't a section of `workspace`, or nil (workspace-sections)
@MainActor
func sectionError(_ name: String, _ workspace: Workspace) -> String? {
    guard let sections = workspace.sections else {
        return "Workspace '\(workspace.name)' has no sections (workspace-sections in the config)"
    }
    if sections.index(of: name) != nil { return nil }
    return "Workspace '\(workspace.name)' has no section '\(name)'. Its sections: \(sections.sections.map(\.name).joined(separator: ", "))"
}

/// workspace-sections: `window` goes to the end of section `name` of its workspace
@MainActor
func moveWindowToSection(_ window: Window, _ name: String, _ io: CmdIo, failIfNoop: Bool) -> BinaryExitCode {
    guard let workspace = window.nodeWorkspace else {
        return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace"))
    }
    if let error = sectionError(name, workspace) { return .fail(io.err(error)) }
    guard window.parent is TilingContainer else {
        return .fail(io.err("Window \(window.windowId) isn't tiled: only tiled windows are in sections"))
    }
    if window.sectionName == name {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' is already in section '\(name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    window.bind(to: workspace.sectionForWindows(name), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    return .succ
}
```

`MoveNodeToWorkspaceCommand.swift`:
- `run`, replace the final `return moveWindowToWorkspace(...)` with:
```swift
        if let section = args.section, let error = sectionError(section, targetWorkspace) {
            return .fail(io.err(error))
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow,
                                     failIfNoop: args.failIfNoop, section: args.section)
```
- `moveWindowToWorkspace`:
```swift
/// - Parameter section: workspace-sections: the section a tiled window goes to. Without it, the window keeps its section
@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool,
                           index: Int = INDEX_BIND_LAST, section: String? = nil) -> BinaryExitCode
{
    if window.nodeWorkspace == targetWorkspace {
        if let section, window.parent is TilingContainer {
            return moveWindowToSection(window, section, io, failIfNoop: failIfNoop)
        }
        // ... unchanged noop return ...
    }
    if window.isFloating {
        window.bind(to: targetWorkspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else if targetWorkspace.sections != nil {
        let container = targetWorkspace.sectionForWindows(section ?? window.sectionName ?? window.lastSection)
        window.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else if let split = targetWorkspace.prepareAutoTilingSplit() { // enable-auto-tiling
        // ... unchanged ...
```

`docs/aerospace-move-node-to-workspace.adoc`:
- In the second synopsis form, add `[--section <section>]` after `[--window-id <window-id>]`.
- Under Options, add:
```asciidoc
--section <section>::
Put the window in this section of the workspace (`[workspace-sections]` in the config).
Without it, a tiled window keeps its section, or goes to the default one.
A floating window moves to the workspace and stays floating
```
Then run `./generate.sh --ignore-xcodeproj`.

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest` then `swift test --filter 'AppBundleTests.(MoveNodeToWorkspaceCommandTest|MoveNodeToMonitorCommandTest|AutoTilingTest)'`
Expected: all `0 failures`.

**Step 5: Commit**
```bash
git add Sources docs
git commit -m "feat(sections): new windows go to the default section, windows keep theirs"
```

---

### Task 8: `move-node-to-section`

**Files:**
- Create: `Sources/Common/cmdArgs/impl/MoveNodeToSectionCmdArgs.swift`
- Modify: `Sources/Common/cmdArgs/cmdArgsManifest.swift`:
  - `CmdKind`: `case moveNodeToSection = "move-node-to-section"` after `moveNodeToMonitor`;
  - `initSubcommands()`: `case .moveNodeToSection: result[kind.rawValue] = SubCommandParser(parseMoveNodeToSectionCmdArgs)`.
- Modify: `Sources/AppBundle/command/cmdManifest.swift`:
  `case .moveNodeToSection: command = MoveNodeToSectionCommand(args: self as! MoveNodeToSectionCmdArgs)`.
- Modify: `Sources/AppBundle/command/impl/MoveNodeToSectionCommand.swift` (append the command)
- Create: `docs/aerospace-move-node-to-section.adoc`; Modify: `docs/commands.adoc` (entry after `== move-node-to-monitor`)
- Generated: `Sources/Common/cmdHelpGenerated.swift`, `Sources/Cli/subcommandDescriptionsGenerated.swift`
- Test: `Sources/AppBundleTests/command/MoveNodeToSectionCommandTest.swift`

**Step 1: Write the failing tests**

```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToSectionCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("move-node-to-section left", MoveNodeToSectionCmdArgs(rawArgs: [], section: "left"))
        // Lateinit's == holds for any two values: check the section itself
        assertEquals((parseCommand("move-node-to-section left").cmdOrNil?.singleCmdOrNil as? MoveNodeToSectionCommand)?.args.section.val, "left")
        assertNotNil(parseCommand("move-node-to-section").errorOrNil)
    }

    func testMoveToASection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TestWindow.new(id: 1, parent: $0)
            assertTrue(TestWindow.new(id: 2, parent: $0).focusWindow())
        }
        assertEquals(await run("move-node-to-section right").exitCode.rawValue, 0)
        assertEquals(await run("move-node-to-section --window-id 1 left").exitCode.rawValue, 0)
        // main has no windows left: it goes
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1)])),
            .section("right", .h_tiles([.window(2)])),
        ]))
    }

    func testAlreadyInTheSection() async {
        setUpSections()
        assertTrue(TestWindow.new(id: 1, parent: Workspace.get(byName: "a").makeSection("main")).focusWindow())
        let result = await run("move-node-to-section main")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, ["Window '1' is already in section 'main'. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(await run("move-node-to-section --fail-if-noop main").exitCode.rawValue, 2)
    }

    func testFailures() async {
        setUpSections(workspaces: ["a"])
        let a = Workspace.get(byName: "a")
        assertTrue(TestWindow.new(id: 1, parent: a.makeSection("main")).focusWindow())
        assertEquals(await run("move-node-to-section middle").stderr,
                     ["Workspace 'a' has no section 'middle'. Its sections: left, main, right"])
        TestWindow.new(id: 2, parent: a.floatingWindowsContainer)
        assertEquals(await run("move-node-to-section --window-id 2 left").stderr,
                     ["Window 2 isn't tiled: only tiled windows are in sections"])
        TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
        assertEquals(await run("move-node-to-section --window-id 3 left").stderr,
                     ["Workspace 'b' has no sections (workspace-sections in the config)"])
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.MoveNodeToSectionCommandTest`
Expected: compile error, `cannot find 'MoveNodeToSectionCmdArgs' in scope`.

**Step 3: Implement**

`Sources/Common/cmdArgs/impl/MoveNodeToSectionCmdArgs.swift`:
```swift
public struct MoveNodeToSectionCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveNodeToSection,
        help: move_node_to_section_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.section, parseSectionName, placeholder: "<section>")],
    )
    public var section: Lateinit<String> = .uninitialized
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], section: String) {
        self.commonState = .init(rawArgs.slice)
        self.section = .initialized(section)
    }
}

func parseMoveNodeToSectionCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveNodeToSectionCmdArgs> {
    parseSpecificCmdArgs(MoveNodeToSectionCmdArgs(rawArgs: args), args)
}

private func parseSectionName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(.success(i.arg), advanceBy: 1)
}
```

Append to `MoveNodeToSectionCommand.swift`:
```swift
struct MoveNodeToSectionCommand: Command {
    let args: MoveNodeToSectionCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        return moveWindowToSection(window, args.section.val, io, failIfNoop: args.failIfNoop)
    }
}
```

`docs/aerospace-move-node-to-section.adoc`:
```asciidoc
= aerospace-move-node-to-section(1)
include::util/man-attributes.adoc[]
:manname: aerospace-move-node-to-section
// tag::purpose[]
:manpurpose: Move the focused window to a section of its workspace
// end::purpose[]

// =========================================================== Synopsis
== Synopsis
[verse]
// tag::synopsis[]
aerospace move-node-to-section [-h|--help] [--fail-if-noop] [--window-id <window-id>] <section>

// end::synopsis[]

// =========================================================== Description
== Description

// tag::body[]
{manpurpose}

`[workspace-sections]` in the config makes workspaces rows of side-by-side sections.
The window goes to the end of the section.
A section without windows comes back when a window goes to it.
Only tiled windows are in sections.

To move a window to a section of another workspace: `move-node-to-workspace <workspace-name> --section <section>`

// =========================================================== Options
include::./util/conditional-options-header.adoc[]

-h, --help:: Print help
--fail-if-noop:: Exit with non-zero code if the window is already in the section

--window-id <window-id>::
include::./util/window-id-flag-desc.adoc[]

// =========================================================== Arguments
include::./util/conditional-arguments-header.adoc[]

<section>:: The name of a section in `[workspace-sections]`

// end::body[]

// =========================================================== Footer
include::util/man-footer.adoc[]
```

`docs/commands.adoc`, after the `== move-node-to-monitor` entry:
```asciidoc
== move-node-to-section
----
include::aerospace-move-node-to-section.adoc[tags=synopsis]
----
include::aerospace-move-node-to-section.adoc[tags=purpose]
include::aerospace-move-node-to-section.adoc[tags=body]
```

Generate help (creates `move_node_to_section_help_generated` and the CLI's subcommand list):
`./generate.sh --ignore-xcodeproj`

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.MoveNodeToSectionCommandTest`
Expected: `Executed 4 tests, with 0 failures`.

Shell completion (`grammar/commands-bnf-grammar.txt`) lists commands by hand and isn't tested. Leave it: the
grammar only builds in `make deploy` (`build-shell-completion.sh`), and a mistake there would break the deploy.

**Step 5: Commit**
```bash
git add Sources docs
git commit -m "feat(sections): move-node-to-section"
```

---

### Task 9: `move` goes across sections

Today `move left` out of a section binds the window into the row next to it. At a section's top or bottom, the default
`create-implicit-container` replaces the whole root.

**Files:**
- Modify: `Sources/AppBundle/command/impl/MoveCommand.swift`:
  - `moveOut` and a new `moveOutOfSection`;
  - `hitWorkspaceBoundaries`, `hitAllMonitorsOuterFrameBoundaries` and the two `createImplicitContainer…` functions:
    a `section:` parameter;
  - a new `createImplicitContainer(in:_:_:)`.
- Test: `Sources/AppBundleTests/command/SectionsCommandsTest.swift`

**Step 1: Write the failing tests** (append to `SectionsCommandsTest`)

```swift
    func testMoveRightGoesToTheNextSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TestWindow.new(id: 1, parent: $0)
            assertTrue(TestWindow.new(id: 2, parent: $0).focusWindow())
        }
        assertEquals(await run("move right").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .h_tiles([.window(1)])),
            .section("right", .h_tiles([.window(2)])), // Started by the move
        ]))
    }

    func testMoveLeftJoinsTheSectionsWindows() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        config.defaultRootContainerOrientation = .vertical
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        config.defaultRootContainerOrientation = .horizontal
        assertTrue(TestWindow.new(id: 2, parent: workspace.makeSection("main")).focusWindow())
        assertEquals(await run("move left").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .v_tiles([.window(1), .window(2)])),
        ]))
    }

    func testMoveLeftLandsNextToTheEdge() async {
        // A side-by-side section: the window lands at the end it crossed, not the far end (deepMoveIn's index 0)
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("left").apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        assertTrue(TestWindow.new(id: 3, parent: workspace.makeSection("main")).focusWindow())
        assertEquals(await run("move left").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1), .window(2), .window(3)])),
        ]))
    }

    func testMoveWithinASection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TestWindow.new(id: 1, parent: $0)
            assertTrue(TestWindow.new(id: 2, parent: $0).focusWindow())
        }
        assertEquals(await run("move left").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("main", .h_tiles([.window(2), .window(1)]))]))
    }

    func testMoveUpAtASectionsEdgeStaysInTheSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            assertTrue(TestWindow.new(id: 1, parent: $0).focusWindow())
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        assertEquals(await run("move up").exitCode.rawValue, 0)
        // As at the top of a workspace without sections, with the section as the edge: the row stays
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .v_tiles([.window(1), .h_tiles([.window(2), .window(3)])])),
        ]))
    }

    func testMoveLeftFromTheLeftmostSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        config.defaultRootContainerOrientation = .vertical
        workspace.makeSection("left").apply {
            assertTrue(TestWindow.new(id: 1, parent: $0).focusWindow())
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(await run("move --boundaries-action fail left").exitCode.rawValue, 2)
        assertEquals(await run("move left").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1), .window(2)])),
        ]))
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest`
Expected: the cross-section tests fail. The window lands in the row and normalization sweeps it to its last section,
and `move up` replaces the root.

**Step 3: Implement** (all in `MoveCommand.swift`)

`moveOut`: make the `first(where:)` closure stop at a section, and hand sections to `moveOutOfSection`:
```swift
    let innerMostTilingContainer = window.parents.first(where: {
        // workspace-sections: a window moves out of its section only to the next section
        if ($0 as? TilingContainer)?.section != nil { return true }
        return switch $0.parent?.cases {
            // ... the existing cases, unchanged ...
        }
    }) as? TilingContainer
    guard let innerMostTilingContainer else { return .fail(io.err(bugPrompt())) } // Impossible
    if innerMostTilingContainer.section != nil {
        return moveOutOfSection(window, innerMostTilingContainer, direction, io, args, env)
    }
    switch innerMostTilingContainer.tilingContainerParentCases {
    // ... unchanged ...
```
New function:
```swift
/// workspace-sections: across the row, the window goes to the next section, and starts it if it holds no windows. Past
/// the outer sections, and up or down, the section is the workspace's edge
@MainActor private func moveOutOfSection(
    _ window: Window,
    _ section: TilingContainer,
    _ direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    guard let workspace = section.nodeWorkspace, let sections = workspace.sections,
          let index = section.section.flatMap(sections.index(of:))
    else { return .fail(io.err(bugPrompt())) }
    let next = index + direction.focusOffset
    if direction.orientation == .h, sections.sections.indices.contains(next) {
        let name = sections.sections[next].name
        if let container = workspace.sectionContainer(named: name) {
            if container.orientation == direction.orientation {
                // Side by side: at the end the window crossed. deepMoveIn would put it at index 0, the far end of a
                // section to the left
                window.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: direction.isPositive ? 0 : INDEX_BIND_LAST)
                return .succ
            }
            return deepMoveIn(window: window, into: container, moveDirection: direction, io)
        }
        window.bind(to: workspace.makeSection(name), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        return .succ
    }
    return hitWorkspaceBoundaries(window, workspace, io, args, direction, env, section: section)
}
```
Add a last parameter `section: TilingContainer? = nil` to:
- `hitWorkspaceBoundaries` (pass it on in all three calls inside);
- `hitAllMonitorsOuterFrameBoundaries` (pass it on in both calls);
- `createImplicitContainerAndMoveWindow` and `createImplicitContainerAndMoveWindowOrFail`.

In `createImplicitContainerAndMoveWindow`, first lines:
```swift
    if let section {
        createImplicitContainer(in: section, window, direction)
        return true
    }
```
In `createImplicitContainerAndMoveWindowOrFail`:
- In the `!config.enableNormalizationFlattenContainers` branch, pass `section: section`.
- Then, before `let prevRoot = …`:
```swift
    if let section {
        let prevOrientation = section.orientation
        let prevChildren = section.children
        createImplicitContainer(in: section, window, direction)
        workspace.normalizeContainers()
        return section.orientation == prevOrientation && section.children == prevChildren ? .fail : .succ
    }
```
New function:
```swift
/// workspace-sections: the section is the workspace's edge. It gets the new level the root would get, in place: a
/// section is never replaced
@MainActor private func createImplicitContainer(in section: TilingContainer, _ window: Window, _ direction: CardinalDirection) {
    let content = TilingContainer(parent: section, adaptiveWeight: WEIGHT_AUTO, section.orientation, section.layout, index: 0)
    for child in section.children where child != content {
        let binding = child.unbindFromParent()
        child.bind(to: content, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
    }
    section.layout = .tiles // Like a new root
    section.setOrientation(direction.orientation)
    window.bind(to: section, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset)
}
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest` then `swift test --filter AppBundleTests.MoveCommandTest`
Expected: both `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): move goes across sections, a section is the workspace's edge"
```

---

### Task 10: The other tree commands

**Files:**
- Modify:
  - `Sources/AppBundle/command/impl/JoinWithCommand.swift`;
  - `Sources/AppBundle/command/impl/ResizeCommand.swift`;
  - `Sources/AppBundle/command/impl/FlattenWorkspaceTreeCommand.swift`;
  - `Sources/AppBundle/command/impl/LayoutCommand.swift`;
  - `Sources/AppBundle/command/impl/WorkspaceCommand.swift`, the view-toggle branch;
  - `Sources/AppBundle/command/format.swift`, `%{workspace-root-container-layout}` and `%{workspace-root-container-orientation}`;
  - `Sources/AppBundle/tree/workspaceSections.swift`, a new `sectionsLayout`.
- Test: `Sources/AppBundleTests/command/SectionsCommandsTest.swift`

**Step 1: Write the failing tests** (append to `SectionsCommandsTest`)

```swift
    func testJoinWithDoesntJoinSections() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        assertTrue(TestWindow.new(id: 2, parent: workspace.makeSection("main")).focusWindow())
        let before = workspace.rootTilingContainer.layoutDescription
        let result = await run("join-with left")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["join-with doesn't join windows of different sections. Use move or move-node-to-section"])
        assertEquals(workspace.rootTilingContainer.layoutDescription, before)
    }

    func testResizeDoesntResizeSections() async {
        setUpSections()
        config.defaultRootContainerOrientation = .vertical
        let workspace = Workspace.get(byName: "a")
        assertTrue(TestWindow.new(id: 1, parent: workspace.makeSection("left")).focusWindow())
        TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        workspace.normalizeContainers() // The row is side by side: without the fix, resize resizes the section
        let result = await run("resize width +100")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Can't resize a section: section widths come from workspace-sections in the config"])
    }

    func testFlattenKeepsTheSections() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 4, parent: workspace.makeSection("left"))
        workspace.makeSection("main").apply {
            assertTrue(TestWindow.new(id: 1, parent: $0).focusWindow())
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        assertEquals(await run("flatten-workspace-tree").exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(4)])),
            .section("main", .h_tiles([.window(1), .window(2), .window(3)])),
        ]))
    }

    func testLayoutRootSetsEverySection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        config.defaultRootContainerOrientation = .vertical
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        config.defaultRootContainerOrientation = .horizontal
        assertTrue(TestWindow.new(id: 2, parent: workspace.makeSection("main")).focusWindow())
        assertEquals(await run("layout --root tiles accordion").exitCode.rawValue, 0) // aero-helper's toggle-accordion
        TestWindow.new(id: 3, parent: workspace.sectionForWindows("right")) // A section to come
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .v_accordion([.window(1)])), // Each keeps its orientation
            .section("main", .h_accordion([.window(2)])),
            .section("right", .h_accordion([.window(3)])),
        ]))
        assertTrue(await workspaceLayouts().contains("a h_accordion")) // The default section's
        assertEquals(await run("layout --root vertical").stderr,
                     ["Each section keeps its orientation (workspace-sections). Run 'layout horizontal|vertical' on a window of the section"])
    }

    func testLayoutRootOnAWorkspaceWithoutWindows() async {
        // aero-helper's toggle-accordion reads the focused workspace's layout to pick tiles or accordion
        setUpSections()
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        assertEquals(await run("layout --root tiles accordion").exitCode.rawValue, 0)
        assertTrue(await workspaceLayouts().contains("a h_accordion"))
        assertEquals(await run("layout --root tiles accordion").exitCode.rawValue, 0)
        assertTrue(await workspaceLayouts().contains("a h_tiles"))
    }

    private func workspaceLayouts() async -> [String] {
        await run("list-workspaces --all --format '%{workspace} %{workspace-root-container-layout}'").stdout
    }

    func testViewToggleRefusesSections() async {
        setUpSections()
        assertTrue(TestWindow.new(id: 1, parent: Workspace.get(byName: "a").makeSection("main")).focusWindow())
        let result = await run("workspace --view-toggle b")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["workspace --view-toggle doesn't work with workspace-sections yet"])
    }
```

**Step 2: Run to see them fail**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest`
Expected: these six fail:
- join-with wraps the left section;
- resize changes the row's weights and exits 0;
- flatten-workspace-tree empties the sections;
- `layout --root` changes the row, which normalization then puts back;
- view-toggle merges.

**Step 3: Implement**

`JoinWithCommand.swift`, after `let joinWithTarget = …`:
```swift
        // workspace-sections: the next node over is another section
        if (joinWithTarget as? TilingContainer)?.section != nil {
            return .fail(io.err("join-with doesn't join windows of different sections. Use move or move-node-to-section"))
        }
```

`ResizeCommand.swift`:
- The candidates:
```swift
        let candidates = target.windowOrNil?.parentsWithSelf
            // workspace-sections: a section's width is the config's
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles && ($0 as? TilingContainer)?.section == nil }
            ?? []
```
- `guard let parent else {`, first line inside:
```swift
            if target.windowOrNil?.containingSection != nil {
                return .fail(io.err("Can't resize a section: section widths come from workspace-sections in the config"))
            }
```

`FlattenWorkspaceTreeCommand.swift`, replace the windows loop with:
```swift
        // workspace-sections: each section flattens on its own
        let containers = workspace.sections == nil ? [workspace.rootTilingContainer] : workspace.sectionContainers
        for container in containers {
            for window in container.allLeafWindowsRecursive {
                window.bind(to: container, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            }
        }
```

`LayoutCommand.swift`:
- `run`, right after `guard let target = …`:
```swift
        if args.root && target.workspace.sections != nil {
            return changeSectionsLayout(target.workspace, args, io)
        }
```
- New functions, after `changeTilingLayout`:
```swift
/// workspace-sections: `layout --root` sets every section's layout, and the layout of the sections to come. Each section
/// keeps its orientation, so only the layout (tiles, accordion, tabs) counts
@MainActor private func changeSectionsLayout(_ workspace: Workspace, _ args: LayoutCmdArgs, _ io: CmdIo) -> BinaryExitCode {
    let current = workspace.sectionsLayout
    let targetDescription = args.toggleBetween.val.first(where: { sectionLayout(of: $0) != current })
        ?? args.toggleBetween.val.first.orDie()
    guard let layout = sectionLayout(of: targetDescription) else {
        let msg = targetDescription == .horizontal || targetDescription == .vertical
            ? "Each section keeps its orientation (workspace-sections). Run 'layout horizontal|vertical' on a window of the section"
            : "'layout --root \(targetDescription.rawValue)' doesn't work with workspace-sections"
        return .fail(io.err(msg))
    }
    let sections = workspace.sectionContainers
    if (workspace.newSectionLayout ?? config.defaultRootContainerLayout) == layout && sections.allSatisfy({ $0.layout == layout }) {
        switch args.failIfNoop {
            case true: return .fail
            case false:
                return .succ(io.err("Already in the requested \(targetDescription.rawValue) mode. Tip: use --fail-if-noop to exit with non-zero exit code"))
        }
    }
    workspace.newSectionLayout = layout
    for section in sections {
        section.layout = layout
    }
    return .succ
}

/// The layout `layout --root <description>` gives every section (workspace-sections), or nil when it can't
private func sectionLayout(of description: LayoutCmdArgs.LayoutDescription) -> Layout? {
    switch description {
        case .tiles, .h_tiles, .v_tiles: .tiles
        case .accordion, .h_accordion, .v_accordion: .accordion
        case .tabs: .tabs
        case .horizontal, .vertical, .scrolling, .tiling, .floating, .unmanaged, .sticky: nil
    }
}
```

Append to `workspaceSections.swift`, in `extension Workspace`:
```swift
    /// The sections' layout: the default section's (else the first's). While no section holds windows, the one
    /// `layout --root` gave the sections to come
    @MainActor var sectionsLayout: Layout {
        rootLayoutContainer.takeIf { $0.section != nil }?.layout ?? newSectionLayout ?? config.defaultRootContainerLayout
    }
```

`format.swift`:
- The two workspace cases:
```swift
                    case .workspaceRootContainerLayout:
                        // workspace-sections: the sections' layout, in the default section's orientation
                        .success(.string(w.sections == nil
                                ? toLayoutString(tc: w.rootTilingContainer)
                                : toLayoutString(w.sectionsLayout, w.rootLayoutContainer.orientation)))
                    case .workspaceRootContainerOrientation: .success(.string(toOrientationString(w.rootLayoutContainer.orientation)))
```
- Split `toLayoutString(tc:)` so it takes a layout and an orientation:
```swift
private func toLayoutString(tc: TilingContainer) -> String { toLayoutString(tc.layout, tc.orientation) }

private func toLayoutString(_ layout: Layout, _ orientation: Orientation) -> String {
    switch (layout, orientation) {
        // ... the existing six cases, unchanged ...
    }
}
```

`WorkspaceCommand.swift`, in `if args.viewToggle {`, before `performViewToggle(…)`:
```swift
                    // Toggling off still works: it puts back what toggling on moved
                    let isToggledOn = focusedWs.viewToggledStates.contains { $0.donorWorkspaceName == workspaceName }
                    if !isToggledOn && (focusedWs.sections != nil || config.workspaceSections?.applies(to: workspaceName) == true) {
                        return .fail(io.err("workspace --view-toggle doesn't work with workspace-sections yet"))
                    }
```

**Step 4: Run to see them pass**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest` then `swift test --filter 'AppBundleTests.(JoinWithCommandTest|ResizeCommandTest|FlattenWorkspaceTreeCommandTest|LayoutCommandTest|WorkspaceViewToggleTest|ListWorkspacesTest)'`
Expected: all `0 failures`. If a filter names a class that doesn't exist, drop it from the filter.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): join-with, resize, flatten and layout --root know about sections"
```

---

### Task 11: The closed-windows cache keeps sections

When a window closes, the whole tree is frozen. A window that comes back within the cache's life restores it with new
containers, which had no names. Normalization would then sweep every window to its last section, losing order.

**Files:**
- Modify: `Sources/AppBundle/tree/frozen/FrozenTreeNode.swift` (`FrozenContainer`)
- Modify: `Sources/AppBundle/tree/frozen/closedWindowsCache.swift` (`restoreTreeRecursive`)
- Test: `Sources/AppBundleTests/tree/WorkspaceSectionsTest.swift`

**Step 1: Write the failing test** (append to `WorkspaceSectionsTest`)

```swift
    func testTheClosedWindowsCacheKeepsSections() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        let left = TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        let main = TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        let frozen = FrozenContainer(workspace.rootTilingContainer)
        workspace.rootTilingContainer.unbindFromParent()
        restoreTreeRecursive(frozenContainer: frozen, parent: workspace, index: INDEX_BIND_LAST, lookup: { [1: left, 2: main][$0] })
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1)])),
            .section("main", .h_tiles([.window(2)])),
        ]))
    }
```

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.WorkspaceSectionsTest`
Expected: FAIL, the restored containers have no section.

**Step 3: Implement**

`FrozenTreeNode.swift`, `FrozenContainer`: add `let section: String?` after `let weight: CGFloat`, and in `init` after
`orientation = container.orientation`: `section = container.section`.

`closedWindowsCache.swift`, `restoreTreeRecursive`, right after `let container = TilingContainer(…)`:
```swift
    container.section = frozenContainer.section
```

**Step 4: Run to see it pass**
Run: `swift test --filter 'AppBundleTests.(WorkspaceSectionsTest|ClosedWindowsCacheTest)'`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources
git commit -m "feat(sections): the closed-windows cache keeps sections"
```

---

### Task 12: `%{window-section}`

keep-windows needs each window's section. aero-helper can use it later.

**Files:**
- Modify: `Sources/Common/cmdArgs/impl/ListWindowsCmdArgs.swift` (`WindowFormatVar`: `case windowSection = "window-section"` after `windowTreeIndex`)
- Modify: `Sources/AppBundle/command/format.swift` (the window `switch f`)
- Modify: `Sources/AppBundle/command/impl/ListTreeCommand.swift` (`windowVars`: add `.window(.windowSection)`)
- Modify (they pin the list of variables): `Sources/AppBundleTests/command/EchoCommandTest.swift:45`,
  `Sources/AppBundleTests/command/TestCommandTest.swift:25,31`. Insert `|window-section` right after
  `window-tree-index`. Also add `"window-section"` to the expected window-variable set in
  `Sources/AppBundleTests/command/ListTreeTest.swift`.
- Modify: `docs/aerospace-list-windows.adoc` (after the last `%{window-…}` variable)
- Test: `Sources/AppBundleTests/command/SectionsCommandsTest.swift`

**Step 1: Write the failing test** (append to `SectionsCommandsTest`)

```swift
    func testWindowSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        let result = await run("list-windows --workspace a --format '%{window-section}|%{window-id}'")
        assertEquals(Set(result.stdout), ["left|1", "|2"])
    }
```

**Step 2: Run to see it fail**
Run: `swift test --filter AppBundleTests.SectionsCommandsTest`
Expected: FAIL, unknown `%{window-section}` interpolation variable.

**Step 3: Implement**
- `format.swift`, in `case (.window(let w), .window(let f))`:
```swift
                    case .windowSection: .success(.string(w.window.sectionName ?? ""))
```
- `docs/aerospace-list-windows.adoc`:
```asciidoc
%{window-section}:: String. The section the window is in (`[workspace-sections]`). Empty when it's in none
```
- The enum case, `windowVars` and the pinned test strings as listed under Files.

**Step 4: Run to see it pass**
Run: `swift test --filter 'AppBundleTests.(SectionsCommandsTest|EchoCommandTest|TestCommandTest|ListTreeTest)'`
Expected: `0 failures`.

**Step 5: Commit**
```bash
git add Sources docs
git commit -m "feat(sections): window-section format variable"
```

---

### Task 13: keep-windows keeps sections

After a restart, every window is new, so it lands in the default section. Restore puts each window back in its saved
section, in order.

**Files:**
- Modify: `script/keep-windows.py`:
  - the docstring;
  - `Tree.__init__`;
  - `save`;
  - `put_back`;
  - `restore`'s final check.
- Modify: `script/keep-windows-test.py`:
  - the fake `list-tree`, `move-node-to-workspace` and `move-node-to-section`;
  - `restart`, `differences`;
  - a new test.

**Step 1: Write the failing test**

In `keep-windows-test.py`, the fake models sections like AeroSpace's:
- a tiled window is in a section;
- list-tree gives a workspace's windows section by section;
- a move appends to the end of the window's section;
- a move without `--section` keeps the window's section;
- after a restart, every window is in the default section.

Add after `show`:
```python
ORDER = ["left", "main", "right"]  # the fake's sections, left to right (workspace-sections)


def section_of(s, wid):
    """'' without sections, or for a floating window"""
    return "" if wid in s["floating"] else s.get("sections", {}).get(str(wid), "")


def tree_order(s, w):
    """A workspace's windows as list-tree gives them: section by section"""
    return sorted(w["windows"], key=lambda wid: ORDER.index(section_of(s, wid)) if section_of(s, wid) in ORDER else len(ORDER))
```
In the fake `list-tree`:
- give each window a key: `"window-section": section_of(s, wid)`;
- iterate `for wid in tree_order(s, w)` instead of `for wid in w["windows"]`.

Replace the `move-node-to-workspace` branch with:
```python
    if args[:2] == ["move-node-to-workspace", "--window-id"]:
        wid, ws = int(args[2]), args[3]
        section = args[5] if args[4:5] == ["--section"] else None
        src = where(s, wid)
        if src == ws and section in (None, section_of(s, wid)):
            print("noop")
            return 0
        if section is not None:
            s.setdefault("sections", {})[str(wid)] = section
        s["workspaces"][src]["windows"].remove(wid)
        ensure(s, ws)["windows"].append(wid)
```
and add a branch before `elif args[:2] == ["layout", "--workspace"]`:
```python
    elif args[:2] == ["move-node-to-section", "--window-id"]:
        wid, section = int(args[2]), args[3]
        ws = where(s, wid)
        s.setdefault("sections", {})[str(wid)] = section
        s["workspaces"][ws]["windows"].remove(wid)
        s["workspaces"][ws]["windows"].append(wid)
```
Replace the `layout --root` branch's assignment (`s["workspaces"][args[2]]["root"] = args[4]`) with:
```python
        w = s["workspaces"][args[2]]
        sectioned = any(section_of(s, wid) for wid in w["windows"])
        # As in AeroSpace: a bare tiles|accordion keeps the orientation, and with sections each section keeps its own
        w["root"] = w["root"].split("_")[0] + "_" + args[4].split("_")[-1] if sectioned or "_" not in args[4] else args[4]
```
In `restart`, before `gc(s)` (the first one):
```python
    if "sections" in s:
        s["sections"] = {wid: "main" for wid in s["sections"]}  # Every window is new: the default section
```
In `differences`:
- compare `tree_order(now, have)` against `[wid for wid in tree_order(saved, w) if wid not in gone]` instead of
  `have["windows"] != want`;
- replace the root check with one that compares only tiles/accordion for a workspace with sections:
```python
        sectioned = any(saved.get("sections", {}).get(str(wid)) for wid in want)
        kind = (lambda root: root.split("_")[-1]) if sectioned else (lambda root: root)
        if any(wid not in saved["floating"] for wid in want) and kind(have["root"]) != kind(w["root"]):
            problems.append(f"{name}: root {have['root']} != {w['root']}")
```
- after the floating check, add:
```python
    off = {wid: section for wid, section in saved.get("sections", {}).items()
           if int(wid) not in gone and int(wid) not in saved["floating"] and now.get("sections", {}).get(wid) != section}
    if off:
        problems.append(f"sections {off}")
```
New test, added to `TESTS` as `("sections: each window back in its section, in order", test_sections)`:
```python
def test_sections(root):
    s = copy.deepcopy(BASE)
    s["sections"] = {"20100": "main", "27623": "main", "28169": "left", "29014": "right",
                     "28325": "main", "28940": "right", "500": "left", "501": "main", "29304": "main"}
    env = Env(root, s)
    env.run("save")
    env.put(restart(s))
    code, out = env.run("restore")
    return differences(env, s)[0] + exit_ok(code, out)
```

**Step 2: Run to see it fail**
Run: `./script/keep-windows-test.py`
Expected: `FAIL sections: ...`, since windows come back in main, and CC2/Temp1's saved `v_…` layouts can't come back
with sections. Every other test `PASS`.

**Step 3: Implement** (`keep-windows.py`)
- Docstring: "each window's workspace and tree order" → "each window's workspace, section (workspace-sections) and tree order".
- `Tree.__init__`: `self.section = {}   # window id -> its section ('' when in none)`, and in the windows loop:
  `self.section[w["window-id"]] = w.get("window-section", "")`.
- `save`, in each workspace entry:
  `"sections": {str(wid): tree.section[wid] for wid in ids if tree.section.get(wid)},`
- `put_back`:
  - Add, before the function:
```python
def section_flag(ws, wid):
    """`--section <name>` for a window that was in a section (workspace-sections)"""
    section = ws.get("sections", {}).get(str(wid))
    return ["--section", section] if section else []
```
  - Pass `*section_flag(ws, wid)` to both `move-node-to-workspace` calls to `ws["name"]`: the first loop, and the second
    of the staging pair.
  - After the first loop's `tree = tree_now()`, insert before the order check:
```python
    for ws in snapshot["workspaces"]:
        # Already on its workspace, in another section
        for wid, floating in ws["windows"]:
            section = ws.get("sections", {}).get(str(wid))
            if section and not floating and wid not in gone and tree.where.get(wid) == ws["name"] \
                    and tree.section.get(wid) != section:
                changed |= change("move-node-to-section", "--window-id", str(wid), section)
    tree = tree_now()
```
- Layouts with sections: `layout --root` sets only tiles or accordion, and each section keeps its orientation. A
  saved `v_tiles` restored onto `h` sections would otherwise never match, so `restore` would retry and exit 2. Add,
  before `put_back`:
```python
def root_kind(ws, layout):
    """With sections (workspace-sections), `layout --root` sets tiles or accordion: each section keeps its orientation"""
    return layout.rsplit("_", 1)[-1] if layout and ws.get("sections") else layout
```
  In `put_back`'s layout check, compare `root_kind(ws, tree.roots.get(name)) != root_kind(ws, ws["root"])` and pass
  `root_kind(ws, ws["root"])` to `layout --root`. In `restore`, `layouts_off` compares the same way.
- `restore`, final check, after `layouts_off`:
```python
    sections_off = [wid for ws in snapshot["workspaces"] for wid, floating in ws["windows"]
                    if not floating and wid not in gone
                    and ws.get("sections", {}).get(str(wid), tree.section.get(wid)) != tree.section.get(wid)]
```
  and report it like the others: print `f"  ! not back in their sections: {sections_off}"`, and include it in the
  `if off or layouts_off or labels_off` condition.

**Step 4: Run to see it pass**
Run: `./script/keep-windows-test.py`
Expected: every line `PASS`.

**Step 5: Commit**
```bash
git add script
git commit -m "feat(keep-windows): restore each window's section"
```

---

### Task 14: Document it

**Files:**
- Modify: `docs/guide.adoc`, a new section after `=== Normalization` (before `[#floating-windows]`)
- Modify: `docs/aerospace-layout.adoc` (`--root` note), `docs/aerospace-flatten-workspace-tree.adoc` (one line)
- Modify: `CLAUDE.md` (Key architecture)

**Step 1: Guide section**
```asciidoc
[#sections]
=== Sections

`[workspace-sections]` makes workspaces rows of side-by-side sections, such as a narrow strip on each side of a wide
main area.
The sections are containers of the workspace's tree, so switching workspaces switches them too.

[source,toml]
----
[workspace-sections]
    default = 'main'      # New windows go here
    sections = [          # Left to right
        { name = 'left', width = 1 },
        { name = 'main', width = 2, collapse = false },
        { name = 'right', width = 1 }
    ]
    # workspaces = ['1', '2']   # Optional: only these workspaces have sections
----

* `width` is relative to the other sections' widths.
* Without windows, a section gives its width to the others (`collapse = true`, the default), or keeps an empty slot
(`collapse = false`).
* Inside a section, windows tile like in any container.
* New windows go to the `default` section.
A window keeps its section when it moves to another workspace or monitor, and when it tiles again after floating,
minimized or a hidden app.
* Window rules put windows in sections:
+
[source,toml]
----
[[on-window-detected]]
    if.app-id = 'com.tinyspeck.slackmacgap'
    run = 'move-node-to-section left'                   # Of the workspace it opened on

[[on-window-detected]]
    if.app-id = 'com.spotify.client'
    run = 'move-node-to-workspace 2 --section right'    # Of another workspace
----
* `focus` and `move` go across sections.
A window that moves to a section without windows brings the section back.
Past the outer sections, and up or down, the section is the workspace's edge.
* `join-with` doesn't join windows of different sections, and `resize` doesn't resize sections: their widths are the
config's.
* `layout --root`, `flatten-workspace-tree` and `balance-sizes` act on every section.
`layout --root` keeps each section's orientation, and `%{workspace-root-container-layout}` is the default section's
layout.
* `%{window-section}` (`list-windows`, `list-tree`) is the window's section.
* Sections don't work with `enable-normalization-binary-tree`, `enable-auto-tiling`,
`default-root-container-layout = 'scrolling'` or `workspace --view-toggle`.
```
`aerospace-layout.adoc`, under `--root`: "In a workspace with sections (`[workspace-sections]`), it sets every section's
layout, and each section keeps its orientation." `aerospace-flatten-workspace-tree.adoc`, in the body: "With
sections (`[workspace-sections]`), each section flattens on its own." Then `./generate.sh --ignore-xcodeproj`.

**Step 2: CLAUDE.md**, add to Key architecture:
```markdown
- `workspace-sections` (fork-only, `[workspace-sections]`, `move-node-to-section`, `move-node-to-workspace --section`):
  a workspace's root is a row of section containers (`TilingContainer.section`) in config order, each holding windows.
  `Workspace.normalizeSections()` (`Sources/AppBundle/tree/workspaceSections.swift`, first step of `normalizeContainers`)
  keeps it so: whatever lands in the root goes to a section, empty sections go, flattening never removes a section or
  its row. Layout cuts the row by width (`sectionFrames`; collapse or keep an empty slot). Windows keep their section
  across workspaces (`moveWindowToWorkspace`) and when they tile again (`Window.lastSection`). User doc:
  `docs/guide.adoc#sections`.
```

**Step 3: Commit**
```bash
git add docs CLAUDE.md Sources
git commit -m "docs: workspace sections"
```

---

### Task 15: Full check and PR

**Step 1:** `./format.sh` then `git diff --stat` (commit any formatting as `style: swiftformat`).
**Step 2:** `./test.sh`
Expected: ends with `✅ All tests have passed successfully` (it also fails on uncommitted generated files: commit them).
**Step 3:** `./script/keep-windows-test.py` — every line `PASS`.
**Step 4:** Push `feature/workspace-sections` and open a PR against `MintCollector/AeroSpace` (not upstream). The body:
- says it reverts #32 and keeps the two fixes;
- lists the decisions and the "Known, not changed" list below;
- ends with the attribution from the session's system reminder.

---

### Task 16: Deploy and configure (ask James first)

Installing restarts AeroSpace and shuffles the screen for ~15s, and the live check opens/moves windows: **ask James and
wait for his go-ahead before Step 1 and before Step 4.** Do the config edits only after the new build is installed:
`auto-reload-config` would make the old build reject the unknown `workspace-sections` key.

**Step 1:** After the PR is merged and the main checkout is updated: `make -C /Users/jedwards/code/aero/AeroSpace deploy`.
If AeroSpace doesn't answer afterwards, see memory `accessibility-reset-on-deploy`.

**Step 2:** Prove the installed app has the feature:
- `aerospace move-node-to-section --help` prints the usage;
- `aerospace list-windows --all --format '%{window-section}'` is accepted.

**Step 3:** Ask James three things:
- which apps go to which section (and workspace);
- whether `main` should keep its slot (`collapse = false`, proposed);
- whether to limit `workspaces` (e.g. leave `Laptop` and `U28E590` without sections).

Then add the `[workspace-sections]` table and the rules to `~/.config/aerospace/aerospace.toml`. Add the same to
`/Users/jedwards/code/aero/aero-helper/profiles.toml`: the table in the shared settings, the rules among the others.
Both files change together.
- Write `move-node-to-workspace <ws> --section <s>` with the workspace name first: aero-helper's
  `WorkspaceLabels`/`HelperConfigWriter` take the first non-flag token after the command as the workspace.
- Prove the two files agree:
  - `aero-helper profile --current` names the current profile;
  - `aero-helper profile <current> --dry-run`, diffed against the live `aerospace.toml`, should differ only by a trailing
    blank line.
- profiles.toml is in the aero-helper repo: leave the commit to James or the aero-helper session.

**Step 4 (James watching):** `aerospace reload-config`, then check live:
- A ruled app opens in its section, on the focused workspace or the one its rule names.
- `workspace` switches take the sections along.
- `move left/right` crosses sections.
- An empty side section gives its width to main; `main` keeps its slot when it is empty.
- `toggle-accordion` (cmd-ctrl-alt-backslash) flips every section and back.
- `make install`'s keep-windows round trip puts windows back in their sections.

---

## Known, not changed

- A window that crosses to another monitor (`move-node-to-monitor`, `move --boundaries all-monitors-outer-frame`)
  keeps its section. So leaving the right section to the right lands in the right section of the next monitor's
  workspace, not its left.
- Shell completion doesn't know `move-node-to-section` or `--section`.
- `max-window-width` per column count (`perColumnCount`) counts the sections present as columns. James uses one value.
- A reserved empty slot isn't a mouse drop target. A window dragged to an empty part of another monitor lands in its
  last section.
- Pre-existing bugs found in research:
  - `workspace --view-toggle` crashes when the donor workspace has floating windows (`ViewToggle.swift:35` binds a
    window to a Workspace).
  - Minimized windows come back on the focused workspace.
  - `macos-native-fullscreen` never sets `layoutReason`.

## Appendix: aero-helper follow-ups (separate, in the aero-helper repo)

- `SharedCode/Sources/AeroSocket/WorkspaceLabels.swift:80-105` (`aeroOptionsWithValue`) and
  `SharedCode/Sources/AeroProfile/HelperConfigWriter.swift:49-67` (`workspaceFromRun`) treat `--section left` before
  the workspace name as the workspace. Add `--section` to the options that take a value.
- The accordion strip (`AccordionStripPanelController.swift`) lists every tiled window of the workspace, and so every
  section's windows. It could use `%{window-section}` to show the default section's only.
- Overview drag-reorder (`swap dfs-next|dfs-prev`) moves windows across sections.

---

## Executive Summary

**What exists today:**
- One workspace per monitor, with one tree whose root lays out windows side by side.
- Split-monitors (PR #32) is merged and deployed but unconfigured. It makes columns of a screen into monitors that
  switch workspaces independently.

**What we're moving to:**
- `[workspace-sections]` makes each workspace's root a row of named sections, e.g. left | main | right as 1 | 2 | 1.
  An empty section collapses or keeps its slot, per section.
- `move-node-to-section left` and `move-node-to-workspace 2-S --section right` (also in `on-window-detected`) place
  windows.
- New windows go to the default section, and windows keep their section across workspaces.
- `move`, `layout --root`, flatten, `join-with`, `resize`, the closed-windows cache, `%{window-section}` and
  keep-windows all know about sections. Normalization keeps the shape whatever path changes the tree.
- Split-monitors is reverted, keeping two upstream bug fixes.

**Why:**
- James wants sections that come with the workspace (Slack on the left of whatever's open), not independent columns.
- It is AeroSpace's tree model, and the shape upstream's maintainer proposed in #260 (declared layouts with
  placeholders that collapse), with named slots for rules.
