@testable import AppBundle
import Common
import XCTest

@MainActor
final class FloatingArrivalTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspacesNeedingFloatingRaise = []
    }

    /// Workspace a: a floating window, then a tiled one focused after it
    private func setUpWorkspaceA() async -> Workspace {
        let a = Workspace.get(byName: "a")
        let float = TestWindow.new(id: 1, parent: a.floatingWindowsContainer)
        let tiled = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        assertTrue(float.focusWindow())
        assertTrue(tiled.focusWindow())
        await checkOnFocusChangedCallbacks_nonCancellable() // A refresh session runs after every switch
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        await checkOnFocusChangedCallbacks_nonCancellable()
        workspacesNeedingFloatingRaise = []
        return a
    }

    func testArrivingFocusesTheFloatingWindow() async {
        let a = await setUpWorkspaceA()

        assertTrue(a.focusWorkspace())
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testWorkspaceAlreadyOnScreenKeepsItsFocusedWindow() async {
        let a = await setUpWorkspaceA()
        recordVisibleWorkspaces([mainMonitorInfo.rect.topLeftCorner: "b", CGPoint(x: 1920, y: 0): "a"]) // a on another monitor

        assertTrue(a.focusWorkspace())
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testRaiseOnlyOnArrival() async {
        let a = await setUpWorkspaceA()
        assertTrue(a.focusWorkspace())
        await checkOnFocusChangedCallbacks_nonCancellable()
        assertEquals(workspacesNeedingFloatingRaise, ["a"])

        workspacesNeedingFloatingRaise = []
        recordVisibleWorkspaces([mainMonitorInfo.rect.topLeftCorner: "a", CGPoint(x: 1920, y: 0): "b"]) // b on another monitor
        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        await checkOnFocusChangedCallbacks_nonCancellable()
        assertEquals(workspacesNeedingFloatingRaise, [])
    }

    func testDotWorkspaceStopDoesntTakeTheMonitorOffScreen() {
        let point = mainMonitorInfo.rect.topLeftCorner
        recordVisibleWorkspaces([point: "a"])
        recordVisibleWorkspaces([point: ".scratchpad"]) // aero-helper takes a window out of it

        assertEquals(workspacesOnScreen, ["a"])
    }
}
