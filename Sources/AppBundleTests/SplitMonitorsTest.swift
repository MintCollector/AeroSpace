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

    func testActiveWorkspaceOfAColumnThatIsGone() {
        splitTestMonitor()
        // Captured before the merge, like the monitors of a layout pass that awaits while the split toggles
        let right = testColumns.right
        splitMonitorsEnabled = false
        gcMonitors()
        // The workspace of the monitor that is there now, the whole screen, instead of recursing forever
        assertEquals(right.activeWorkspace, monitorInfos.singleOrNil()!.activeWorkspace)
    }

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

    private func runCommand(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
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
