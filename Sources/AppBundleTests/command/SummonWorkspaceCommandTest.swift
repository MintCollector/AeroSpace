@testable import AppBundle
import Common
import XCTest

@MainActor
final class SummonWorkspaceCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertEquals(parseCommand("summon-workspace").errorOrNil, "ERROR: Argument '<workspace>' is mandatory")
        testParseSingleCommandSucc("summon-workspace foo", SummonWorkspaceCmdArgs(rawArgs: []).copy(\.target, .initialized(.parse("foo").getOrDie())))
    }

    func testParseDashDash() {
        testParseSingleCommandSucc(
            "summon-workspace -- foo",
            SummonWorkspaceCmdArgs(rawArgs: []).copy(\.target, .initialized(.parse("foo").getOrDie())),
        )
        testParseSingleCommandSucc(
            "summon-workspace --fail-if-noop -- foo",
            SummonWorkspaceCmdArgs(rawArgs: []).copy(\.target, .initialized(.parse("foo").getOrDie())).copy(\.failIfNoop, true),
        )
        assertEquals(parseCommand("summon-workspace --").errorOrNil, "ERROR: Argument '<workspace>' is mandatory")
        assertEquals(parseCommand("summon-workspace -- --fail-if-noop").errorOrNil, "ERROR: Workspace names starting with dash are disallowed")
    }

    func testParseWhenVisibleDefault() {
        let cmd = parseCommand("summon-workspace foo").cmdOrDie as! SummonWorkspaceCommand
        assertEquals(cmd.args.rawWhenVisibleAction, nil)
        assertEquals(cmd.args.whenVisible, .focus)
    }

    func testParseWhenVisibleFocus() {
        let cmd = parseCommand("summon-workspace --when-visible focus foo").cmdOrDie as! SummonWorkspaceCommand
        assertEquals(cmd.args.whenVisible, .focus)
    }

    func testParseWhenVisibleSwap() {
        let cmd = parseCommand("summon-workspace --when-visible swap foo").cmdOrDie as! SummonWorkspaceCommand
        assertEquals(cmd.args.whenVisible, .swap)
    }

    func testParseWhenVisibleUnknown() {
        XCTAssertNotNil(parseCommand("summon-workspace --when-visible bogus foo").errorOrNil)
    }
}
