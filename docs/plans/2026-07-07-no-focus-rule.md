# `no-focus` on-window-detected Rule Option — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Add a per-rule `no-focus = true` option to `[[on-window-detected]]` config rules that prevents newly detected windows from stealing focus, by bouncing native focus back to the previously focused window during a ~1s suppression window.

**Architecture:** Two-part mechanism. (1) **Arm:** when a matched rule has `no-focus`, `onWindowDetected()` records a suppression entry `{detectedWindowId → restoreWindowId, deadline}` in a `@MainActor` registry in `focusCache.swift`. (2) **Bounce:** `updateFocusCache()` — the single funnel where native macOS focus becomes AeroSpace model focus — refuses to adopt a suppressed window (preventing the visible-workspace flip, since adoption is what calls `setActiveWorkspace`) and pushes native focus back to the restore target. Mirrors the existing `lastWindowDestroyedDate` suppression precedent at `focusCache.swift:57-66`.

**Tech Stack:** Swift, XCTest (AppBundleTests), TOML config parsing, macOS AX API.

**Worktree:** `EnterWorktree` with name `no-focus-rule` (branch: `feature/no-focus-rule`)

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

**Commands used throughout** (run from repo root):
- Build: `make check` (= `swift build --arch arm64`)
- Full test suite: `./swift-test.sh` (wraps `swift test` with the swiftly toolchain; prints `✅ Swift tests have passed successfully`)
- Focused test run: `swift test --filter <TestClassName>` (fall back to `./swift-test.sh` if the plain toolchain mismatches)
- Format before every commit: `make format` (CI lints with swiftformat)

---

## Context

**Problem:** Google Chrome for Testing (`com.google.chrome.for.testing`, the Playwright-managed browser used by sc-extension automation) opens windows while the user works elsewhere. Each new window natively activates, and AeroSpace follows native focus — yanking keyboard focus and flipping the visible workspace to wherever the window landed (currently 3-D).

**Why a config flag and not a callback command:** AeroSpace never focuses new windows itself (`moveWindowToWorkspace` defaults `focusFollowsWindow: false`); the steal is macOS-level app activation, which can land *before or after* AeroSpace's detection callbacks run. A one-shot "refocus previous" command inside `run` would lose that race. A time-windowed suppression armed at detection catches the activation regardless of ordering.

**Key mechanics (verified during exploration):**
- `updateFocusCache(_ nativeFocused:)` (`Sources/AppBundle/focusCache.swift:35`) is called at the top of every heavy/light refresh session (`refresh.swift:43-45,77-79`) and adopts native focus into the model via `focusWindow()` → `setFocus()` → `setActiveWorkspace()` (`focus.swift:75`) — adoption is what flips the visible workspace, so suppression must happen *before* adoption, not undo it after.
- The fork already has a time-based suppression precedent in the exact same spot: the `lastWindowDestroyedDate.distance(to: .now) < 0.5` cross-workspace guard (`focusCache.swift:57-66`).
- The model+native restore pair precedent: `MacWindow.swift:184-198` (`setFocus` + `nativeFocus()` — "Force focus to fix macOS annoyance #65").
- Fully unit-testable: `TestWindow.nativeFocus()` sets `TestApp.shared.focusedWindow`, which is what `getNativeFocusedWindow` reads under `isUnitTest` — the arm→steal→bounce loop runs entirely in XCTest.
- `updateFocusCache` currently uses `macAppUnsafe` (`app as! MacApp`) which would crash tests driving it with `TestWindow` → safe-cast refactor included (behavior-preserving in production).

## Key design decisions

1. **Registry lives in `focusCache.swift`** next to the existing precedent. Entries keyed by `windowId: UInt32`, storing optional `restoreWindowId` and `deadline: Date`. Window **ids**, not `Window` references (per the FrozenFocus rule at `focus.swift:30-32`: never memorize `LiveFocus`/`Window`).
2. **Arm point** is inside the `onWindowDetected` callback loop (`MacWindow.swift:398`), *before* `callback.run.run(...)`, so suppression is active regardless of what the run commands do. Arming is a plain dict write — idempotent across multiple matched rules (`check-further-callbacks`) and AX re-registration churn (a re-fire merely refreshes a 1s entry).
3. **Arm-time restore selection + immediate bounce:** if model focus is *already* the detected window at arm time (activation raced ahead of detection), the restore target is `prevFocus?.windowOrNil` (`focus.swift:139`) and the arm function bounces **immediately** (model `focusWindow()` + `nativeFocus()`), because `updateFocusCache` will never re-fire for it (`lastKnownNativeFocusedWindowId` already adopted it). Otherwise the restore target is the current `focus.windowOrNil` and the suppression branch catches the grab on the next refresh.
4. **Bounce point** is a new branch in `updateFocusCache` inside the `windowId != lastKnownNativeFocusedWindowId` block, after the popup/sticky early-returns, before the destroy-suppression branch and the `focusWindow()` adoption. Unlike the destroy-suppression, it is **not** conditioned on cross-workspace: a same-workspace steal is also refused.
5. **Bounce target = current model focus, remembered id as fallback.** Since we never adopt the suppressed grab, `focus.windowOrNil` remains "the window the user considers focused". The stored `restoreWindowId` is used for the arm-time immediate bounce and as fallback when model focus is nil. If both resolve to nothing (window destroyed), refuse adoption without bouncing.
6. **After a bounce, memorize the SUPPRESSED window id** in `lastKnownNativeFocusedWindowId` (follow precedent), not the restore id. The round-trip is coherent: the async bounce lands, the next refresh adopts the restore window through the normal path where `setFocus` early-returns (model never left it). Memorizing the restore id instead would re-enter the branch and re-issue `nativeFocus()` every refresh until the bounce lands — a focus war with the app. Repeat grabs after the bounce lands still get suppressed (ids differ again, TTL permitting).
7. **Testability:** `now: Date = Date()` injectable parameters (idiom from `MacApp.shouldThrottleFailedRegistration`, `MacApp.swift:45`); `resetFocusCacheState()` helper for test isolation (`setUpWorkspacesForTests()` does not reset focus-cache module state).

---

### Task 1: Set Up Worktree

**Step 1: Validate you are in a worktree**
Validate work is being done in a worktree. If not, use the `EnterWorktree` tool with `name: "no-focus-rule"` to create an isolated worktree.

**Step 2: Verify clean baseline**
```bash
make check
```
Expected: build succeeds. If not, investigate before proceeding.

---

### Task 2: Parse `no-focus` in `[[on-window-detected]]`

**Files:**
- Modify: `Sources/AppBundle/config/parseOnWindowDetected.swift` (struct at line 3, parser table at line 117)
- Test: `Sources/AppBundleTests/config/ConfigTest.swift`

**Step 1: Write the failing test**

Append to `ConfigTest.swift` (after `testParseOnWindowDetected2`, ~line 434):

```swift
    func testParseOnWindowDetectedNoFocus() {
        let result = parseConfig(
            """
            on-window-detected = [
                { if.app-id = 'com.google.chrome.for.testing', no-focus = true, run = [] },
                { if = 'true', run = [] },
            ]
            """,
        )
        assertEquals(result.config.onWindowDetected, [
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(
                    appId: "com.google.chrome.for.testing",
                )),
                noFocus: true,
                rawRun: .empty,
            ),
            WindowDetectedCallback( // no-focus defaults to false
                matcher: .command(.cmd(TrueCommand.instance)),
                rawRun: .empty,
            ),
        ])
        assertEquals(result.strErrors, [])

        // no-focus participates in equality
        assertNotEquals(
            WindowDetectedCallback(matcher: .command(.empty), noFocus: true, rawRun: .empty),
            WindowDetectedCallback(matcher: .command(.empty), rawRun: .empty),
        )
    }
```

Notes: `run = []` is legal — the parser only requires the `run` *key* present (ID-46D063B2, `parseOnWindowDetected.swift:194`); existing test entry at `ConfigTest.swift:334-337` already parses `run = []` to `.empty`. `assertNotEquals` is at `assert.swift:16`. The `.command(.cmd(TrueCommand.instance))` expectation form matches `ConfigTest.swift:363`.

**Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigTest`
Expected: **compile failure** (no `noFocus` member). That is the failing state.

**Step 3: Implement**

In `parseOnWindowDetected.swift`, add the field between `checkFurtherCallbacks` and `rawRun` (all fields have defaults, so existing call sites keep compiling), extend `debugJson` and `==`:

```swift
struct WindowDetectedCallback: ConvenienceMutable, Equatable {
    var matcher: WindowDetectedCallbackMatcher = .command(.empty)
    var checkFurtherCallbacks: Bool = false
    var noFocus: Bool = false
    var rawRun: Shell<any Command>? = nil

    var run: Shell<any Command> {
        rawRun ?? dieT("ID-46D063B2 should have discarded nil")
    }

    var debugJson: Json {
        var result: [String: Json] = [:]
        result["matcher"] = switch matcher {
            case .command(let command): .string(command.shellOfCommandsDescription)
            case .legacy(let legacy): legacy.debugJson
        }
        if let commands = rawRun {
            result["commands"] = .string(commands.shellOfCommandsDescription)
        }
        if noFocus {
            result["no-focus"] = .bool(true)
        }
        return .dict(result)
    }

    static func == (lhs: WindowDetectedCallback, rhs: WindowDetectedCallback) -> Bool {
        lhs.matcher == rhs.matcher && lhs.checkFurtherCallbacks == rhs.checkFurtherCallbacks &&
            lhs.noFocus == rhs.noFocus && lhs.run.strictEquals(rhs.run)
    }
}
```

Parser table (line 117):

```swift
private let windowDetectedParser: [String: any ParserProtocol<WindowDetectedCallback>] = [
    "if": Parser(\.matcher, parseMatcher),
    "check-further-callbacks": Parser(\.checkFurtherCallbacks, parseBool),
    "no-focus": Parser(\.noFocus, parseBool),
    "run": Parser(\.rawRun, parseShellOfCommandsForConfig),
]
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTest` → all pass. Then `make check` → clean build.

**Step 5: Commit**

```bash
make format
git add Sources/AppBundle/config/parseOnWindowDetected.swift Sources/AppBundleTests/config/ConfigTest.swift
git commit -m "feat(config): parse 'no-focus' key in [[on-window-detected]] rules"
```

---

### Task 3: Suppression registry + arm on detection

**Files:**
- Modify: `Sources/AppBundle/focusCache.swift` (append)
- Modify: `Sources/AppBundle/tree/MacWindow.swift:397-404` (`onWindowDetected` loop)
- Create: `Sources/AppBundleTests/tree/NoFocusSuppressionTest.swift`

**Step 1: Write the failing tests**

Create `Sources/AppBundleTests/tree/NoFocusSuppressionTest.swift`:

```swift
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
```

Notes: the `Workspace.get(byName: name)` / `TestWindow.new` / `tryOnWindowDetected` pattern mirrors `OnWindowDetectedTest.swift`. `checkOnFocusChangedCallbacks_nonCancellable()` is safe in tests (`refreshSessionEvent` is nil; defaultConfig has no on-focus-changed commands). `TestWindow.nativeFocus()` sets `TestApp.shared.focusedWindow` (`TestWindow.swift:24-28`).

**Step 2: Run tests to verify they fail**

Run: `swift test --filter NoFocusSuppressionTest`
Expected: **compile failure** (`noFocusSuppression`, `resetFocusCacheState` don't exist).

**Step 3: Implement**

Append to `Sources/AppBundle/focusCache.swift`:

```swift
// MARK: - 'no-focus' suppression ([[on-window-detected]] rules with no-focus = true)

struct NoFocusSuppressionEntry {
    let restoreWindowId: UInt32?
    let deadline: Date
}

let noFocusSuppressionTtl: TimeInterval = 1.0
/// windowId of the detected window -> suppression entry.
/// Expired entries are dropped lazily in updateFocusCache.
@MainActor var noFocusSuppression: [UInt32: NoFocusSuppressionEntry] = [:]

/// Called from onWindowDetected when a matched rule has 'no-focus = true'.
/// For noFocusSuppressionTtl seconds, native focus grabs by `window` are refused and bounced
/// back to the remembered window (see updateFocusCache).
/// Re-arming (multiple matched rules, or AX re-registration re-firing on-window-detected for an
/// old window) is harmless: the entry is simply refreshed.
@MainActor func armNoFocusSuppression(for window: Window, now: Date = Date()) {
    let modelFocusedId = focus.windowOrNil?.windowId
    // If the detected window has already grabbed the model focus (activation raced detection),
    // the pre-steal focus lives in prevFocus. Otherwise the current focus is the restore target.
    let restoreWindowId: UInt32? = modelFocusedId == window.windowId
        ? prevFocus?.windowOrNil?.windowId
        : modelFocusedId
    noFocusSuppression[window.windowId] = NoFocusSuppressionEntry(
        restoreWindowId: restoreWindowId,
        deadline: now.addingTimeInterval(noFocusSuppressionTtl),
    )
    focusLog("[focus-cache] no-focus armed for window \(window.windowId) (app: \(window.app.name ?? "?")), restore target: \(restoreWindowId.map(String.init) ?? "nil")")
    // The steal already happened before the rule armed. updateFocusCache won't re-fire for this
    // window (lastKnownNativeFocusedWindowId already adopted it), so undo the grab right away.
    if modelFocusedId == window.windowId, let restore = restoreWindowId.flatMap({ Window.get(byId: $0) }) {
        _ = restore.focusWindow()
        restore.nativeFocus()
        focusLog("[focus-cache] no-focus immediate bounce: window \(window.windowId) -> restore window \(restore.windowId)")
    }
}

/// Test-only. Resets focusCache module state between unit tests.
@MainActor func resetFocusCacheState() {
    lastKnownNativeFocusedWindowId = nil
    noFocusSuppression = [:]
    lastWindowDestroyedDate = .distantPast
}
```

Edit `Sources/AppBundle/tree/MacWindow.swift`, `onWindowDetected` loop:

```swift
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        if callback.noFocus {
            // Arm before (and regardless of) the run commands, so the suppression is active
            // even if a run command fails or moves the window.
            armNoFocusSuppression(for: window)
        }
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
```

(`tryOnWindowDetected` at `MacWindow.swift:378` already skips popup/unbound parents, so popup windows never arm.)

**Step 4: Run tests to verify they pass**

Run: `swift test --filter NoFocusSuppressionTest` → 4 tests pass.
Run: `swift test --filter OnWindowDetectedTest` and `swift test --filter ConfigTest` → still pass. `make check` → clean.

**Step 5: Commit**

```bash
make format
git add Sources/AppBundle/focusCache.swift Sources/AppBundle/tree/MacWindow.swift Sources/AppBundleTests/tree/NoFocusSuppressionTest.swift
git commit -m "feat: arm no-focus suppression when a matched on-window-detected rule has no-focus"
```

---

### Task 4: Bounce native focus grabs in `updateFocusCache`

**Files:**
- Modify: `Sources/AppBundle/focusCache.swift:35-76` (`updateFocusCache`)
- Test: `Sources/AppBundleTests/tree/NoFocusSuppressionTest.swift` (append)

**Step 1: Write the failing tests**

Append to `NoFocusSuppressionTest.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter NoFocusSuppressionTest`
Expected: compile error on the `now:` label first; after adding only the parameter, behavioral failures. (Without the `macAppUnsafe` safe-cast refactor in Step 3, the expiry/no-rule tests would **crash** on `app as! MacApp`.)

**Step 3: Implement**

Rewrite `updateFocusCache` in `focusCache.swift`:

```swift
/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?, now: Date = Date()) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        focusLog("[focus-cache] skip popup window \(nativeFocused?.windowId ?? 0)")
        return
    }
    if let macWindow = nativeFocused as? MacWindow,
       macWindow.isSticky,
       macWindow.visualWorkspace != focus.workspace
    {
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        macWindow.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        let oldId = lastKnownNativeFocusedWindowId.map(String.init) ?? "nil"
        let newId = nativeFocused.map { String($0.windowId) } ?? "nil"
        let app = nativeFocused?.app.name ?? "?"
        let bundleId = nativeFocused?.app.rawAppBundleId ?? "?"
        let nativeWs = nativeFocused?.toLiveFocusOrNil()?.workspace.name ?? "nil"
        let currentWs = focus.workspace.name
        let parentKind = parentKindLabel(nativeFocused)
        // A matched 'on-window-detected' rule with 'no-focus = true' recently fired for this
        // window. Refuse to adopt its native focus grab (adoption is what flips the visible
        // workspace via setFocus -> setActiveWorkspace) and push native focus back to the window
        // the user was working in.
        if let nativeFocused, let entry = noFocusSuppression[nativeFocused.windowId] {
            if entry.deadline <= now {
                noFocusSuppression[nativeFocused.windowId] = nil // Lazily drop expired entries
            } else {
                focusLog("[focus-cache] no-focus suppressed: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(nativeWs)' (focusWs: '\(currentWs)', prev: \(oldId))")
                // Intentionally memorize the SUPPRESSED id (not the restore id), mirroring the
                // window-destroy suppression below. The async bounce lands later; the next refresh
                // then adopts the restore window through the normal path, where setFocus is a
                // no-op because the model never left it. Memorizing the restore id instead would
                // re-enter this branch (and re-issue nativeFocus) on every refresh until the
                // bounce lands - a focus war with the app.
                lastKnownNativeFocusedWindowId = nativeFocused.windowId
                (nativeFocused.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused.windowId
                // The user may have re-focused another window since detection: the live model
                // focus (never contaminated, since we refuse adoption) beats the remembered id.
                let bounceTarget: Window? = focus.windowOrNil
                    ?? entry.restoreWindowId.flatMap { Window.get(byId: $0) }
                if let bounceTarget, bounceTarget.windowId != nativeFocused.windowId {
                    _ = bounceTarget.focusWindow()
                    bounceTarget.nativeFocus() // Model + native pair, see deadWindowFocus in MacWindow
                    focusLog("[focus-cache] no-focus bounce: native focus pushed back to window \(bounceTarget.windowId)")
                }
                return
            }
        }
        // macOS auto-activates same-app windows on other workspaces when the last window
        // of that app is closed on the current workspace. Don't follow it.
        if let nativeFocusedWs = nativeFocused?.toLiveFocusOrNil()?.workspace,
           nativeFocusedWs != focus.workspace,
           lastWindowDestroyedDate.distance(to: .now) < 0.5
        {
            focusLog("[focus-cache] suppressed cross-ws switch: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(nativeWs)' — recent window destroy (focusWs: '\(currentWs)', prev: \(oldId))")
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
            (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
            return
        }
        if nativeWs != currentWs {
            focusLog("[focus-cache] CROSS-WS: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) — switching ws '\(currentWs)' → '\(nativeWs)' (prev: \(oldId))")
        } else {
            focusLog("[focus-cache] native focus changed: window \(newId) (app: \(app), bundle: \(bundleId), parent: \(parentKind)) on ws '\(currentWs)' (prev: \(oldId))")
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    // Safe cast (was macAppUnsafe) so unit tests can drive updateFocusCache with TestWindow.
    // In production, real windows always belong to a MacApp.
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}
```

Only changes vs. current: the `now:` parameter, the new suppression branch, and two `macAppUnsafe` → `(… as? MacApp)?` safe casts. Callers at `refresh.swift:45,79` compile unchanged via the default parameter.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter NoFocusSuppressionTest` → all 8 pass.
Run: `./swift-test.sh` → `✅ Swift tests have passed successfully`. `make check` → clean.

**Step 5: Commit**

```bash
make format
git add Sources/AppBundle/focusCache.swift Sources/AppBundleTests/tree/NoFocusSuppressionTest.swift
git commit -m "feat: bounce native focus grabs from no-focus windows in updateFocusCache"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/guide.adoc:537-620` (`on-window-detected` section; hand-edited — `script/generate-cmd-help.sh` applies only to `docs/aerospace-*.adoc` CLI help, no regen needed)

**Step 1: Add `no-focus` to the reference block** (~line 551, after `check-further-callbacks`):

```
    check-further-callbacks = true
    no-focus = true
    run = ['layout floating', 'move-node-to-workspace S']  # The callback itself
```

**Step 2: Insert explanation + example** after the `check-further-callbacks` example block (~line 580, before "A common use case is to match against app bundle ID"):

```
Additionally, `no-focus = true` prevents the newly detected window from stealing focus.
For about a second after the window is detected, AeroSpace refuses to follow the window's native
focus grabs (so the focused window and the visible workspace stay put) and pushes macOS focus back
to the window you were working in.
It is useful for apps that open windows in the background while you work elsewhere,
e.g. a test runner driving a browser:

[source,toml]
----
[[on-window-detected]]
    if.app-id = 'com.google.chrome.for.testing' # Playwright-driven Chrome
    no-focus = true
    run = []
----
```

**Step 3: Verify build unaffected**

Run: `make check` → clean (docs only).

**Step 4: Commit**

```bash
git add docs/guide.adoc
git commit -m "docs: document no-focus option of on-window-detected callbacks"
```

---

### Task 6: Merge, deploy, user config rollout + manual E2E

**Step 1: Merge to main and deploy**

Merge `feature/no-focus-rule` to `main` (or as the user prefers — fork PRs target `MintCollector/AeroSpace`). Then from the main checkout:

```bash
make deploy
```
(build-release + rsync install + restart; rsync preserves the bundle inode so the Accessibility grant persists.)

**Step 2: Add the user rule**

Add to `~/.config/aerospace/aerospace.toml`, after the catch-all rule at lines 87-89 (`run = "exec-and-forget /opt/homebrew/bin/aero-helper auto-place"`, `check-further-callbacks = true`):

```toml
[[on-window-detected]]
if.app-id = "com.google.chrome.for.testing"
no-focus = true
run = []
```

Ordering: the catch-all has `check-further-callbacks = true`, so `auto-place` still runs first; this rule then matches, arms suppression, and stops further callbacks (default `check-further-callbacks = false`).

Dual-config note: `aero-helper/profiles.toml` contains **no** `on-window-detected` section (verified — zero occurrences), so there is nothing to mirror. Confirm aero-helper doesn't regenerate/overwrite `on-window-detected` in `aerospace.toml`; if it does, add the rule to the generation source instead.

**Step 3: Reload config**

`auto-reload-config` should pick it up; otherwise `aerospace reload-config`. Confirm no config errors.

**Step 4: Manual E2E**

1. Focus a window on some workspace; note the workspace.
2. Run `open -na 'Google Chrome for Testing'` (or drive Playwright).
3. Expected: focus stays on the current window; the visible workspace does not flip.
4. `tail -f /tmp/aerospace-focus-cache.log` — expect: `no-focus armed for window <id>`, then `no-focus suppressed: window <id> ...` and `no-focus bounce: native focus pushed back to window <id>` (or `no-focus immediate bounce` if activation raced detection).
5. After ~1s, click the Chrome for Testing window manually — it must focus normally (suppression expired).
6. Regression: open a Finder window — focus follows as usual; close a window on the current workspace — existing destroy-suppression behavior unchanged.

---

## Edge-case coverage map

| # | Edge case | Where handled |
|---|---|---|
| 1 | Activation races detection (either order) | Arm-time restore selection (`prevFocus` when focus already stolen) + immediate bounce in `armNoFocusSuppression`; normal order caught by the `updateFocusCache` branch. Tests: `testArmRemembers...`, `testArmBouncesImmediately...`, `testUpdateFocusCacheRefuses...` |
| 2 | `check-further-callbacks` with earlier no-focus rule | Arm is a dict write inside the loop, before `run`; later rules still execute. Test: `testArmsOnceEvenWithCheckFurtherCallbacks` |
| 3 | Popup/sticky early-returns ordering | Suppression branch sits inside the `windowId != lastKnown` block, after popup/sticky early-returns, before destroy-suppression — same slot as the existing precedent |
| 4 | Which id to memorize after bounce | Suppressed id (precedent). Justified in Design decision 6 + code comment |
| 5 | `serverArgs.isReadOnly` no-op `nativeFocus` | Accepted; tests use `TestWindow.nativeFocus` override |
| 6 | AX re-registration re-fires detection | Re-arm is harmless (1s TTL, entry refreshed); noted in `armNoFocusSuppression` doc comment |
| 7 | Restore window destroyed while pending | `focus.windowOrNil ?? Window.get(byId:)` both nil → refuse adoption, skip bounce. Test: `testDeadRestoreTargetRefusesAdoptionWithoutBounce` |

---

## Executive Summary

**What exists today:**
- `on-window-detected` rules can move/float new windows, but cannot stop them stealing focus: the steal is macOS-level app activation, which AeroSpace follows via `updateFocusCache` → `focusWindow()` → `setFocus` → `setActiveWorkspace` — flipping the visible workspace to wherever the new window landed.
- The fork already fights adjacent problems in the same funnel: a 0.5s destroy-time cross-workspace suppression in `updateFocusCache` (`focusCache.swift:57-66`), and a "force focus" model+native restore pair in window GC (`MacWindow.swift:184-198`).
- Pain: Playwright's Chrome for Testing opens windows mid-automation and yanks the user's focus and workspace several times per run.

**What we're moving to:**
- A `no-focus = true` key on `[[on-window-detected]]` rules. Matched detection arms a 1s suppression entry; `updateFocusCache` refuses to adopt native focus grabs by that window and bounces macOS focus back to the window the user was in. If activation raced ahead of detection, the arm itself bounces immediately using `prevFocus`.
- ~120 lines of implementation across 3 files + 8 unit tests + docs. No new CLI surface, no changes to upstream-shared command parsing.

**Why:**
- Kills the single most disruptive behavior in the user's automation workflow (focus/workspace yanking during sc-extension Playwright runs) with a composable config primitive that also covers any future background-window app.
- Complements (and partially obviates) the earlier `exec-and-capture` idea: static rules + `no-focus` handle the "launch and stay put" case with zero wrapper tooling.
