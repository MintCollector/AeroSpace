@testable import AppBundle
import Common
import XCTest

private let testAppId = "bobko.AeroSpace.test-app"

@MainActor
final class RuleRecheckTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheState()
    }

    private func rule(_ recheck: RuleRecheck?, if matcher: String, run: String, checkFurther: Bool = false) -> WindowDetectedCallback {
        WindowDetectedCallback(
            matcher: .command(parseCommand(matcher).cmdOrDie),
            checkFurtherCallbacks: checkFurther,
            recheck: recheck,
            rawRun: parseCommand(run).cmdOrDie,
        )
    }

    func testMatchersUseTheKnownTitleInsteadOfAskingTheApp() async {
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "from the app")
        let command = rule(nil, if: "test %{window-title} ~= known", run: "layout floating")
        let legacy = WindowDetectedCallback(
            matcher: .legacy(LegacyWindowDetectedCallbackMatcher(windowTitleRegexSubstring: CaseInsensitiveRegex.new("known").getOrDie())),
            rawRun: .empty,
        )

        assertEquals(await command.matches(window), false)
        assertEquals(await command.matches(window, knownTitle: "known title"), true)
        assertEquals(await legacy.matches(window), false)
        assertEquals(await legacy.matches(window, knownTitle: "known title"), true)
    }

    func testSnapshotChangesWithTitleLayoutAndWorkspace() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let snapshot = { ruleSnapshot(window, title: $0, monitorValues: ruleMonitorValues(window.nodeWorkspace)) }
        let tiled = snapshot("a")
        assertEquals(snapshot("a"), tiled)
        assertNotEquals(snapshot("b"), tiled)

        window.bindAsFloatingWindow(to: workspace)
        let floating = snapshot("a")
        assertNotEquals(floating, tiled)

        window.bindAsFloatingWindow(to: Workspace.get(byName: "other"))
        assertNotEquals(snapshot("a"), floating)
    }

    private func detect(id: UInt32, title: String) async -> TestWindow {
        let window = TestWindow.new(id: id, parent: Workspace.get(byName: name).rootTilingContainer, title: title)
        await tryOnWindowDetected(window)
        return window
    }

    func testDetectionStartsTrackingTheWindow() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Untitled")

        assertEquals(window.nodeWorkspace?.name, name)
        assertEquals(window.lastKnownTitle, "Untitled")
        assertEquals(window.ruleRecheck?.title, "Untitled")
        assertEquals(window.ruleRecheck?.matched, [])
        assertEquals(window.ruleRecheck?.spent, [])
    }

    func testAnUntilMatchedRuleThatRunsAtDetectionIsSpent() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Bitwarden")

        assertEquals(window.nodeWorkspace?.name, "B")
        assertEquals(window.ruleRecheck?.spent, [0])
    }

    func testDetectionUsesTheTitleFromTitleEvents() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "stale")
        window.hasTitleEvents = true
        window.lastKnownTitle = "Meet"

        await tryOnWindowDetected(window)

        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testRunCallbackLeavesUntrackedWindowsUntracked() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "layout floating")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)

        assertNil(window.ruleRecheck)
    }

    private func move(_ window: Window, to workspace: String) {
        window.bind(to: Workspace.get(byName: workspace).rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    /// A title-changed notification followed by the refresh's check pass
    private func retitle(_ window: Window, _ title: String) async -> Bool {
        recordTitleEvent(window, title)
        return await recheckWindowRules([window])
    }

    func testTitleEventsIgnoreRepeatsOfTheSameTitle() {
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(recordTitleEvent(window, "a"), true)
        assertEquals(recordTitleEvent(window, "a"), false)
        assertEquals(recordTitleEvent(window, "b"), true)
        assertEquals(window.lastKnownTitle, "b")
        assertEquals(window.hasTitleEvents, true)
    }

    func testUntilMatchedCatchesALateTitleOnce() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Bitwarden", run: "move-node-to-workspace B")]
        let window = await detect(id: 2, title: "Untitled")
        assertEquals(window.nodeWorkspace?.name, name)

        assertEquals(await retitle(window, "Bitwarden"), true)
        assertEquals(window.nodeWorkspace?.name, "B")

        move(window, to: name)
        assertEquals(await retitle(window, "Untitled"), false)
        assertEquals(await retitle(window, "Bitwarden"), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testEveryMatchRunsEachTimeTheIfStartsMatching() async {
        config.onWindowDetected = [rule(.everyMatch, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet - standup"), true)
        assertEquals(window.nodeWorkspace?.name, "M")

        move(window, to: name)
        assertEquals(await retitle(window, "Meet - standup (2)"), false) // still matching: not a new match
        assertEquals(await retitle(window, "Inbox"), false)
        assertEquals(await retitle(window, "Meet - retro"), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testEveryChangeRunsOnEveryChangeWhileMatching() async {
        config.onWindowDetected = [rule(.everyChange, if: "test %{app-bundle-id} = \(testAppId)", run: "layout floating tiling")]
        let window = await detect(id: 2, title: "a") // a recheck rule runs at detection like any rule
        assertEquals(window.parent is FloatingWindowsContainer, true)

        assertEquals(await retitle(window, "b"), true)
        assertEquals(window.parent is TilingContainer, true)
        assertEquals(await retitle(window, "c"), true)
        assertEquals(window.parent is FloatingWindowsContainer, true)

        assertEquals(await recheckWindowRules([window]), false) // nothing changed
    }

    func testOtherCriteriaAreCheckedWhenTheyChange() async {
        config.onWindowDetected = [rule(.everyMatch, if: "test %{workspace} = W", run: "layout floating")]
        let window = await detect(id: 2, title: "a")
        assertEquals(window.parent is TilingContainer, true)

        move(window, to: "W")
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.parent is FloatingWindowsContainer, true)
    }

    func testARulesOwnMoveDoesNotSetOffOtherRules() async {
        config.onWindowDetected = [
            rule(.everyMatch, if: "test %{workspace} = A", run: "move-node-to-workspace B"),
            rule(.everyMatch, if: "test %{workspace} = B", run: "move-node-to-workspace A"),
        ]
        let window = await detect(id: 2, title: "a")

        move(window, to: "A")
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.nodeWorkspace?.name, "B")
        assertEquals(await recheckWindowRules([window]), false)
        assertEquals(window.nodeWorkspace?.name, "B")
    }

    func testTheFirstRuleToFireShadowsTheRest() async {
        config.onWindowDetected = [
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace X"),
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace Y"),
        ]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "X")

        move(window, to: name)
        assertEquals(await recheckWindowRules([window]), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testCheckFurtherCallbacksLetsLaterRulesRun() async {
        config.onWindowDetected = [
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace X", checkFurther: true),
            rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "layout floating"),
        ]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "X")
        assertEquals(window.parent is FloatingWindowsContainer, true)
    }

    func testRulesWithoutRecheckOnlyRunAtDetection() async {
        config.onWindowDetected = [rule(nil, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        assertEquals(await retitle(window, "Meet"), false)
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testWindowsInAMacosNativeStateWait() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")
        window.layoutReason = .macos(prevParentKind: .tilingContainer) // minimized, say

        assertEquals(await retitle(window, "Meet"), false)
        window.layoutReason = .standard
        assertEquals(await recheckWindowRules([window]), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    func testWindowsClaimedByExpectWindowAreLeftAlone() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        armWindowExpectation(
            matcher: LegacyWindowDetectedCallbackMatcher(appId: testAppId),
            commands: parseCommand("move-node-to-workspace X").cmdOrDie,
            timeout: 10,
        )
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, title: "Inbox")

        await tryOnWindowDetected(window)
        assertEquals(window.nodeWorkspace?.name, "X")
        assertNil(window.ruleRecheck)

        assertEquals(await retitle(window, "Meet"), false)
        assertEquals(window.nodeWorkspace?.name, "X")
    }

    // Only title paths that don't start a refresh: a scheduled refresh would run real AX code here

    func testATitleEventForAnUntrackedWindowOnlyUpdatesItsTitle() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        await windowTitleChanged(windowId: 2, title: "Meet")

        assertEquals(window.lastKnownTitle, "Meet")
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testATitleChangeThatSetsOffNoRuleIsSavedRightAway() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")

        await windowTitleChanged(windowId: 2, title: "Inbox (1)")

        assertEquals(window.ruleRecheck?.title, "Inbox (1)")
        assertEquals(window.nodeWorkspace?.name, name)
    }

    func testReloadStartsTrackedWindowsOverAgainstTheNewRules() async {
        config.onWindowDetected = []
        let matching = await detect(id: 2, title: "Meet")
        let other = await detect(id: 3, title: "Inbox")

        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        await reseedRuleRechecks([matching, other])

        // Already matching when the rule arrived: counts as applied, as at detection
        assertEquals(await retitle(matching, "Meet (2)"), false)
        assertEquals(matching.nodeWorkspace?.name, name)
        assertEquals(await retitle(other, "Meet"), true)
        assertEquals(other.nodeWorkspace?.name, "M")
    }

    func testAStateFromBeforeAReloadIsNotSaved() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = await detect(id: 2, title: "Inbox")
        let stale = window.ruleRecheck!

        await reseedRuleRechecks([window])
        saveRuleRecheck(window, stale)

        assertEquals(window.ruleRecheck?.generation, ruleRecheckGeneration)
    }

    func testARestoredWindowIsTrackedWithoutRunningItsRules() async {
        config.onWindowDetected = [rule(.untilMatched, if: "test %{window-title} ~= Meet", run: "move-node-to-workspace M")]
        let window = TestWindow.new(id: 2, parent: Workspace.get(byName: name).rootTilingContainer, title: "Inbox")

        await restartRuleRecheck(window)
        assertEquals(window.nodeWorkspace?.name, name)

        assertEquals(await retitle(window, "Meet"), true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }
}
