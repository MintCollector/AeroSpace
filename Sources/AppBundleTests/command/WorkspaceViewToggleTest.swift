@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceViewToggleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - Basic state

    func testViewToggledStatesEmptyByDefault() {
        let ws = Workspace.get(byName: "1")
        assertEquals(ws.viewToggledStates.count, 0)
    }

    // MARK: - Toggle ON

    func testToggleOnMergesTilingChildren() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")

        assertEquals(ws1.rootTilingContainer.children.count, 2)
        assertEquals(ws2.rootTilingContainer.children.count, 0)
        assertEquals(ws1.viewToggledStates.count, 1)
        assertEquals(ws1.viewToggledStates[0].donorWorkspaceName, "2")
    }

    // MARK: - Ordering

    func testToggleOnAppendsWhenDonorGreaterThanHost() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")

        let children = ws1.rootTilingContainer.children
        assertEquals(children.count, 2)
        assertEquals((children[0] as! Window).windowId, UInt32(1))
        assertEquals((children[1] as! Window).windowId, UInt32(2))
    }

    func testToggleOnPrependsWhenDonorLessThanHost() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }
        ws2.rootTilingContainer.apply {
            _ = TestWindow.new(id: 2, parent: $0).focusWindow()
        }
        check(ws2.focusWorkspace())

        performViewToggle(hostWorkspace: ws2, donorWorkspaceName: "1")

        let children = ws2.rootTilingContainer.children
        assertEquals(children.count, 2)
        assertEquals((children[0] as! Window).windowId, UInt32(1))
        assertEquals((children[1] as! Window).windowId, UInt32(2))
    }

    // MARK: - Toggle OFF

    func testToggleOffRestoresDonorWindows() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")
        assertEquals(ws1.rootTilingContainer.children.count, 2)

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")

        assertEquals(ws1.rootTilingContainer.children.count, 1)
        assertEquals(ws2.rootTilingContainer.children.count, 1)
        assertEquals((ws1.rootTilingContainer.children[0] as! Window).windowId, UInt32(1))
        assertEquals((ws2.rootTilingContainer.children[0] as! Window).windowId, UInt32(2))
        assertEquals(ws1.viewToggledStates.count, 0)
    }

    func testDissolveViewTogglesRestoresAllDonors() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        let ws3 = Workspace.get(byName: "3")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }
        ws3.rootTilingContainer.apply {
            TestWindow.new(id: 3, parent: $0)
        }

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")
        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "3")
        assertEquals(ws1.rootTilingContainer.children.count, 3)
        assertEquals(ws1.viewToggledStates.count, 2)

        dissolveViewToggles(workspace: ws1)

        assertEquals(ws1.rootTilingContainer.children.count, 1)
        assertEquals(ws2.rootTilingContainer.children.count, 1)
        assertEquals(ws3.rootTilingContainer.children.count, 1)
        assertEquals(ws1.viewToggledStates.count, 0)
    }

    // MARK: - Stale bindings

    func testStaleBindingSkippedOnDissolve() {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        let ws3 = Workspace.get(byName: "3")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")
        assertEquals(ws1.rootTilingContainer.children.count, 2)

        // Simulate user moving window 2 to ws3 during the merge
        let window2 = ws1.rootTilingContainer.children.first(where: { ($0 as? Window)?.windowId == 2 })!
        window2.bind(to: ws3.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        dissolveViewToggles(workspace: ws1)

        assertEquals(ws1.rootTilingContainer.children.count, 1)
        assertEquals(ws3.rootTilingContainer.children.count, 1)
        assertEquals(ws1.viewToggledStates.count, 0)
    }

    // MARK: - Command integration

    func testWorkspaceCommandViewToggle() async throws {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }
        check(ws1.focusWorkspace())

        var args = WorkspaceCmdArgs(rawArgs: [])
        args.target = .initialized(.direct(.parse("2").getOrDie()))
        args.viewToggle = true
        _ = try await WorkspaceCommand(args: args).run(.defaultEnv, .emptyStdin)

        assertEquals(ws1.rootTilingContainer.children.count, 2)
        assertEquals(ws1.viewToggledStates.count, 1)
    }

    func testWorkspaceSwitchDissolvesToggle() async throws {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }
        check(ws1.focusWorkspace())

        var toggleArgs = WorkspaceCmdArgs(rawArgs: [])
        toggleArgs.target = .initialized(.direct(.parse("2").getOrDie()))
        toggleArgs.viewToggle = true
        _ = try await WorkspaceCommand(args: toggleArgs).run(.defaultEnv, .emptyStdin)
        assertEquals(ws1.rootTilingContainer.children.count, 2)

        var switchArgs = WorkspaceCmdArgs(rawArgs: [])
        switchArgs.target = .initialized(.direct(.parse("3").getOrDie()))
        _ = try await WorkspaceCommand(args: switchArgs).run(.defaultEnv, .emptyStdin)

        assertEquals(ws1.rootTilingContainer.children.count, 1)
        assertEquals(ws2.rootTilingContainer.children.count, 1)
        assertEquals(ws1.viewToggledStates.count, 0)
    }

    func testWorkspaceBackAndForthDissolvesToggle() async throws {
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        ws1.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }
        check(ws1.focusWorkspace())
        check(ws2.focusWorkspace())
        check(ws1.focusWorkspace())

        performViewToggle(hostWorkspace: ws1, donorWorkspaceName: "2")
        assertEquals(ws1.rootTilingContainer.children.count, 2)

        _ = try await WorkspaceBackAndForthCommand(args: WorkspaceBackAndForthCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)

        assertEquals(ws1.viewToggledStates.count, 0)
        assertEquals(ws2.rootTilingContainer.children.count, 1)
    }

    // MARK: - Parsing

    func testParseViewToggle() {
        testParseSingleCommandSucc(
            "workspace --view-toggle 2",
            WorkspaceCmdArgs(rawArgs: []).copy(\.viewToggle, true).copy(\.target, .initialized(.direct(.parse("2").getOrDie()))),
        )
    }

    func testParseViewToggleIncompatibleWithWrapAround() {
        XCTAssertNotNil(parseCommand("workspace --view-toggle --wrap-around next").errorOrNil)
    }

    func testParseViewToggleIncompatibleWithAutoBackAndForth() {
        XCTAssertNotNil(parseCommand("workspace --view-toggle --auto-back-and-forth 2").errorOrNil)
    }

    func testParseViewToggleIncompatibleWithRelative() {
        XCTAssertNotNil(parseCommand("workspace --view-toggle next").errorOrNil)
    }
}
