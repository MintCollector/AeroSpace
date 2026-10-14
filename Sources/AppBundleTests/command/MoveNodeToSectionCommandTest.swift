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
