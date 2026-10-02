import AppKit
import Common

/// One-shot expectation armed by `aerospace expect-window`: the next new window matching `matcher`
/// doesn't take focus, skips [[on-window-detected]] rules, and runs `commands` instead.
struct WindowExpectation {
    let id: Int
    let matcher: LegacyWindowDetectedCallbackMatcher
    let commands: Shell<any Command>
    let deadline: Date
}

/// FIFO: the oldest matching expectation claims a window. Expired entries are dropped lazily.
@MainActor var pendingWindowExpectations: [WindowExpectation] = []
@MainActor private var nextWindowExpectationId = 1

@MainActor func armWindowExpectation(
    matcher: LegacyWindowDetectedCallbackMatcher,
    commands: Shell<any Command>,
    timeout: TimeInterval,
    now: Date = Date(),
) {
    let id = nextWindowExpectationId
    nextWindowExpectationId += 1
    pendingWindowExpectations.append(WindowExpectation(id: id, matcher: matcher, commands: commands, deadline: now.addingTimeInterval(timeout)))
    focusLog("[expect-window] #\(id) armed for \(timeout)s")
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
/// detection (takeWindowExpectation) decides.
@MainActor func preArmWindowExpectations(windowId: UInt32, pid: pid_t, appBundleId: String?, appName: String?, now: Date = Date()) -> Bool {
    dropExpiredWindowExpectations(now)
    guard noFocusSuppression[windowId] == nil else { return false }
    let mayMatch = pendingWindowExpectations.contains { expectation in
        var appOnly = expectation.matcher
        appOnly.windowTitleRegexSubstring = nil
        return appOnly.matchesAppBeforeDetection(bundleId: appBundleId, appName: appName)
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
    armNoFocusSuppression(for: window) // Refreshes the pre-armed entry and its TTL
    focusLog("[expect-window] #\(expectation.id) claimed window \(window.windowId) (app: \(window.app.name ?? "?"))")
    _ = await expectation.commands.run(.defaultEnv.withWindowId(window.windowId), CmdIoImpl.emptyStdinIgnoringOut)
}

/// Test-only.
@MainActor func resetWindowExpectations() {
    pendingWindowExpectations = []
    nextWindowExpectationId = 1
}
