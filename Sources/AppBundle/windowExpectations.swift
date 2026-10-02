import AppKit
import Common

/// One-shot expectation armed by `aerospace expect-window`: the next new window matching `matcher`
/// skips [[on-window-detected]] rules and runs `commands` instead. It doesn't take focus, unless
/// `takeFocus` (`--focus`): then it's focused once the commands have placed it.
struct WindowExpectation {
    let id: Int
    let matcher: LegacyWindowDetectedCallbackMatcher
    let commands: Shell<any Command>
    let deadline: Date
    let takeFocus: Bool

    /// Whether the app conditions alone admit this app (the title is checked at detection).
    @MainActor func mayMatchApp(bundleId: String?, appName: String?) -> Bool {
        var appOnly = matcher
        appOnly.windowTitleRegexSubstring = nil
        return appOnly.matchesAppBeforeDetection(bundleId: bundleId, appName: appName)
    }

    var hasAppCondition: Bool {
        matcher.appIds != nil || matcher.appIdRegexSubstring != nil || matcher.appNameRegexSubstring != nil
    }
}

/// FIFO: the oldest matching expectation claims a window. Expired entries are dropped lazily.
@MainActor var pendingWindowExpectations: [WindowExpectation] = []
@MainActor private var nextWindowExpectationId = 1

@MainActor func armWindowExpectation(
    matcher: LegacyWindowDetectedCallbackMatcher,
    commands: Shell<any Command>,
    timeout: TimeInterval,
    takeFocus: Bool = false,
    now: Date = Date(),
) {
    let id = nextWindowExpectationId
    nextWindowExpectationId += 1
    pendingWindowExpectations.append(WindowExpectation(
        id: id,
        matcher: matcher,
        commands: commands,
        deadline: now.addingTimeInterval(timeout),
        takeFocus: takeFocus,
    ))
    focusLog("[expect-window] #\(id) armed for \(timeout)s\(takeFocus ? " (takes focus)" : "")")
}

@MainActor private func dropExpiredWindowExpectations(_ now: Date) {
    pendingWindowExpectations.removeAll { expectation in
        let expired = expectation.deadline <= now
        if expired { focusLog("[expect-window] #\(expectation.id) expired") }
        return expired
    }
}

/// AX windowCreated, before tree registration: shield a window that MAY be expected from focus
/// stealing. Doesn't consume. The title isn't known yet and the window may turn out to be a popup;
/// detection (takeWindowExpectation) decides. `--focus` expectations want the window focused, so they don't shield.
@MainActor func preArmWindowExpectations(windowId: UInt32, pid: pid_t, appBundleId: String?, appName: String?, now: Date = Date()) -> Bool {
    dropExpiredWindowExpectations(now)
    guard noFocusSuppression[windowId] == nil else { return false }
    let mayMatch = pendingWindowExpectations.contains { expectation in
        !expectation.takeFocus && expectation.mayMatchApp(bundleId: appBundleId, appName: appName)
    }
    guard mayMatch else { return false }
    noFocusSuppression[windowId] = NoFocusSuppressionEntry(
        restoreWindowId: focus.windowOrNil?.windowId,
        pid: pid,
        deadline: now.addingTimeInterval(noFocusSuppressionTtl),
    )
    focusLog("[expect-window] pre-armed no-focus for window \(windowId) (bundle: \(appBundleId ?? "?"))")
    return true
}

/// App activation is the first focus steal of a cold launch (or of `open -a` on a running app), and it
/// comes before AX windowCreated, so pre-arming can't cover it. While an expectation with an app
/// condition is pending, refuse activations of a matching app: push native focus back to the focused
/// window. Title-only expectations don't guard, since they'd bounce every app switch, and neither do
/// `--focus` ones: their app is wanted in front, and a keystroke-driven new window needs it there.
/// Windows that already have a suppression entry are left to fastBounceNoFocusSuppression.
@MainActor func bounceExpectedAppActivation(pid: pid_t, appBundleId: String?, appName: String?, now: Date = Date()) -> Bool {
    dropExpiredWindowExpectations(now)
    guard !noFocusSuppression.values.contains(where: { $0.pid == pid }) else { return false }
    let expected = pendingWindowExpectations.contains { expectation in
        !expectation.takeFocus && expectation.hasAppCondition && expectation.mayMatchApp(bundleId: appBundleId, appName: appName)
    }
    guard expected, let restore = focus.windowOrNil, restore.app.pid != pid else { return false }
    restore.nativeFocus()
    focusLog("[expect-window] refused activation of \(appBundleId ?? "?") (pid \(pid)), native focus pushed back to window \(restore.windowId)")
    return true
}

/// Detection: consume the oldest pending expectation whose full conditions match `window`.
@MainActor func takeWindowExpectation(for window: Window, now: Date = Date()) async -> WindowExpectation? {
    dropExpiredWindowExpectations(now)
    for candidate in pendingWindowExpectations {
        guard await candidate.matcher.matches(window) else { continue }
        // Re-find by id: the title await may have let another detection consume it meanwhile.
        guard let index = pendingWindowExpectations.firstIndex(where: { $0.id == candidate.id }) else { continue }
        return pendingWindowExpectations.remove(at: index)
    }
    return nil
}

@MainActor func runWindowExpectation(_ expectation: WindowExpectation, _ window: Window) async {
    broadcastWindowDetected(window)
    if expectation.takeFocus {
        // A shield pre-armed for another pending expectation would bounce the focus below
        noFocusSuppression[window.windowId] = nil
    } else {
        armNoFocusSuppression(for: window) // Refreshes the pre-armed entry and its TTL
    }
    focusLog("[expect-window] #\(expectation.id) claimed window \(window.windowId) (app: \(window.app.name ?? "?"))")
    _ = await expectation.commands.run(.defaultEnv.withWindowId(window.windowId), CmdIoImpl.emptyStdinIgnoringOut)
    if expectation.takeFocus {
        _ = window.focusWindow() // Like `focus --window-id`: the refresh syncs native focus
    }
}

/// Test-only.
@MainActor func resetWindowExpectations() {
    pendingWindowExpectations = []
    nextWindowExpectationId = 1
}
