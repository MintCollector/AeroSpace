@testable import AppBundle
import Common
import XCTest

final class ListTreeTest: XCTestCase {
    func testParseListTreeCommand() {
        testParseCommandSucc("list-tree", ListTreeCmdArgs(rawArgs: []))
    }

    // Pins the exact JSON keys the helper's tree DTOs decode, so a FormatVar rename can't
    // silently break list-tree's output contract.
    func testFieldVarKeysMatchHelperContract() {
        assertEquals(Set(ListTreeCommand.windowVars.map { $0.rawValue }), [
            "window-id", "window-title", "window-is-fullscreen", "window-layout",
            "window-x", "window-y", "window-width", "window-height",
            "app-name", "app-bundle-id", "app-pid", "app-exec-path", "app-bundle-path",
        ])
        assertEquals(Set(ListTreeCommand.workspaceVars.map { $0.rawValue }), [
            "workspace", "workspace-is-focused", "workspace-is-visible", "workspace-root-container-layout",
        ])
        assertEquals(Set(ListTreeCommand.monitorVars.map { $0.rawValue }), [
            "monitor-id", "monitor-appkit-nsscreen-screens-id",
            "monitor-name", "monitor-is-main", "monitor-width", "monitor-height",
        ])
    }

    @MainActor
    func testListTreeOutputShapeAndCachedRect() async throws {
        setUpWorkspacesForTests()
        let w = TestWindow.new(id: 5, parent: focus.workspace.rootTilingContainer,
                               rect: Rect(topLeftX: 1, topLeftY: 1, width: 1, height: 1))
        // Cached layout rect differs from the AX rect on purpose; list-tree must report the cached one.
        w.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)

        let result = try await ListTreeCommand(args: ListTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)

        // Root is now an object: { "focused-window-id": Int?, "monitors": [...] }.
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.joined().utf8)) as! [String: Any]
        let monitors = root["monitors"] as! [[String: Any]]
        // focused-window-id key is always present (Int when something is focused, else NSNull/null).
        assertTrue(root["focused-window-id"] != nil)
        assertTrue(root["focused-window-id"] is Int || root["focused-window-id"] is NSNull)
        // monitor-id must be a number, not a "NULL-MONITOR-ID" sentinel string (helper decodes Int).
        assertTrue((monitors[0]["monitor-id"] as? Int) != nil)

        let allWindows = monitors
            .flatMap { ($0["workspaces"] as! [[String: Any]]) }
            .flatMap { ($0["windows"] as! [[String: Any]]) }
        let win = allWindows.first { ($0["window-id"] as? Int) == 5 }!
        assertEquals(win["window-x"] as? Int, 100)      // cached layout rect, not the AX rect (1)
        assertEquals(win["window-width"] as? Int, 300)
        assertEquals(Set(win.keys), Set(ListTreeCommand.windowVars.map { $0.rawValue }))
    }
}
