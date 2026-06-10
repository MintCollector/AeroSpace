@testable import AppBundle
import Common
import XCTest

@MainActor
final class ListWorkspacesTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertNotNil(parseCommand("list-workspaces --all").cmdOrNil)
        assertNil(parseCommand("list-workspaces --all --visible").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --visible").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --all").cmdOrNil)
        assertNil(parseCommand("list-workspaces --visible").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --visible --monitor 2").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --monitor focused").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --monitor 2").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --all --format %{workspace}").cmdOrNil)
        assertEquals(parseCommand("list-workspaces --all --format %{workspace} --count").errorOrNil, "ERROR: Conflicting options: --count, --format")
        assertEquals(parseCommand("list-workspaces --empty").errorOrNil, "Mandatory option is not specified (--all|--focused|--monitor)")
        assertEquals(parseCommand("list-workspaces --all --focused --monitor mouse").errorOrNil, "ERROR: Conflicting options: --all, --focused, --monitor")
        assertEquals(parseCommand("list-workspaces --all --format '%{all}'").errorOrNil, "'%{all}' format option requires --json flag")
        assertNotNil(parseCommand("list-workspaces --all --format '%{all}' --json").cmdOrNil)
        assertEquals(parseCommand("list-workspaces --all --format '%{all} %{workspace}'").errorOrNil, "'%{all}' format option must be used alone and cannot be combined with other variables")
        assertEquals(parseCommand("list-workspaces --all --format '%{workspace-is-focused} %{all}'").errorOrNil, "'%{all}' format option must be used alone and cannot be combined with other variables")
        assertNotNil(parseCommand("list-workspaces --all --format ' %{all} ' --json").cmdOrNil)
    }

    func testWorkspaceRootOrientationVariable() {
        Workspace.get(byName: name).rootTilingContainer.apply {
            $0.changeOrientation(.h)
            let workspace = Workspace.get(byName: name)
            let workspaces = [AeroObj.workspace(workspace)]
            assertEquals(
                workspaces.format([.interVar(.formatVar(.workspace(.workspaceRootContainerOrientation)))]),
                .success(["horizontal"]),
            )
        }

        Workspace.get(byName: name).rootTilingContainer.apply {
            $0.changeOrientation(.v)
            let workspace = Workspace.get(byName: name)
            let workspaces = [AeroObj.workspace(workspace)]
            assertEquals(
                workspaces.format([.interVar(.formatVar(.workspace(.workspaceRootContainerOrientation)))]),
                .success(["vertical"]),
            )
        }

        Workspace.get(byName: name).rootTilingContainer.apply {
            $0.changeOrientation(.h)
            let workspace = Workspace.get(byName: name)
            let workspaces = [AeroObj.workspace(workspace)]
            assertEquals(
                workspaces.format([
                    .interVar(.formatVar(.workspace(.workspaceName))),
                    .literal(" | "),
                    .interVar(.formatVar(.workspace(.workspaceRootContainerOrientation))),
                    .literal(" | "),
                    .interVar(.formatVar(.workspace(.workspaceRootContainerLayout))),
                ]),
                .success(["\(name) | horizontal | h_tiles"]),
            )
        }
    }
}
