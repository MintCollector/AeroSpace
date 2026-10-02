@testable import AppBundle
import Common
import XCTest

private let testAppId = "bobko.AeroSpace.test-app"

@MainActor
final class WindowExpectationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheState()
    }

    private var appMatcher: LegacyWindowDetectedCallbackMatcher {
        LegacyWindowDetectedCallbackMatcher(appId: testAppId)
    }

    private func commands(_ raw: String) -> Shell<any Command> {
        parseCommand(raw, allowExecAndForget: true, allowEval: false).cmdOrNil!
    }

    private func moveRule(to workspace: String) -> WindowDetectedCallback {
        WindowDetectedCallback(matcher: .legacy(appMatcher), rawRun: commands("move-node-to-workspace \(workspace)"))
    }

    /// Focused window 1 on this test's workspace; returns that workspace.
    private func setUpFocusedWindow() -> Workspace {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        return workspace
    }

    func testClaimsWindowAndRunsCommands() async {
        let workspace = setUpFocusedWindow()
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        await tryOnWindowDetected(detected)

        assertEquals(detected.nodeWorkspace?.name, "X")
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(noFocusSuppression[2]?.restoreWindowId, 1)
        assertEquals(pendingWindowExpectations.isEmpty, true)
    }

    func testReplacesConfigRules() async {
        let workspace = setUpFocusedWindow()
        config.onWindowDetected = [moveRule(to: "Y")]
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        await tryOnWindowDetected(detected)

        assertEquals(detected.nodeWorkspace?.name, "X")
    }

    func testOneShot() async {
        let workspace = setUpFocusedWindow()
        config.onWindowDetected = [moveRule(to: "Y")]
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)
        let claimed = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        await tryOnWindowDetected(claimed)
        let next = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        await tryOnWindowDetected(next)

        assertEquals(claimed.nodeWorkspace?.name, "X")
        assertEquals(next.nodeWorkspace?.name, "Y")
    }

    func testNonMatchingWindowPassesThrough() async {
        let workspace = setUpFocusedWindow()
        config.onWindowDetected = [moveRule(to: "Y")]
        _ = armWindowExpectation(
            matcher: LegacyWindowDetectedCallbackMatcher(appId: "com.other"),
            commands: commands("move-node-to-workspace X"),
            timeout: 10,
        )
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        await tryOnWindowDetected(detected)

        assertEquals(detected.nodeWorkspace?.name, "Y")
        assertEquals(pendingWindowExpectations.count, 1)
    }

    func testTitleCondition() async {
        let workspace = setUpFocusedWindow()
        let matcher = LegacyWindowDetectedCallbackMatcher(appId: testAppId, windowTitleRegexSubstring: CaseInsensitiveRegex.new("PR #23").getOrDie())
        _ = armWindowExpectation(matcher: matcher, commands: commands("move-node-to-workspace X"), timeout: 10)
        let inbox = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, title: "inbox")
        await tryOnWindowDetected(inbox)
        let pr = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, title: "Fix — PR #23")

        await tryOnWindowDetected(pr)

        assertEquals(inbox.nodeWorkspace?.name, workspace.name)
        assertEquals(pr.nodeWorkspace?.name, "X")
        assertEquals(pendingWindowExpectations.isEmpty, true)
    }

    func testFifo() async {
        let workspace = setUpFocusedWindow()
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace Z"), timeout: 10)
        let first = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        await tryOnWindowDetected(first)
        let second = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        await tryOnWindowDetected(second)

        assertEquals(first.nodeWorkspace?.name, "X")
        assertEquals(second.nodeWorkspace?.name, "Z")
    }

    func testExpiredExpectationIsDroppedAndDoesNotClaim() async {
        let workspace = setUpFocusedWindow()
        let t0 = Date()
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 1, now: t0)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let taken = await takeWindowExpectation(for: detected, now: t0.addingTimeInterval(2))

        assertEquals(taken == nil, true)
        assertEquals(pendingWindowExpectations.isEmpty, true)
    }

    func testPreArmDoesNotConsume() {
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)

        assertEquals(preArmWindowExpectations(windowId: 9, pid: 1, appBundleId: testAppId, appName: nil), true)

        assertEquals(noFocusSuppression[9] != nil, true)
        assertEquals(pendingWindowExpectations.count, 1)
    }

    func testPreArmWithTitleOnlyExpectation() {
        let matcher = LegacyWindowDetectedCallbackMatcher(windowTitleRegexSubstring: CaseInsensitiveRegex.new("PR #23").getOrDie())
        _ = armWindowExpectation(matcher: matcher, commands: commands("move-node-to-workspace X"), timeout: 10)

        assertEquals(preArmWindowExpectations(windowId: 9, pid: 1, appBundleId: "com.anything", appName: nil), true)

        assertEquals(noFocusSuppression[9] != nil, true)
        assertEquals(pendingWindowExpectations.count, 1)
    }

    func testPreArmIgnoresNonMatchingApp() {
        _ = armWindowExpectation(matcher: appMatcher, commands: commands("move-node-to-workspace X"), timeout: 10)

        assertEquals(preArmWindowExpectations(windowId: 9, pid: 1, appBundleId: "com.other", appName: nil), false)

        assertEquals(noFocusSuppression[9] == nil, true)
    }
}
