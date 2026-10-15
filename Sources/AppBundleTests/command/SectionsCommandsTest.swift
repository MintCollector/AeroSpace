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
        config.defaultRootContainerOrientation = .auto // By their slots: left and right stacked, main side by side
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        assertTrue(TestWindow.new(id: 2, parent: workspace.sectionForWindows("main")).focusWindow())
        assertEquals(await run("layout --root tiles accordion").exitCode.rawValue, 0) // aero-helper's toggle-accordion
        TestWindow.new(id: 3, parent: workspace.sectionForWindows("right")) // A section to come
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("left", .v_accordion([.window(1)])), // Each keeps its orientation
            .section("main", .h_accordion([.window(2)])),
            .section("right", .v_accordion([.window(3)])),
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

    func testWindowSection() async {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        let result = await run("list-windows --workspace a --format '%{window-section}|%{window-id}'")
        assertEquals(Set(result.stdout), ["left|1", "|2"])
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
