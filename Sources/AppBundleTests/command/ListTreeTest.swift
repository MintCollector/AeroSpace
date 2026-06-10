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
}
