@testable import AppBundle
import Common
import XCTest

final class ListMonitorsTest: XCTestCase {
    func testParseListMonitorsCommand() {
        testParseSingleCommandSucc("list-monitors", ListMonitorsCmdArgs(rawArgs: []))
        testParseSingleCommandSucc("list-monitors --focused", ListMonitorsCmdArgs(rawArgs: []).copy(\.focused, true))
        testParseSingleCommandSucc("list-monitors --count", ListMonitorsCmdArgs(rawArgs: []).copy(\.outputOnlyCount, true))
        assertEquals(parseCommand("list-monitors --format %{monitor-id} --count").errorOrNil, "ERROR: Conflicting options: --count, --format")
        assertEquals(parseCommand("list-monitors --format '%{all}'").errorOrNil, "'%{all}' format option requires --json flag")
        assertNil(parseCommand("list-monitors --format '%{all}' --json").errorOrNil)
        assertEquals(parseCommand("list-monitors --format '%{all} %{monitor-id}'").errorOrNil, "'%{all}' format option must be used alone and cannot be combined with other variables")
        assertEquals(parseCommand("list-monitors --format '%{monitor-name} %{all}'").errorOrNil, "'%{all}' format option must be used alone and cannot be combined with other variables")
        assertNil(parseCommand("list-monitors --format ' %{all} ' --json").errorOrNil)
    }

    @MainActor
    func testColumnsAreMonitors() async {
        setUpWorkspacesForTests()
        splitTestMonitor()
        let result = await parseCommand("list-monitors --format '%{monitor-id} %{monitor-name} %{monitor-x} %{monitor-y} %{monitor-width} %{monitor-is-main}'")
            .cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, [
            "1 Test Monitor 1 0 0 480 false",
            "2 Test Monitor 2 480 0 960 true",
            "3 Test Monitor 3 1440 0 480 false",
        ])
    }
}
