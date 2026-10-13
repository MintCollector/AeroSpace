@testable import AppBundle
import Common
import XCTest

@MainActor
final class SplitMonitorsCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("split-monitors toggle", SplitMonitorsCmdArgs(rawArgs: [], targetState: .toggle))
        testParseSingleCommandSucc("split-monitors off", SplitMonitorsCmdArgs(rawArgs: [], targetState: .off))
        testParseSingleCommandSucc("split-monitors on --fail-if-noop", SplitMonitorsCmdArgs(rawArgs: [], targetState: .on).copy(\.failIfNoop, true))
        assertNotNil(parseCommand("split-monitors").errorOrNil)
        assertNotNil(parseCommand("split-monitors toggle --fail-if-noop").errorOrNil)
    }

    func testToggle() async {
        splitTestMonitor()
        assertEquals(await runCommand("split-monitors toggle").exitCode.rawValue, 0)
        assertEquals(monitorInfos.count, 1)
        assertEquals(await runCommand("split-monitors toggle").exitCode.rawValue, 0)
        assertEquals(monitorInfos.count, 3)
    }

    func testNoop() async {
        let result = await runCommand("split-monitors on")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, ["Already split. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(await runCommand("split-monitors on --fail-if-noop").exitCode.rawValue, 2)
    }

    private func runCommand(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
