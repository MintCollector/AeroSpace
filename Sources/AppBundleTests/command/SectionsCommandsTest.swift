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
