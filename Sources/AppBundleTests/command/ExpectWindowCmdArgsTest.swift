@testable import AppBundle
import Common
import XCTest

final class ExpectWindowCmdArgsTest: XCTestCase {
    func testParseAppIdAndCommands() {
        let args = parseExpectWindow("expect-window --app-id com.x -- 'layout floating' 'exec-and-forget echo hi'")
        assertEquals(args.appId, "com.x")
        assertEquals(args.commands, ["layout floating", "exec-and-forget echo hi"])
        assertEquals(args.timeoutSeconds, nil)
    }

    func testParseTitleRegexAndTimeout() {
        let args = parseExpectWindow(#"expect-window --window-title-regex-substring 'PR #\d+' --timeout 5"#)
        assertEquals(args.windowTitleRegexSubstring?.origin, #"PR #\d+"#)
        assertEquals(args.timeoutSeconds, 5)
    }

    func testZeroCommandsIsValid() {
        let args = parseExpectWindow("expect-window --app-id com.x")
        assertEquals(args.commands, [])
    }

    func testNoConditionsFails() {
        assertEquals(
            parseCommand("expect-window -- 'layout floating'").errorOrNil,
            "At least one of --app-id, --app-name-regex-substring, --window-title-regex-substring is required",
        )
    }

    func testInvalidRegexFails() {
        XCTAssertNotNil(parseCommand("expect-window --app-name-regex-substring '('").errorOrNil)
    }
}

private func parseExpectWindow(_ raw: String) -> ExpectWindowCmdArgs {
    (parseCommand(raw).cmdOrDie.singleCmdOrDie as! ExpectWindowCommand).args
}
