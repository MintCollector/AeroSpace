# Workspace Overview Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Holding Ctrl opens a full-screen, Mission-Control-style overview in aero-helper. It shows every workspace as a card, with each window drawn as a box at its real tiled position (app icon + title). You can drag a window to another card to move it, click a window to focus it, or click a card to switch to that workspace.

**Architecture:** The AeroSpace fork gets a side-effect-free `Workspace.previewLayoutRects()`. It uses the same tile/accordion math as the live layout (extracted into pure functions), so `list-tree` can report a `window-layout-x/y/width/height` for every window, including windows on hidden workspaces. AeroSpace parks those in a screen corner and clears their cached rect, so a cache can't provide this. aero-helper decodes the new fields. Its pure logic goes in a new SharedCode module `AeroOverview`: the card grid, unit-rect mapping and the peek/pin state machine, all unit-tested. A new full-screen `OverviewPanelController` + `OverviewView` reuse the existing drag/drop types and move/focus actions. The existing left panel is kept, and a menu setting chooses which one Ctrl-hold opens.

**Tech Stack:** Swift. AeroSpace fork: SwiftPM + XCTest (`swift test`). aero-helper: SwiftUI + AppKit `NSPanel`; SharedCode SwiftPM package (XCTest); Xcode project with synchronized folder groups.

**Worktree:** fork: `EnterWorktree` with name `workspace-overview`. Helper: `git worktree add` on branch `feature/workspace-overview` (Task 1).

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation. Delete old interfaces, rename freely, and update all callers directly. Clean code over migration paths.
- Complete code in every step, with no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

---

## Context

The user wants the Ctrl-hold peek to become a Mission-Control-like overview instead of expanding the left-side panel. Decisions already made:
- v1 draws **layout boxes** (icon + title at the real position and size). No live thumbnails.
- **Hold Ctrl to peek, click to pin.** Release hides the overview unless it is pinned. Esc or a click on the background closes it.
- **Keep the left panel.** A setting picks which UI Ctrl-hold opens.

Constraint found during exploration: in the fork, `Window.hideInCorner` (Window.swift:130) sets `lastAppliedLayoutPhysicalRect = nil` for every window on a non-visible workspace, so hidden workspaces have no geometry. A persistent cache would also go stale as soon as the overview moves windows between hidden workspaces. So the fork computes a preview layout from the tree on demand.

Related hotfix: commit `6cd53d8` on aero-helper `main` was pushed with `holdDelay = 0.1`. The user asked for about 50ms, and the commit message claims 60ms. Task 2 fixes it.

---

### Task 1: Set Up Worktrees

**Step 1: Validate You Are In A Worktree (fork)**
Validate that work is being done in a worktree. If it isn't, use the `EnterWorktree` tool with `name: "workspace-overview"` from `/Users/jedwards/code/aero/AeroSpace`.

**Step 2: Create the helper worktree** (a separate repo, so use plain git)
```bash
git -C /Users/jedwards/code/aero/aero-helper worktree add /Users/jedwards/code/aero/aero-helper-workspace-overview -b feature/workspace-overview
```
Expected: `Preparing worktree (new branch 'feature/workspace-overview')`. All helper paths below are relative to `/Users/jedwards/code/aero/aero-helper-workspace-overview` (call it `$HELPER`).

**Step 3: Verify a clean baseline**
```bash
make check                                   # fork worktree: swift build --arch arm64
swift test --filter ListTreeTest             # fork worktree
cd $HELPER && make check                     # helper: build + SharedCode tests
```
Expected: all pass. If anything fails, investigate before going on.

---

### Task 2: Hotfix the hold delay on helper `main` (50ms)

Do this on helper **main** (`/Users/jedwards/code/aero/aero-helper`), not in the feature worktree.

**Step 1:** In `App/Config/KeyMonitoringService.swift` (around line 16), replace the `holdDelay` doc comment and value with:
```swift
    /// Filters the ~35ms Control presses that keyboard/remapper shortcuts generate while still
    /// feeling instant on a real hold. Kept deliberately short (user preference).
    private static let holdDelay: TimeInterval = 0.05
```
**Step 2:** `make deploy`. Expected: `Helper deployed`.
**Step 3: Commit and push**
```bash
git add App/Config/KeyMonitoringService.swift
git commit -m "fix(overlay): Control hold delay is 50ms (6cd53d8 shipped 100ms by mistake)"
git push origin main
```
**Step 4:** Rebase the feature branch onto it: `git -C $HELPER rebase main`.

---

### Task 3 (fork): Extract pure tile/accordion frame math

**Files:**
- Modify: `Sources/AppBundle/layout/layoutRecursive.swift` (`layoutTiles` L122-173, `layoutAccordion` L175-209)
- Test: `Sources/AppBundleTests/layout/PreviewLayoutTest.swift` (new; written in Task 4. This task is a pure refactor guarded by the existing suite.)

**Step 1:** Add the pure frame types and functions inside `extension TilingContainer` (next to `layoutChildren`):
```swift
struct ChildFrame {
    let child: TreeNode
    let point: CGPoint
    let width: CGFloat
    let height: CGFloat
    let virtual: Rect
    /// Weight along the container orientation after normalization (tiles only)
    let weight: CGFloat
}

/// Where each child of a `tiles` container goes. Pure: weights are read, not normalized in place.
/// The caller applies `weight` when it is laying out for real.
@MainActor
func tileFrames(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect,
                gaps: ResolvedGaps, maxWindowWidth: CGFloat?) -> [ChildFrame] {
    var point = point
    var virtualPoint = virtual.topLeftCorner
    let effectiveChildren = layoutChildren
    guard let delta = ((orientation == .h ? width : height) - CGFloat(effectiveChildren.sumOfDouble { $0.getWeight(orientation) }))
        .div(effectiveChildren.count) else { return [] }
    let lastIndex = effectiveChildren.indices.last
    let rawGap = gaps.inner.get(orientation).toDouble()

    // Center clamped children as a group so excess space goes to outer edges
    if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0 {
        var totalOccupied: CGFloat = 0
        for (i, child) in effectiveChildren.enumerated() {
            let adjustedWeight = CGFloat(child.getWeight(orientation) + delta)
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            totalOccupied += min(adjustedWeight, maxWidth + gap)
        }
        point = CGPoint(x: point.x + (width - totalOccupied) / 2, y: point.y)
    }

    var frames: [ChildFrame] = []
    for (i, child) in effectiveChildren.enumerated() {
        let weight = child.getWeight(orientation) + delta
        let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
        var childWidth = orientation == .h ? weight - gap : width
        if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0, childWidth > maxWidth {
            childWidth = maxWidth
        }
        frames.append(ChildFrame(
            child: child,
            point: i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
            width: childWidth,
            height: orientation == .v ? weight - gap : height,
            virtual: Rect(
                topLeftX: virtualPoint.x,
                topLeftY: virtualPoint.y,
                width: orientation == .h ? weight : width,
                height: orientation == .v ? weight : height,
            ),
            weight: weight,
        ))
        virtualPoint = orientation == .h ? virtualPoint.addingXOffset(weight) : virtualPoint.addingYOffset(weight)
        if orientation == .h, let maxWidth = maxWindowWidth, maxWidth > 0 {
            point = point.addingXOffset(min(weight, maxWidth + gap))
        } else {
            point = orientation == .h ? point.addingXOffset(weight) : point.addingYOffset(weight)
        }
    }
    return frames
}

/// Where each child of an `accordion` container goes. Pure.
@MainActor
func accordionFrames(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect) -> [ChildFrame] {
    guard let mostRecentChild else { return [] }
    let children = layoutChildren
    let mruIndex: Int = children.firstIndex { $0 === mostRecentChild } ?? 0
    let padding = CGFloat(config.accordionPadding)
    return children.enumerated().map { index, child in
        let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
            case 0 where children.count == 1: (0, 0)
            case 0:                           (0, padding)
            case children.indices.last:       (padding, 0)
            case mruIndex - 1:                (0, 2 * padding)
            case mruIndex + 1:                (2 * padding, 0)
            default:                          (padding, padding)
        }
        return switch orientation {
            case .h: ChildFrame(child: child, point: point + CGPoint(x: lPadding, y: 0),
                                width: width - rPadding - lPadding, height: height, virtual: virtual, weight: 0)
            case .v: ChildFrame(child: child, point: point + CGPoint(x: 0, y: lPadding),
                                width: width, height: height - lPadding - rPadding, virtual: virtual, weight: 0)
        }
    }
}
```

**Step 2:** Replace the bodies of `layoutTiles` and `layoutAccordion` so the live path uses those functions:
```swift
@MainActor
fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
    for f in tileFrames(point, width: width, height: height, virtual: virtual,
                        gaps: context.resolvedGaps, maxWindowWidth: context.maxWindowWidth) {
        f.child.setWeight(orientation, f.weight)
        try await f.child.layoutRecursive(f.point, width: f.width, height: f.height, virtual: f.virtual, context)
    }
}

@MainActor
fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
    for f in accordionFrames(point, width: width, height: height, virtual: virtual) {
        try await f.child.layoutRecursive(f.point, width: f.width, height: f.height, virtual: f.virtual, context)
    }
}
```

**Step 3: Run the full suite to prove the refactor changed nothing**
Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, with the same count as the Task 1 baseline.

**Step 4: Commit**
```bash
git add Sources/AppBundle/layout/layoutRecursive.swift
git commit -m "refactor(layout): extract pure tileFrames/accordionFrames from the live layout pass"
```

---

### Task 4 (fork): `Workspace.previewLayoutRects()` + floating restore rect

**Files:**
- Create: `Sources/AppBundle/layout/previewLayout.swift`
- Modify: `Sources/AppBundle/tree/Window.swift` (`unhideFromCorner`, floating branch L143-155)
- Test: `Sources/AppBundleTests/layout/PreviewLayoutTest.swift`

**Step 1: Write the failing tests**
```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class PreviewLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// The preview must match what the live pass applies, for tiles and accordion.
    func testPreviewMatchesLiveLayout() async throws {
        for layout in [Layout.tiles, .accordion] {
            setUpWorkspacesForTests()
            let ws = focus.workspace
            ws.rootTilingContainer.layout = layout
            let ids: [UInt32] = [1, 2, 3]
            for id in ids { _ = TestWindow.new(id: id, parent: ws.rootTilingContainer) }
            let preview = ws.previewLayoutRects()
            _ = try await ws.layoutWorkspace()
            for window in ws.rootTilingContainer.allLeafWindowsRecursive {
                assertEquals(preview[window.windowId], window.lastAppliedLayoutPhysicalRect)
            }
        }
    }

    func testPreviewDoesNotNormalizeWeights() {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        _ = TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        let before = a.getWeight(.h)
        _ = ws.previewLayoutRects()
        assertEquals(a.getWeight(.h), before)
    }

    /// Hidden workspaces have no cached rect; the preview still lays them out on their monitor.
    func testHiddenWorkspaceGetsRects() {
        let hidden = Workspace.get(byName: "hidden-preview")
        _ = TestWindow.new(id: 7, parent: hidden.rootTilingContainer)
        _ = TestWindow.new(id: 8, parent: hidden.rootTilingContainer)
        assertTrue(!hidden.isVisible)
        let rects = hidden.previewLayoutRects()
        let monitor = hidden.workspaceMonitor.rect
        assertEquals(rects.count, 2)
        for r in rects.values {
            assertTrue(r.width > 0 && r.height > 0)
            assertTrue(r.minX >= monitor.minX && r.maxX <= monitor.maxX)
        }
        assertTrue(rects[7]!.minX < rects[8]!.minX) // h_tiles: side by side
    }
}
```
**Step 2:** Run `swift test --filter PreviewLayoutTest`. Expected: FAIL (`value of type 'Workspace' has no member 'previewLayoutRects'`).

**Step 3: Implement** `Sources/AppBundle/layout/previewLayout.swift`:
```swift
import AppKit

extension Workspace {
    /// Where layoutWorkspace would put each tiled window, without touching AX, weights or caches.
    /// Rects are global top-left points, like `lastAppliedLayoutPhysicalRect`. Tiles and accordion
    /// are exact (they share `tileFrames`/`accordionFrames` with the live pass). Scrolling and tabs
    /// show one page at a time, so every page previews as the full container rect.
    /// Floating windows are not included; see `Window.floatingRestoreRect`.
    @MainActor
    func previewLayoutRects() -> [UInt32: Rect] {
        var result: [UInt32: Rect] = [:]
        if isEffectivelyEmpty { return result }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps(forWorkspace: name)
        let context = LayoutContext(self)
        rootTilingContainer.preview(rect.topLeftCorner, width: rect.width, height: rect.height - 1,
                                    virtual: rect, context, into: &result)
        return result
    }
}

extension TreeNode {
    @MainActor
    fileprivate func preview(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect,
                             _ context: LayoutContext, into result: inout [UInt32: Rect]) {
        switch nodeCases {
            case .window(let window):
                if window.isAwaitingOnWindowDetected { return }
                if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                    let monitor = context.workspace.workspaceMonitor
                    result[window.windowId] = window.noOuterGapsInFullscreen
                        ? monitor.visibleRect
                        : monitor.visibleRectPaddedByOuterGaps(forWorkspace: context.workspace.name)
                } else {
                    result[window.windowId] = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
                }
            case .tilingContainer(let container):
                // Same layout substitution as layoutRecursive's .tilingContainer case
                let layout = !TrayMenuModel.shared.isEnabled && (container.layout == .scrolling || container.layout == .tabs)
                    ? Layout.accordion : container.layout
                let frames: [TilingContainer.ChildFrame] = switch layout {
                    case .tiles: container.tileFrames(point, width: width, height: height, virtual: virtual,
                                                      gaps: context.resolvedGaps, maxWindowWidth: context.maxWindowWidth)
                    case .accordion: container.accordionFrames(point, width: width, height: height, virtual: virtual)
                    case .scrolling, .tabs: container.children.map {
                        .init(child: $0, point: point, width: width, height: height, virtual: virtual, weight: 0)
                    }
                }
                for f in frames {
                    f.child.preview(f.point, width: f.width, height: f.height, virtual: f.virtual, context, into: &result)
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return
        }
    }
}
```
In `Window.swift`, extract the floating restore math from `unhideFromCorner` so list-tree can reuse it. Add next to `isHiddenInCorner`:
```swift
    /// Where `unhideFromCorner` will put this hidden floating window back (global top-left points)
    @MainActor
    var floatingRestoreRect: Rect? {
        guard let p = prevUnhiddenProportionalPositionInsideWorkspaceRect, let nodeWorkspace else { return nil }
        let workspaceRect = nodeWorkspace.workspaceMonitor.rect
        // todo we probably should replace lastFloatingSize with proper floating window sizing
        // https://github.com/nikitabobko/AeroSpace/issues/1519
        let windowWidth = lastFloatingSize?.width ?? 0
        let windowHeight = lastFloatingSize?.height ?? 0
        let x = (workspaceRect.topLeftX + workspaceRect.width * p.x)
            .coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
        let y = (workspaceRect.topLeftY + workspaceRect.height * p.y)
            .coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))
        return Rect(topLeftX: x, topLeftY: y, width: windowWidth, height: windowHeight)
    }
```
Then replace the `.floatingWindow` branch body of `unhideFromCorner` (the `workspaceRect`/`newX`/`newY`/coerce lines) with:
```swift
            case .floatingWindow:
                if let restore = floatingRestoreRect { setAxFrame(restore.topLeftCorner, nil) }
                self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
```
If `TestWindow.new` has no default `adaptiveWeight`, pass `adaptiveWeight: 1` in the test. If `Workspace.get(byName:)`/`isVisible` are named differently, use the names `WindowVisibilityTest.swift` uses.

**Step 4:** Run `swift test --filter PreviewLayoutTest && swift test --filter WindowVisibilityTest`. Expected: PASS.

**Step 5: Commit**
```bash
git add Sources/AppBundle/layout/previewLayout.swift Sources/AppBundle/tree/Window.swift Sources/AppBundleTests/layout/PreviewLayoutTest.swift
git commit -m "feat(layout): previewLayoutRects lays out any workspace without side effects"
```

---

### Task 5 (fork): `list-tree` emits monitor-relative `window-layout-*`

**Files:**
- Modify: `Sources/AppBundle/command/impl/ListTreeCommand.swift` (window loop L47-62)
- Modify: `Sources/AppBundleTests/command/ListTreeTest.swift`
- Modify: `docs/aerospace-list-tree.adoc` (prose only, so no help regeneration needed)

**Step 1: Write the failing test** (append to `ListTreeTest`):
```swift
    @MainActor
    func testLayoutRectForHiddenWorkspaceIsMonitorRelative() async throws {
        setUpWorkspacesForTests()
        let hidden = Workspace.get(byName: "hidden-tree")
        _ = TestWindow.new(id: 11, parent: hidden.rootTilingContainer)
        _ = TestWindow.new(id: 12, parent: hidden.rootTilingContainer)

        let result = await ListTreeCommand(args: ListTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.joined().utf8)) as! [String: Any]
        let windows = (root["monitors"] as! [[String: Any]])
            .flatMap { $0["workspaces"] as! [[String: Any]] }
            .flatMap { $0["windows"] as! [[String: Any]] }
        let w11 = windows.first { ($0["window-id"] as? Int) == 11 }!
        let w12 = windows.first { ($0["window-id"] as? Int) == 12 }!
        let preview = hidden.previewLayoutRects()
        let origin = hidden.workspaceMonitor.rect.topLeftCorner
        assertEquals(w11["window-layout-x"] as? Int, Int(preview[11]!.topLeftX - origin.x))
        assertEquals(w11["window-layout-width"] as? Int, Int(preview[11]!.width))
        assertTrue((w12["window-layout-x"] as! Int) > (w11["window-layout-x"] as! Int))
        for key in ListTreeCommand.layoutRectKeys { assertTrue(w11[key] is Int) }
    }
```
Update `testListTreeOutputShapeAndCachedRect`'s last assertion to allow the new keys:
```swift
        assertEquals(Set(win.keys), Set(ListTreeCommand.windowVars.map { $0.rawValue } + ListTreeCommand.layoutRectKeys))
```
**Step 2:** Run `swift test --filter ListTreeTest`. Expected: FAIL (`layoutRectKeys` doesn't exist).

**Step 3: Implement.** In `ListTreeCommand` add:
```swift
    /// List-tree-only keys: where the window sits in its workspace's layout, relative to the top-left
    /// of the workspace's monitor. Present for hidden workspaces too, so the helper's overview can draw
    /// them to scale. Omitted when unknown (e.g. a floating window that was never shown).
    static let layoutRectKeys = ["window-layout-x", "window-layout-y", "window-layout-width", "window-layout-height"]
```
In `run`, inside `for workspace in monitorWorkspaces {` before the window loop:
```swift
                let preview = workspace.previewLayoutRects()
                let monitorOrigin = workspace.workspaceMonitor.rect.topLeftCorner
```
and replace the window `fields` switch with:
```swift
                    switch fields(.window(resolved), Self.windowVars) {
                        case .success(var f):
                            let layoutRect = preview[window.windowId]
                                ?? (window.isFloating ? (window.isHiddenInCorner ? window.floatingRestoreRect : resolved.rect) : nil)
                            if let r = layoutRect {
                                f["window-layout-x"] = .int(Int64(r.topLeftX - monitorOrigin.x))
                                f["window-layout-y"] = .int(Int64(r.topLeftY - monitorOrigin.y))
                                f["window-layout-width"] = .int(Int64(r.width))
                                f["window-layout-height"] = .int(Int64(r.height))
                            }
                            windowNodes.append(JsonTreeNode(fields: f, childrenKey: nil, children: nil))
                        case .failure(let e): return .fail(io.err(e))
                    }
```
(`resolved.rect` is `WindowWithPrefetchedTitle.rect`. If the stored property has a different name, use what format.swift:4-30 declares.)

Add to `docs/aerospace-list-tree.adoc`, after the paragraph describing window fields:
```
Each window also has `window-layout-x`, `window-layout-y`, `window-layout-width` and `window-layout-height`: where the window sits in its workspace's layout, relative to the top-left corner of the workspace's monitor. Unlike `window-x`/`window-y`, they are meaningful for windows on workspaces that aren't visible, which AeroSpace parks in a screen corner. The keys are omitted when the position is unknown.
```
**Step 4:** Run `swift test --filter ListTreeTest`, then `./test.sh`. Expected: PASS (full check: build with warnings-as-errors, tests, lint, generate, no uncommitted generated files).
**Step 5: Commit**
```bash
git add Sources/AppBundle/command/impl/ListTreeCommand.swift Sources/AppBundleTests/command/ListTreeTest.swift docs/aerospace-list-tree.adoc
git commit -m "feat(list-tree): window-layout-* rects, including hidden workspaces"
```
**Step 6: Deploy and smoke-test the fork**
```bash
make deploy
aerospace list-tree | grep -c '"window-layout-x"'
```
Expected: a count equal to the number of tiled windows. Spot-check one window on a hidden workspace: it should show a sane monitor-relative rect, not 5056/1406.

---

### Task 6 (helper): DTOs carry the layout rect

**Files:**
- Modify: `$HELPER/SharedCode/Sources/AeroSpaceDTOs/AeroTreeDTOs.swift` (`AeroWindowTreeDTO`, `flattenTreeResponse`)
- Modify: `$HELPER/SharedCode/Sources/AeroSpaceDTOs/AeroWindowDTOs.swift` (`AeroWindowDTO`)
- Modify: `$HELPER/SharedCode/Package.swift`
- Create: `$HELPER/SharedCode/Tests/AeroSpaceDTOsTests/AeroTreeDTOsTests.swift`

**Step 1: Write the failing test**
```swift
@testable import AeroSpaceDTOs
import XCTest

final class AeroTreeDTOsTests: XCTestCase {
    private func windowJSON(layout: Bool) -> Data {
        let layoutKeys = layout ? #","window-layout-x":10,"window-layout-y":20,"window-layout-width":300,"window-layout-height":400"# : ""
        return Data(("""
        {"window-id":1,"window-title":"t","window-layout":"h_tiles","window-is-fullscreen":false,
         "window-x":0,"window-y":0,"window-width":1,"window-height":1,"app-name":"a","app-pid":9\(layoutKeys)}
        """).utf8)
    }

    func testDecodesLayoutRect() throws {
        let w = try JSONDecoder().decode(AeroWindowTreeDTO.self, from: windowJSON(layout: true))
        XCTAssertEqual(w.windowLayoutX, 10)
        XCTAssertEqual(w.windowLayoutHeight, 400)
    }

    func testLayoutRectIsOptional() throws {
        let w = try JSONDecoder().decode(AeroWindowTreeDTO.self, from: windowJSON(layout: false))
        XCTAssertNil(w.windowLayoutX)
    }
}
```
Add the test target to `Package.swift`:
```swift
        .testTarget(
            name: "AeroSpaceDTOsTests",
            dependencies: ["AeroSpaceDTOs"]),
```
**Step 2:** Run `cd $HELPER/SharedCode && swift test --filter AeroTreeDTOsTests`. Expected: FAIL (`no member 'windowLayoutX'`).

**Step 3: Implement.** In `AeroWindowTreeDTO` add properties and keys:
```swift
    public let windowLayoutX: Int?
    public let windowLayoutY: Int?
    public let windowLayoutWidth: Int?
    public let windowLayoutHeight: Int?
    // CodingKeys:
        case windowLayoutX = "window-layout-x"
        case windowLayoutY = "window-layout-y"
        case windowLayoutWidth = "window-layout-width"
        case windowLayoutHeight = "window-layout-height"
```
Add the same four properties and keys to `AeroWindowDTO`. In `flattenTreeResponse`, pass them through after `windowHeight: win.windowHeight,`:
```swift
                    windowLayoutX: win.windowLayoutX,
                    windowLayoutY: win.windowLayoutY,
                    windowLayoutWidth: win.windowLayoutWidth,
                    windowLayoutHeight: win.windowLayoutHeight,
```
(Put the properties in `AeroWindowDTO` right after `windowHeight` so the memberwise-init order matches. If `AeroWindowDTO` has an explicit `init`, add the parameters there in the same position.)

**Step 4:** Run `swift test`. Expected: PASS, including the existing suites.
**Step 5: Commit**
```bash
git add SharedCode
git commit -m "feat(dto): decode list-tree window-layout-* rects"
```

---

### Task 7 (helper): `AeroOverview` pure logic: unit rects

**Files:**
- Modify: `$HELPER/SharedCode/Package.swift` (target `AeroOverview`, test target `AeroOverviewTests`, add `"AeroOverview"` to the `SharedCode` product's `targets`)
- Create: `$HELPER/SharedCode/Sources/AeroOverview/OverviewGeometry.swift`
- Create: `$HELPER/SharedCode/Tests/AeroOverviewTests/OverviewGeometryTests.swift`

**Step 1: Write the failing test**
```swift
@testable import AeroOverview
import CoreGraphics
import XCTest

final class OverviewGeometryTests: XCTestCase {
    private let monitor = CGSize(width: 2000, height: 1000)

    func testMapsLayoutRectsToUnitSpace() {
        let rects = OverviewGeometry.unitRects([
            .init(id: 1, layoutRect: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            .init(id: 2, layoutRect: CGRect(x: 1000, y: 0, width: 1000, height: 500)),
        ], monitorSize: monitor)
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(rects[2], CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testMissingRectFallsBackToEqualColumns() {
        let rects = OverviewGeometry.unitRects([
            .init(id: 1, layoutRect: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            .init(id: 2, layoutRect: nil),
        ], monitorSize: monitor)
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(rects[2], CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    func testOffMonitorRectFallsBackToColumns() {
        let rects = OverviewGeometry.unitRects([.init(id: 1, layoutRect: CGRect(x: 5000, y: 5000, width: 10, height: 10))],
                                               monitorSize: monitor)
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testPartlyOffMonitorRectIsClamped() {
        let rects = OverviewGeometry.unitRects([.init(id: 1, layoutRect: CGRect(x: 1500, y: 0, width: 1000, height: 1000))],
                                               monitorSize: monitor)
        XCTAssertEqual(rects[1], CGRect(x: 0.75, y: 0, width: 0.25, height: 1))
    }

    func testEmpty() {
        XCTAssertTrue(OverviewGeometry.unitRects([], monitorSize: monitor).isEmpty)
    }
}
```
**Step 2:** Run `swift test --filter OverviewGeometryTests`. Expected: FAIL (no module `AeroOverview`).

**Step 3: Implement.** `Package.swift` additions:
```swift
        .target(
            name: "AeroOverview"
        ),
        .testTarget(
            name: "AeroOverviewTests",
            dependencies: ["AeroOverview"]),
```
and the product line becomes `targets: ["AeroSocket", "AeroSpaceDTOs", "AeroProfile", "AeroOverview"]`.

`OverviewGeometry.swift`:
```swift
import CoreGraphics

public struct OverviewWindowGeometry: Equatable {
    public let id: Int
    /// Monitor-relative layout rect from list-tree `window-layout-*`, nil when unknown
    public let layoutRect: CGRect?

    public init(id: Int, layoutRect: CGRect?) {
        self.id = id
        self.layoutRect = layoutRect
    }
}

public enum OverviewGeometry {
    /// Each window's rect in unit space (0...1 on both axes) of its workspace card.
    /// If any window has no usable rect, every window is drawn as an equal column instead, so a
    /// card is either to scale or schematic, never a mix with overlapping guesses.
    public static func unitRects(_ windows: [OverviewWindowGeometry], monitorSize: CGSize) -> [Int: CGRect] {
        guard monitorSize.width > 0, monitorSize.height > 0 else { return columns(windows) }
        let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)
        var result: [Int: CGRect] = [:]
        for window in windows {
            guard let r = window.layoutRect else { return columns(windows) }
            let unit = CGRect(x: r.minX / monitorSize.width, y: r.minY / monitorSize.height,
                              width: r.width / monitorSize.width, height: r.height / monitorSize.height)
                .intersection(unitSquare)
            guard !unit.isNull, unit.width > 0, unit.height > 0 else { return columns(windows) }
            result[window.id] = unit
        }
        return result
    }

    private static func columns(_ windows: [OverviewWindowGeometry]) -> [Int: CGRect] {
        let width = 1 / CGFloat(max(windows.count, 1))
        var result: [Int: CGRect] = [:]
        for (i, window) in windows.enumerated() {
            result[window.id] = CGRect(x: CGFloat(i) * width, y: 0, width: width, height: 1)
        }
        return result
    }
}
```
**Step 4:** Run `swift test --filter OverviewGeometryTests`. Expected: PASS.
**Step 5: Commit**
```bash
git add SharedCode
git commit -m "feat(overview): AeroOverview module with unit-rect mapping"
```

---

### Task 8 (helper): `OverviewGrid`: card slot frames

**Files:**
- Create: `$HELPER/SharedCode/Sources/AeroOverview/OverviewGrid.swift`
- Create: `$HELPER/SharedCode/Tests/AeroOverviewTests/OverviewGridTests.swift`

**Step 1: Write the failing test**
```swift
@testable import AeroOverview
import CoreGraphics
import XCTest

final class OverviewGridTests: XCTestCase {
    func testFourSquareCardsMakeTwoByTwo() {
        let frames = OverviewGrid.slotFrames(count: 4, in: CGSize(width: 1000, height: 1000),
                                             contentAspect: 1, labelHeight: 0, spacing: 0)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 500, height: 500), CGRect(x: 500, y: 0, width: 500, height: 500),
            CGRect(x: 0, y: 500, width: 500, height: 500), CGRect(x: 500, y: 500, width: 500, height: 500),
        ])
    }

    func testFramesStayInBoundsAndDontOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let frames = OverviewGrid.slotFrames(count: 7, in: bounds.size, contentAspect: 32.0 / 9, labelHeight: 22, spacing: 24)
        XCTAssertEqual(frames.count, 7)
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(bounds.contains(a), "\(a) out of bounds")
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)") }
        }
    }

    func testSlotHeightIsContentPlusLabel() {
        let f = OverviewGrid.slotFrames(count: 1, in: CGSize(width: 1600, height: 1000),
                                        contentAspect: 2, labelHeight: 20, spacing: 0)[0]
        XCTAssertEqual(f.height, f.width / 2 + 20, accuracy: 0.001)
    }

    func testZeroCount() {
        XCTAssertEqual(OverviewGrid.slotFrames(count: 0, in: CGSize(width: 100, height: 100),
                                               contentAspect: 1, labelHeight: 0, spacing: 0), [])
    }
}
```
**Step 2:** Run `swift test --filter OverviewGridTests`. Expected: FAIL.
**Step 3: Implement** `OverviewGrid.swift`:
```swift
import CoreGraphics

public enum OverviewGrid {
    /// Row-major slot frames (top-left origin) for `count` equal cards, centered in `bounds`.
    /// Picks the column count that makes cards largest. A slot is the card content (with
    /// `contentAspect`, width / height) plus a `labelHeight` title strip above it.
    public static func slotFrames(count: Int, in bounds: CGSize, contentAspect: CGFloat,
                                  labelHeight: CGFloat, spacing: CGFloat) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0, contentAspect > 0 else { return [] }
        var bestColumns = 1
        var bestWidth: CGFloat = 0
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let byWidth = (bounds.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            let byHeight = ((bounds.height - spacing * CGFloat(rows + 1)) / CGFloat(rows) - labelHeight) * contentAspect
            let width = min(byWidth, byHeight)
            if width > bestWidth {
                bestWidth = width
                bestColumns = columns
            }
        }
        let columns = bestColumns
        let rows = (count + columns - 1) / columns
        let slotWidth = max(bestWidth, 0)
        let slotHeight = slotWidth / contentAspect + labelHeight
        let gridWidth = CGFloat(columns) * slotWidth + CGFloat(columns - 1) * spacing
        let gridHeight = CGFloat(rows) * slotHeight + CGFloat(rows - 1) * spacing
        let originX = (bounds.width - gridWidth) / 2
        let originY = (bounds.height - gridHeight) / 2
        return (0..<count).map { i in
            CGRect(x: originX + CGFloat(i % columns) * (slotWidth + spacing),
                   y: originY + CGFloat(i / columns) * (slotHeight + spacing),
                   width: slotWidth, height: slotHeight)
        }
    }
}
```
**Step 4:** Run `swift test --filter OverviewGridTests`. Expected: PASS.
**Step 5: Commit**: `git add SharedCode && git commit -m "feat(overview): card grid layout"`

---

### Task 9 (helper): `OverviewSession`: peek/pin state machine

**Files:**
- Create: `$HELPER/SharedCode/Sources/AeroOverview/OverviewSession.swift`
- Create: `$HELPER/SharedCode/Tests/AeroOverviewTests/OverviewSessionTests.swift`

**Step 1: Write the failing test**
```swift
@testable import AeroOverview
import XCTest

final class OverviewSessionTests: XCTestCase {
    func testPeekShowsWhileHeldAndHidesOnRelease() {
        var s = OverviewSession()
        s.controlHeld();     XCTAssertEqual(s.phase, .peeking)
        s.controlReleased(); XCTAssertEqual(s.phase, .hidden)
    }

    func testClickPinsSoReleaseKeepsItOpen() {
        var s = OverviewSession()
        s.controlHeld(); s.clicked(); s.controlReleased()
        XCTAssertEqual(s.phase, .pinned)
        s.dismiss()
        XCTAssertEqual(s.phase, .hidden)
    }

    func testClickWhileHiddenDoesNothing() {
        var s = OverviewSession()
        s.clicked()
        XCTAssertEqual(s.phase, .hidden)
    }

    func testHoldingAgainWhilePinnedStaysPinned() {
        var s = OverviewSession()
        s.controlHeld(); s.clicked(); s.controlReleased(); s.controlHeld()
        XCTAssertEqual(s.phase, .pinned)
    }
}
```
**Step 2:** Run `swift test --filter OverviewSessionTests`. Expected: FAIL.
**Step 3: Implement** `OverviewSession.swift`:
```swift
/// Hold Ctrl to peek, click to pin. Esc, a background click or a finished action dismisses.
public struct OverviewSession: Equatable {
    public enum Phase: Equatable { case hidden, peeking, pinned }

    public private(set) var phase: Phase = .hidden

    public init() {}

    public mutating func controlHeld() { if phase == .hidden { phase = .peeking } }
    public mutating func controlReleased() { if phase == .peeking { phase = .hidden } }
    public mutating func clicked() { if phase == .peeking { phase = .pinned } }
    public mutating func dismiss() { phase = .hidden }
}
```
**Step 4:** Run `swift test`. Expected: all SharedCode tests PASS.
**Step 5: Commit**: `git add SharedCode && git commit -m "feat(overview): peek/pin session state machine"`

---

### Task 10 (helper): App model carries the layout rect

**Files:**
- Modify: `$HELPER/App/Models/WindowModel.swift`
- Modify: `$HELPER/App/AeroSpace/AeroStateStore.swift:207-215`

**Step 1:** In `WindowModel`, add `let layoutRect: CGRect?` after `workspaceIdentifier`, an init parameter `layoutRect: CGRect? = nil` (assigned in init), and `lhs.layoutRect == rhs.layoutRect &&` in `==`. The store only republishes changed values, so `==` must include it or geometry updates are lost.
**Step 2:** In `AeroStateStore` where `WindowModel(` is built (line 207), add:
```swift
                layoutRect: {
                    guard let x = windowInfo.windowLayoutX, let y = windowInfo.windowLayoutY,
                          let w = windowInfo.windowLayoutWidth, let h = windowInfo.windowLayoutHeight else { return nil }
                    return CGRect(x: x, y: y, width: w, height: h)
                }()
```
**Step 3:** Run `make build`. Expected: build succeeds.
**Step 4: Commit**: `git add App && git commit -m "feat(model): WindowModel.layoutRect from list-tree"`

---

### Task 11 (helper): Shared move/focus actions (DRY before the second caller)

**Files:**
- Modify: `$HELPER/App/AeroSpace/AeroStateStore.swift` (new `// MARK: - User Actions` after the optimistic updates)
- Modify: `$HELPER/App/Views/WorkspaceView.swift` (`handleFocusTap` L311-326, `handleWindowDrop` L328-376; add an `NSItemProvider` extension next to `TransferableWindowID`)

**Step 1:** Add to `AeroStateStore`:
```swift
    // MARK: - User Actions (optimistic update, then AeroSpace; refresh on failure)

    func focusWorkspace(_ workspace: WorkspaceModel) {
        _ = applyFocusWorkspaceOptimisticUpdate(identifier: workspace.identifier, monitorId: workspace.monitorId)
        Task {
            do { try await aeroSpaceActions.focusWorkspace(identifier: workspace.identifier) }
            catch {
                handleActionError(error, context: "focus workspace \(workspace.identifier)")
                await performRefresh()
            }
        }
    }

    func focusWindow(_ windowId: Int) {
        _ = applyFocusChangedOptimisticUpdate(windowId: windowId)
        Task {
            do { try await aeroSpaceActions.focusWindow(windowId: windowId) }
            catch {
                handleActionError(error, context: "focus window \(windowId)")
                await performRefresh()
            }
        }
    }

    /// Refreshes after success too: list-tree then reports the window's new layout rect and its
    /// old workspace's re-flowed layout.
    func moveWindow(_ windowId: Int, toWorkspace identifier: String) {
        if windows.first(where: { $0.windowId == windowId })?.workspaceIdentifier == identifier { return }
        _ = applyMoveWindowOptimisticUpdate(windowId: windowId, targetWorkspaceIdentifier: identifier)
        Task {
            do { try await aeroSpaceActions.moveWindowToWorkspace(windowId: windowId, workspaceIdentifier: identifier) }
            catch { handleActionError(error, context: "move window \(windowId) to \(identifier)") }
            await performRefresh()
        }
    }
```
**Step 2:** In `WorkspaceView.swift`, next to `TransferableWindowID`, add:
```swift
extension NSItemProvider {
    /// Reads a dragged `TransferableWindowID`. Calls back on the main actor; nil if unreadable.
    func loadAeroSpaceWindowId(_ completion: @escaping @MainActor (Int?) -> Void) {
        _ = loadDataRepresentation(forTypeIdentifier: UTType.aeroSpaceWindow.identifier) { data, _ in
            let id = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(id) } }
        }
    }
}
```
Replace `handleFocusTap` and `handleWindowDrop` bodies:
```swift
    private func handleFocusTap() {
        log.debug("Tapped workspace \(workspace.displayName) (\(workspace.identifier))", category: logCategory)
        aeroSpaceUIManager.focusWorkspace(workspace)
    }

    private func handleWindowDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadAeroSpaceWindowId { id in
            isDropTargeted = false
            guard let id else {
                aeroSpaceUIManager.lastErrorMessage = "Dropped window data could not be read."
                return
            }
            aeroSpaceUIManager.moveWindow(id, toWorkspace: workspace.identifier)
        }
        return true
    }
```
**Step 3:** Run `grep -rn "focusWindow(windowId:" $HELPER/App/Views`. Any view that does "optimistic focus + `Task { try await AeroSpaceActions.shared.focusWindow` + error refresh" should call `aeroSpaceUIManager.focusWindow(id)` instead. Delete the duplicated block.
**Step 4:** Run `make build`. Expected: success. Then `make deploy` and check by hand that dragging a window icon between workspaces in the left panel still moves it, and clicking a workspace still switches.
**Step 5: Commit**: `git add App && git commit -m "refactor: shared move/focus actions on AeroStateStore"`

---

### Task 12 (helper): Overview panel + controller

**Files:**
- Create: `$HELPER/App/Config/OverviewPanelController.swift`
- Modify: `$HELPER/App/aerospace_helper.xcodeproj/project.pbxproj`: add `OverviewPanelController.swift,` to the `Exceptions for "Config" folder` `membershipExceptions` list (around line 88, after `AccordionStripPanelController.swift,`). Synchronized groups treat that list as the include list (precedent: commit `068ca50`).

**Step 1: Implement**
```swift
import SwiftUI
import Cocoa
import AeroOverview

private let log = FileLogger.shared
private let logCategory = "OverviewPanelController"

/// Full-screen overview panel. Becomes key without activating the app, so it can take Esc
/// once pinned while the app you came from stays active underneath.
final class OverviewPanel: NSPanel {
    var onMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }
}

/// Hold Ctrl to peek; any click pins it; Esc, a background click or an action dismisses.
@MainActor
final class OverviewPanelController {
    private let store: AeroStateStore
    private let panel: OverviewPanel
    private var session = OverviewSession()
    private var escMonitor: Any?

    init(store: AeroStateStore) {
        self.store = store
        panel = OverviewPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isMovable = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView:
            OverviewView(onDismiss: { [weak self] in self?.dismiss() })
                .environmentObject(store)
                .environmentObject(FaviconService.shared)
        )
        panel.onMouseDown = { [weak self] in
            guard let self else { return }
            self.session.clicked()
            self.sync()
        }
    }

    func controlHeld() {
        let wasHidden = session.phase == .hidden
        session.controlHeld()
        if wasHidden { store.triggerRefresh() }
        sync()
    }

    func controlReleased() {
        session.controlReleased()
        sync()
    }

    func dismiss() {
        session.dismiss()
        sync()
    }

    private func sync() {
        switch session.phase {
            case .hidden:
                removeEscMonitor()
                guard panel.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = ConstantViewSettings.animationMedium
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.session.phase == .hidden else { return }   // re-shown mid-fade
                        self.panel.orderOut(nil)
                    }
                })
            case .peeking:
                show()
            case .pinned:
                show()
                panel.makeKey()
                installEscMonitor()
        }
    }

    private func show() {
        if let screen = NSScreen.main, panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ConstantViewSettings.animationMedium
            panel.animator().alphaValue = 1
        }
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}
```
**Step 2:** Run `make build`. Expected: fails only on the missing `OverviewView` (Task 13). Go straight on and commit after Task 13 builds.

---

### Task 13 (helper): Overview view

**Files:**
- Create: `$HELPER/App/Views/OverviewView.swift`
- Modify: `project.pbxproj`: add `OverviewView.swift,` to the `Exceptions for "Views" folder` list (around line 75)

**Step 1: Implement**
```swift
import SwiftUI
import AeroOverview

private let labelHeight: CGFloat = 22
private let cardSpacing: CGFloat = 28

/// Mission-Control-style grid: every workspace as a card with its windows drawn to scale.
struct OverviewView: View {
    @EnvironmentObject var store: AeroStateStore
    let onDismiss: () -> Void

    /// Workspaces worth a card: anything with windows, anything visible, and persistent/named
    /// ones (so you can drop onto an empty one). Dot workspaces (.scratchpad etc.) are skipped.
    /// Main monitor first, then the store's order.
    private var cards: [WorkspaceModel] {
        let occupied = Set(store.windows.map(\.workspaceIdentifier))
        let mainIds = Set(store.monitors.filter(\.isMain).map(\.aeroSpaceId))
        return store.workspaces
            .filter { !$0.isDotWorkspace && (occupied.contains($0.identifier) || $0.isVisible || !$0.hideIfEmpty) }
            .enumerated()
            .sorted { (mainIds.contains($0.element.monitorId) ? 0 : 1, $0.offset) < (mainIds.contains($1.element.monitorId) ? 0 : 1, $1.offset) }
            .map(\.element)
    }

    private var mainAspect: CGFloat {
        guard let main = store.monitors.first(where: \.isMain), main.width > 0, main.height > 0 else { return 16.0 / 9 }
        return CGFloat(main.width) / CGFloat(main.height)
    }

    var body: some View {
        GeometryReader { geo in
            let cards = self.cards
            let frames = OverviewGrid.slotFrames(count: cards.count, in: geo.size, contentAspect: mainAspect,
                                                 labelHeight: labelHeight, spacing: cardSpacing)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                ForEach(Array(zip(cards, frames)), id: \.0.id) { workspace, frame in
                    OverviewCardView(workspace: workspace, onDismiss: onDismiss)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct OverviewCardView: View {
    @EnvironmentObject var store: AeroStateStore
    @EnvironmentObject var faviconService: FaviconService
    let workspace: WorkspaceModel
    let onDismiss: () -> Void
    @State private var isDropTargeted = false

    private var windows: [WindowModel] {
        // Tiled under floating, so floating windows draw on top
        store.windows
            .filter { $0.workspaceIdentifier == workspace.identifier }
            .sorted { ($0.isFloating ? 1 : 0, $0.treeIndex) < ($1.isFloating ? 1 : 0, $1.treeIndex) }
    }

    private var monitorSize: CGSize {
        guard let m = store.monitors.first(where: { $0.aeroSpaceId == workspace.monitorId }), m.width > 0, m.height > 0
        else { return CGSize(width: 16, height: 9) }
        return CGSize(width: m.width, height: m.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(workspace.displayName)
                .font(.system(size: 13, weight: workspace.isVisible ? .semibold : .regular))
                .foregroundStyle(workspace.isVisible ? Color.accentColor : .white)
                .frame(height: labelHeight)
            content
                .aspectRatio(monitorSize.width / monitorSize.height, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        GeometryReader { geo in
            let windows = self.windows
            let unit = OverviewGeometry.unitRects(
                windows.map { OverviewWindowGeometry(id: $0.windowId, layoutRect: $0.layoutRect) },
                monitorSize: monitorSize)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                        isDropTargeted ? Color.accentColor : (workspace.isVisible ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.15)),
                        lineWidth: isDropTargeted ? 3 : 1.5))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.focusWorkspace(workspace)
                        onDismiss()
                    }
                ForEach(windows) { window in
                    if let r = unit[window.windowId] {
                        let frame = CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                           width: r.width * geo.size.width, height: r.height * geo.size.height)
                            .insetBy(dx: 3, dy: 3)
                        OverviewWindowBox(window: window, icon: faviconService.favicon(for: window.windowId) ?? store.apps.first { $0.pid == window.pid }?.icon,
                                          isFocused: window.windowId == store.focusedWindowId)
                            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                            .position(x: frame.midX, y: frame.midY)
                            .onTapGesture {
                                store.focusWindow(window.windowId)
                                onDismiss()
                            }
                            .draggable(TransferableWindowID(id: String(window.windowId)))
                    }
                }
            }
        }
        // Only the window type: TransferableWindowID also exports .plainText, which MonitorView
        // reads as a workspace name.
        .onDrop(of: [UTType.aeroSpaceWindow], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadAeroSpaceWindowId { id in
                guard let id else { return }
                store.moveWindow(id, toWorkspace: workspace.identifier)
            }
            return true
        }
    }
}

struct OverviewWindowBox: View {
    let window: WindowModel
    let icon: NSImage?
    let isFocused: Bool

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 4) {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                        .frame(width: min(40, geo.size.width * 0.5), height: min(40, geo.size.height * 0.5))
                }
                if geo.size.height > 50 {
                    Text(window.title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary).padding(.horizontal, 6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(window.isFloating ? 0.16 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: isFocused ? 2 : 1))
        .contentShape(Rectangle())
    }
}
```
(`store.apps` is `[AppModel]`. If it is keyed differently, use the same `pid` lookup `MainOverlay.swift:49` builds.)

**Step 2:** Run `make build`. Expected: success.
**Step 3: Commit** (Tasks 12 and 13 together):
```bash
git add App
git commit -m "feat(overview): full-screen workspace overview panel and view"
```

---

### Task 14 (helper): Setting + Ctrl wiring

**Files:**
- Modify: `$HELPER/App/AeroSpace/AeroStateStore.swift` (setting next to `hoverExpand`, ~L46-53; init ~L70)
- Modify: `$HELPER/App/Config/StatusBarController.swift` (Display submenu ~L55-74, `menuNeedsUpdate` ~L87-91, a new action)
- Modify: `$HELPER/App/AppDelegate.swift` (controllers ~L68-76, Control handlers ~L91-113)

**Step 1:** In `AeroStateStore` add:
```swift
    /// Ctrl-hold opens the full-screen overview instead of expanding the side panel
    @Published var ctrlHoldOpensOverview: Bool = false {
        didSet {
            if oldValue != ctrlHoldOpensOverview {
                UserDefaults.standard.set(ctrlHoldOpensOverview, forKey: "ctrlHoldOpensOverview_v1")
            }
        }
    }
```
and load it in `init`: `self.ctrlHoldOpensOverview = UserDefaults.standard.bool(forKey: "ctrlHoldOpensOverview_v1")`.

**Step 2:** In `StatusBarController`, add `private weak var overviewItem: NSMenuItem?`. In the Display submenu after Hover Expand:
```swift
        let overviewItem = NSMenuItem(title: "Ctrl-Hold Opens Overview", action: #selector(toggleOverviewAction), keyEquivalent: "")
        overviewItem.target = self
        displayMenu.addItem(overviewItem)
        self.overviewItem = overviewItem
```
In `menuNeedsUpdate`: `overviewItem?.state = appStateService.ctrlHoldOpensOverview ? .on : .off`. Add:
```swift
    @objc private func toggleOverviewAction() {
        appStateService.ctrlHoldOpensOverview.toggle()
        log.info("Toggled Ctrl-Hold Opens Overview to: \(appStateService.ctrlHoldOpensOverview)", category: logCategory)
    }
```
**Step 3:** In `AppDelegate`, add `var overviewController: OverviewPanelController?` and create it next to the accordion strip controller: `overviewController = OverviewPanelController(store: appStateService)`. Put the overview branch at the top of both Control handlers:
```swift
        keyMonitoringService?.onControlHeld = { [weak self] in
            guard let self else { return }
            if self.appStateService.ctrlHoldOpensOverview {
                self.overviewController?.controlHeld()
                return
            }
            guard let pc = self.panelController else { return }
            // ... existing side-panel body unchanged ...
        }
        keyMonitoringService?.onControlReleased = { [weak self] in
            guard let self else { return }
            // Always forward: a pinned overview ignores it, and a peek opened before the setting
            // was switched off still closes
            self.overviewController?.controlReleased()
            if self.appStateService.ctrlHoldOpensOverview { return }
            guard let pc = self.panelController else { return }
            // ... existing side-panel body unchanged ...
        }
```
**Step 4:** Run `make check`. Expected: build + all SharedCode tests pass.
**Step 5: Commit**: `git add App && git commit -m "feat(overview): menu setting routes Ctrl-hold to the overview"`

---

### Task 15: Deploy, verify end-to-end, PRs

**Step 1:** Make sure the fork from Task 5 is deployed (`aerospace list-tree | grep -c window-layout-x` > 0), then `cd $HELPER && make deploy`.
**Step 2:** Turn on **Display → Ctrl-Hold Opens Overview** in the helper menu and check by hand:
1. Hold Ctrl (built-in keyboard): the overview fades in within about 50ms. Release: it fades out.
2. Quick Ctrl tap and `ctrl-c` in a terminal: no overview.
3. Hidden workspaces' cards show their windows **to scale** (not stacked in a corner). The visible workspace's card matches the screen.
4. Hold Ctrl and click anything: it stays open after release (pinned). Esc closes it. Clicking the dim background closes it.
5. Pinned: drag a window box to another card. It moves at once (optimistic) and settles into the target's real layout within a second. The source card re-flows. `aerospace list-windows --workspace <target>` confirms it.
6. Click a window box: that window focuses (switching workspace if needed) and the overview closes. Click a card's empty area: switches workspace and closes.
7. Turn the setting off: Ctrl-hold expands the side panel exactly as before.
8. `grep -E "OverviewPanelController|Action Error" ~/Library/Logs/aerospace-helper/helper.log | tail`: no errors.

**Step 3:** Fork PR (target `MintCollector/AeroSpace`):
```bash
git push -u origin HEAD
gh pr create --repo MintCollector/AeroSpace --title "list-tree: window-layout-* rects via side-effect-free layout preview" --body "..."
```
Helper PR:
```bash
cd $HELPER && git push -u origin feature/workspace-overview
gh pr create --repo MintCollector/aero-helper --title "Mission-Control-style workspace overview (Ctrl-hold)" --body "..."
```
PR bodies summarize the Executive Summary and end with the required Claude Code attribution footer.

**Step 4:** Add one row to `$HELPER/CLAUDE.md` describing the overview (Ctrl-hold, pin/Esc, setting) and commit it to the feature branch.

---

## Executive Summary

**What exists today:**
- Ctrl-hold (`App/Config/KeyMonitoringService.swift`) expands the left-side panel (`MainOverlay` via `forceExpand`). It shows a list of icons per workspace with no spatial layout.
- Drag a window icon onto a workspace to move it (`WorkspaceView.handleWindowDrop`). This logic is duplicated inline per view.
- The fork's `list-tree` reports real rects only for visible workspaces. `hideInCorner` clears `lastAppliedLayoutPhysicalRect`, so hidden-workspace windows report their corner-parked position (e.g. `x=5056, y=1406`).
- The helper's `WindowModel` drops all geometry.

**What we're moving to:**
- Fork: `Workspace.previewLayoutRects()` computes any workspace's tile/accordion layout from the tree using the **same** pure `tileFrames`/`accordionFrames` the live pass now uses, with no AX calls or weight mutation. `list-tree` adds monitor-relative `window-layout-x/y/width/height` for every window. Floating windows on hidden workspaces use the same restore math as `unhideFromCorner`.
- Helper: a new `AeroOverview` SharedCode module (unit rects, card grid, peek/pin session), fully unit-tested. A full-screen `OverviewPanelController` + `OverviewView` draws every workspace to scale. Drag-to-move, click-to-focus and click-to-switch go through new shared `AeroStateStore` actions.
- A menu toggle, **Ctrl-Hold Opens Overview**, picks the overview or the existing side panel.

**Why:**
- The user wants a Mission-Control-like way to see and rearrange everything. The side panel can't show layout, and no other AeroSpace tool shows hidden workspaces to scale.
- Computing the preview instead of caching it means cards are correct right after the overview moves windows, which is the core interaction.
- Pure logic in SharedCode gives the helper its first tests for UI behavior. Keeping the side panel behind a setting lets the user compare before retiring anything.
