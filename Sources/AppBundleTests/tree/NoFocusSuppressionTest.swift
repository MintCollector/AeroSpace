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
}
