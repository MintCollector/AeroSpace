@testable import AppBundle
import Common
import XCTest

@MainActor
final class ExpectWindowCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheState()
    }

    func testArmsExpectationThatClaimsTheNextWindow() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let before = Date()

        let result = await parseCommand("expect-window --app-id bobko.AeroSpace.test-app -- 'move-node-to-workspace X'")
            .cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(pendingWindowExpectations.count, 1)
        assertEquals(pendingWindowExpectations.first?.matcher.appIds, ["bobko.AeroSpace.test-app"])
        assertDeadline(pendingWindowExpectations.first?.deadline, isAbout: 10, after: before)

        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        await tryOnWindowDetected(detected)

        assertEquals(detected.nodeWorkspace?.name, "X")
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(pendingWindowExpectations.isEmpty, true)
    }

    func testTimeout() async {
        let before = Date()

        let result = await parseCommand("expect-window --app-id com.x --timeout 3").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertDeadline(pendingWindowExpectations.first?.deadline, isAbout: 3, after: before)
        assertEquals(pendingWindowExpectations.first?.takeFocus, false)
    }

    func testFocusFlagArmsFocusTakingExpectation() async {
        let result = await parseCommand("expect-window --app-id com.x --focus").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(pendingWindowExpectations.first?.takeFocus, true)
    }

    func testUnparsableCommandArmsNothing() async {
        let result = await parseCommand("expect-window --app-id com.x -- 'no-such-command'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertNotEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr.count, 1)
        assertEquals(result.stderr.first?.contains("'no-such-command'"), true)
        assertEquals(pendingWindowExpectations.isEmpty, true)
    }

    func testExecAndForgetIsAccepted() async {
        let result = await parseCommand("expect-window --app-id com.x -- 'exec-and-forget true'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(pendingWindowExpectations.count, 1)
    }
}

private func assertDeadline(_ deadline: Date?, isAbout seconds: TimeInterval, after start: Date, file: StaticString = #filePath, line: UInt = #line) {
    guard let deadline else { return XCTFail("No pending expectation", file: file, line: line) }
    let offset = deadline.timeIntervalSince(start)
    XCTAssert(offset >= seconds && offset < seconds + 1, "deadline is \(offset)s after start, expected ~\(seconds)s", file: file, line: line)
}
