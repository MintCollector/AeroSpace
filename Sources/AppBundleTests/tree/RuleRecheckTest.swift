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

    func testSnapshotChangesWithTitleLayoutAndWorkspace() async {
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
}
