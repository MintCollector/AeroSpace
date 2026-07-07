@testable import AppBundle
import Common
import XCTest

@MainActor
final class NoFocusSuppressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheState()
    }

    private var noFocusRule: WindowDetectedCallback {
        WindowDetectedCallback(matcher: .command(.empty), noFocus: true, rawRun: .empty)
    }

    func testArmRemembersCurrentFocusAsRestoreTarget() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        config.onWindowDetected = [noFocusRule]

        await tryOnWindowDetected(detected)

        assertEquals(noFocusSuppression[2]?.restoreWindowId, 1)
        assertEquals(focus.windowOrNil?.windowId, 1) // Arming must not move the focus
    }

    func testArmBouncesImmediatelyWhenDetectedWindowAlreadyStoleFocus() async {
        let workspace = Workspace.get(byName: name)
        let prev = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(prev.focusWindow(), true)
        await checkOnFocusChangedCallbacks_nonCancellable() // Snapshot focus history like a refresh session would
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(detected.focusWindow(), true) // Activation landed before detection
        await checkOnFocusChangedCallbacks_nonCancellable() // Now prevFocus points to window 1
        config.onWindowDetected = [noFocusRule]

        await tryOnWindowDetected(detected)

        assertEquals(noFocusSuppression[2]?.restoreWindowId, 1)
        assertEquals(focus.windowOrNil?.windowId, 1) // Model focus restored
        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 1) // Native focus restored
    }

    func testArmsOnceEvenWithCheckFurtherCallbacks() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        var first = noFocusRule
        first.checkFurtherCallbacks = true
        config.onWindowDetected = [first, noFocusRule]

        await tryOnWindowDetected(detected)

        assertEquals(noFocusSuppression.count, 1)
        assertEquals(noFocusSuppression[2]?.restoreWindowId, 1)
    }

    func testRuleWithoutNoFocusDoesNotArm() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        config.onWindowDetected = [WindowDetectedCallback(matcher: .command(.empty), rawRun: .empty)]

        await tryOnWindowDetected(detected)

        assertEquals(noFocusSuppression.isEmpty, true)
    }

    func testUpdateFocusCacheRefusesAdoptionAndBounces() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        updateFocusCache(focused) // Adopt the initial focus: lastKnown = 1
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected // Simulate the native focus steal
        updateFocusCache(detected)

        assertEquals(focus.windowOrNil?.windowId, 1) // Model focus not adopted
        assertEquals(focus.workspace.name, name) // Visible workspace didn't flip
        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 1) // Native focus bounced back
    }

    func testSuppressionExpiresAfterTtl() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        updateFocusCache(focused)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected
        updateFocusCache(detected, now: Date().addingTimeInterval(noFocusSuppressionTtl + 0.1))

        assertEquals(focus.windowOrNil?.windowId, 2) // Adopted normally after expiry
        assertEquals(focus.workspace.name, "other")
        assertEquals(noFocusSuppression.isEmpty, true) // Expired entry lazily purged
        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 2) // No bounce
    }

    func testDeadRestoreTargetRefusesAdoptionWithoutBounce() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        updateFocusCache(focused)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        focused.unbindFromParent() // Restore target dies while suppression is pending
        TestApp.shared.focusedWindow = detected
        updateFocusCache(detected)

        assertEquals(focus.workspace.name, name) // Adoption still refused: no workspace flip
        assertNil(focus.windowOrNil)
        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 2) // But no bounce either
    }

    func testWindowWithoutNoFocusRuleIsAdoptedNormally() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        updateFocusCache(focused)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [WindowDetectedCallback(matcher: .command(.empty), rawRun: .empty)]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected
        updateFocusCache(detected)

        assertEquals(focus.windowOrNil?.windowId, 2) // Unchanged legacy behavior
        assertEquals(focus.workspace.name, "other")
    }

    func testFastBounceByWindowId() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected // Native steal, model not yet aware
        fastBounceNoFocusSuppression(windowId: 2, pid: nil)

        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 1) // Native focus bounced back
        assertEquals(focus.windowOrNil?.windowId, 1) // Model focus untouched
    }

    func testFastBounceByPid() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected
        fastBounceNoFocusSuppression(windowId: nil, pid: TestApp.shared.pid) // App-activation path

        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 1)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFastBounceExpiredEntryIsNoop() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let detected = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        config.onWindowDetected = [noFocusRule]
        await tryOnWindowDetected(detected)

        TestApp.shared.focusedWindow = detected
        fastBounceNoFocusSuppression(windowId: 2, pid: nil, now: Date().addingTimeInterval(noFocusSuppressionTtl + 0.1))

        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 2) // Expired: no bounce
    }

    func testFastBounceUnknownWindowIsNoop() {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let other = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        TestApp.shared.focusedWindow = other // Focus change with no armed suppression
        fastBounceNoFocusSuppression(windowId: 3, pid: nil)

        assertEquals((TestApp.shared.focusedWindow as? TestWindow)?.windowId, 3) // Untouched
    }

    func testPreArmMatchesAppIdOnlyRule() {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(appId: "com.example.app")),
                noFocus: true,
                rawRun: .empty,
            ),
        ]

        // Window 42 not yet in the tree — pre-arm fires straight off the AX windowCreated event
        preArmNoFocusSuppression(windowId: 42, pid: 99, appBundleId: "com.example.app", appName: nil)

        assertEquals(noFocusSuppression[42]?.restoreWindowId, 1)
        assertEquals(noFocusSuppression[42]?.pid, 99)
    }

    func testPreArmSkipsWindowConditionedRule() {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(
                    appId: "com.example.app",
                    windowTitleRegexSubstring: .new("Notification").getOrDie(),
                )),
                noFocus: true,
                rawRun: .empty,
            ),
        ]

        // Title can't be evaluated before the window is in the tree — must NOT pre-arm
        preArmNoFocusSuppression(windowId: 42, pid: 99, appBundleId: "com.example.app", appName: nil)

        assertEquals(noFocusSuppression.isEmpty, true)
    }

    func testPreArmSkipsNonMatchingApp() {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(appId: "com.example.app")),
                noFocus: true,
                rawRun: .empty,
            ),
        ]

        preArmNoFocusSuppression(windowId: 42, pid: 99, appBundleId: "com.other.app", appName: nil)

        assertEquals(noFocusSuppression.isEmpty, true)
    }

    func testPreArmSkipsCommandMatcherAndNonNoFocusRules() {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(matcher: .command(.empty), noFocus: true, rawRun: .empty), // Command matcher: needs the window
            WindowDetectedCallback( // Matching app, but no-focus not set
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(appId: "com.example.app")),
                rawRun: .empty,
            ),
        ]

        preArmNoFocusSuppression(windowId: 42, pid: 99, appBundleId: "com.example.app", appName: nil)

        assertEquals(noFocusSuppression.isEmpty, true)
    }
}
