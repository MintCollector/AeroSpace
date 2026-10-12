@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceBackAndForthCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("workspace-back-and-forth", WorkspaceBackAndForthCmdArgs(rawArgs: []))
        testParseSingleCommandSucc("workspace-back-and-forth --monitor 2", WorkspaceBackAndForthCmdArgs(rawArgs: []).copy(\.monitor, .id(2)))
        testParseSingleCommandSucc("workspace-back-and-forth --monitor focused", WorkspaceBackAndForthCmdArgs(rawArgs: []).copy(\.monitor, .focused))
        testParseSingleCommandSucc("workspace-back-and-forth --monitor mouse", WorkspaceBackAndForthCmdArgs(rawArgs: []).copy(\.monitor, .mouse))
        testParseSingleCommandSucc("workspace-back-and-forth --monitor main", WorkspaceBackAndForthCmdArgs(rawArgs: []).copy(\.monitor, .main))
        testParseSingleCommandSucc("workspace-back-and-forth --monitor secondary", WorkspaceBackAndForthCmdArgs(rawArgs: []).copy(\.monitor, .secondary))
        assertNotNil(parseCommand("workspace-back-and-forth --monitor all").errorOrNil)
        assertNotNil(parseCommand("workspace-back-and-forth --monitor 0").errorOrNil)
        assertNotNil(parseCommand("workspace-back-and-forth --monitor").errorOrNil)
    }

    func testGoesBackAndForth() async {
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        trackVisibleWorkspaces() // A refresh session runs after every switch
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        trackVisibleWorkspaces()

        assertEquals(await runCommand("workspace-back-and-forth").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "a")
        trackVisibleWorkspaces()

        assertEquals(await runCommand("workspace-back-and-forth").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "b")
    }

    func testMonitorFlag() async {
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        trackVisibleWorkspaces()
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        trackVisibleWorkspaces()

        assertEquals(await runCommand("workspace-back-and-forth --monitor 1").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "a")
        trackVisibleWorkspaces()

        assertEquals(await runCommand("workspace-back-and-forth --monitor main").exitCode.rawValue, 0) // The test monitor is the main one
        assertEquals(focus.workspace.name, "b")

        let noSuchId = await runCommand("workspace-back-and-forth --monitor 2")
        assertEquals(noSuchId.exitCode.rawValue, 2)
        assertEquals(noSuchId.stderr, ["Invalid monitor ID: 2"])

        let noSecondary = await runCommand("workspace-back-and-forth --monitor secondary")
        assertEquals(noSecondary.exitCode.rawValue, 2)
        assertEquals(noSecondary.stderr, ["There is no secondary monitor: it takes exactly two monitors"])
        assertEquals(focus.workspace.name, "b")
    }

    func testNothingToGoBackTo_fails() async {
        assertTrue(Workspace.get(byName: "a").focusWorkspace())

        let result = await runCommand("workspace-back-and-forth")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No workspace to go back to on monitor 'Test Monitor'"])
        assertEquals(focus.workspace.name, "a")
    }

    func testSwitchEarlierInTheSameSequenceCounts() async {
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        trackVisibleWorkspaces()
        assertTrue(Workspace.get(byName: "b").focusWorkspace()) // No refresh session since

        assertEquals(await runCommand("workspace-back-and-forth").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "a")
    }

    func testSkipsDotWorkspaces() async {
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        trackVisibleWorkspaces()
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        trackVisibleWorkspaces()
        // aero-helper takes a window out of .scratchpad: it's on screen for a moment, then b is back
        assertTrue(Workspace.get(byName: ".scratchpad").focusWorkspace())
        trackVisibleWorkspaces()
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        trackVisibleWorkspaces()

        assertEquals(await runCommand("workspace-back-and-forth").exitCode.rawValue, 0)
        assertEquals(focus.workspace.name, "a")
    }

    func testHistoryIsPerMonitor() {
        let left = CGPoint(x: 0, y: 0)
        let right = CGPoint(x: 1920, y: 0)
        recordVisibleWorkspaces([left: "a", right: "x"])
        recordVisibleWorkspaces([left: "b", right: "x"])
        recordVisibleWorkspaces([left: "b", right: "y"])
        recordVisibleWorkspaces([left: "b", right: "y"]) // Focus moving between the monitors changes nothing
        assertEquals(monitorWorkspaceHistory, [left: ["a"], right: ["x"]])

        recordVisibleWorkspaces([left: "a", right: "y"])
        assertEquals(monitorWorkspaceHistory, [left: ["b", "a"], right: ["x"]])
    }

    func testSkipsWorkspaceOnAScreen() {
        let right = TestMonitor(x: 1920)
        recordVisibleWorkspaces([right.rect.topLeftCorner: "b"])
        recordVisibleWorkspaces([right.rect.topLeftCorner: "a"])
        recordVisibleWorkspaces([right.rect.topLeftCorner: "c"])
        assertTrue(Workspace.get(byName: "a").focusWorkspace()) // Now on the other monitor

        assertEquals(right.backAndForthWorkspace?.name, "b")
    }

    func testSkipsWorkspaceForceAssignedToAnotherMonitor() {
        config.workspaceToMonitorForceAssignment = ["pinned": [.main]]
        let right = TestMonitor(x: 1920)
        recordVisibleWorkspaces([right.rect.topLeftCorner: "free"])
        recordVisibleWorkspaces([right.rect.topLeftCorner: "pinned"])
        recordVisibleWorkspaces([right.rect.topLeftCorner: "c"])

        assertEquals(right.backAndForthWorkspace?.name, "free")
    }

    private func runCommand(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}

private struct TestMonitor: MonitorInfo {
    let rect: Rect
    init(x: CGFloat) { rect = Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080) }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let monitorAppKitNsScreenScreensId = 2
    let name = "Right monitor"
    let isMain = false
}
