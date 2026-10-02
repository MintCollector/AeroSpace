# `expect-window` Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto-execute-plan to implement this plan task-by-task.

**Goal:** Add `aerospace expect-window`: arm a one-shot expectation so the *next* new window meeting the given conditions doesn't take focus, skips `[[on-window-detected]]` rules, and gets the given commands run on it instead.

**Architecture:** A `@MainActor` FIFO registry of pending expectations (`Sources/AppBundle/windowExpectations.swift`). On AX `windowCreated`, any pending expectation whose *app* conditions match pre-arms the existing `noFocusSuppression` entry. This doesn't consume the expectation: the title isn't known yet and the window may turn out to be a popup. At detection (`tryOnWindowDetected`), the first pending expectation whose full conditions (title included) match is consumed. Its commands run with `AEROSPACE_WINDOW_ID`, in place of config rules. Reuses `LegacyWindowDetectedCallbackMatcher`, `armNoFocusSuppression` and `parseCommand(…, allowExecAndForget: true)`.

**Tech Stack:** Swift, XCTest (AppBundleTests), AeroSpace CmdArgs/Command framework, asciidoc help generation.

**Worktree:** `EnterWorktree` with name `expect-window` (branch: `feature/expect-window`)

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output

**Commands** (repo root): build `make check` · tests `./swift-test.sh` (focused: `swift test --filter <Class>`) · format before every commit `make format` · regenerate help after editing `docs/aerospace-*.adoc`: `bash script/generate-cmd-help.sh`

---

## Context

The user has scripts that open windows in apps they also use by hand (browser, kitty, Finder, …). Today a new window takes focus, and `[[on-window-detected]]` rules can only match a whole app, so they'd also hit the user's own windows. The goal is to identify "the next window that meets these conditions", stop it taking focus, and run custom actions on it: move it to a workspace, float/size it, label the workspace, or run a shell command.

**Shaping decisions (agreed with user):**
- **Matching:** one-shot, i.e. the next new window satisfying ALL given conditions: `--app-id`, `--app-name-regex-substring`, `--window-title-regex-substring`. At least one condition is required. No pid.
- **Delivery:** actions are inline in the same command. It returns immediately and AeroSpace applies them when the window appears. Actions are positional args after `--`, one command each (mirrors the TOML `run = [...]` array). `exec-and-forget` is allowed, so arbitrary shell works, e.g. `exec-and-forget aero-helper label -s CC5 'PR review'`.
- **Rules:** a claimed window skips `[[on-window-detected]]` rules entirely. The `window-detected` subscribe event still fires.
- **Arm only:** the command doesn't launch anything. The script arms first, then opens the window.
- **Focus:** a claimed window never takes focus (that's the point). `--timeout <seconds>` defaults to 10. Expired expectations are dropped lazily.

```bash
aerospace expect-window --app-id com.google.Chrome --window-title-regex-substring 'PR #23' -- \
    'move-node-to-workspace CC5-Aerospace' 'layout floating' 'exec-and-forget aero-helper label -s CC5-Aerospace "PR 23"'
open -g 'https://github.com/…/pull/23'
```

**Key mechanics (verified):**
- `noFocusSuppression` / `armNoFocusSuppression` / `preArmNoFocusSuppression` / `fastBounceNoFocusSuppression` live in `Sources/AppBundle/focusCache.swift:105-215`. The bounce paths are entry-driven, so any entry we insert is enforced everywhere.
- AX `windowCreated` hook (pre-tree-registration): `Sources/AppBundle/layout/refresh.swift:190-194`.
- New-window detection path: `tryOnWindowDetected` (`Sources/AppBundle/tree/MacWindow.swift:273`), which skips popups/unbound windows. `onWindowDetected` (`:284`) is ALSO called by `run-callback` for existing windows, so the expectation hook goes in `tryOnWindowDetected`, not `onWindowDetected`.
- Legacy match logic currently lives inline in `WindowDetectedCallback.matches` (`MacWindow.swift:306-334`). `matchesAppBeforeDetection` is `fileprivate` in `focusCache.swift:151`.
- CLI parser rejects repeated options ("Duplicated option", `parseSpecificCmdArgs.swift:20`). That's why commands are positional after `--`, like `echo` (`EchoCmdArgs.swift`).
- `parseCommand(raw, allowExecAndForget: true, allowEval: false)` + `.newCompound(shells, Shell<any Command>.seq)` is exactly how config `run` arrays are built (`parseConfig.swift:218-232`).
- Tests: `TestWindow.new(id:parent:title:)`; `TestApp` bundle id is `bobko.AeroSpace.test-app`; `await tryOnWindowDetected(window)` drives detection (see `NoFocusSuppressionTest.swift`).

**Known limitations (document them, don't fix them):**
- `aero-helper run` joins and re-splits args on whitespace, so call `aerospace expect-window` directly, not through aero-helper.
- A `focus` command in the actions would be bounced by the suppression.
- While an expectation is armed, *any* new same-app window gets ≤1s of focus protection at creation, even one that turns out not to match the title. Accepted: it's brief and only happens during the armed window.

---

### Task 1: Set Up Worktree

**Step 1: Validate You Are In A Worktree** — if not, `EnterWorktree` with `name: "expect-window"`. Save this plan into `docs/plans/` via `mcp__project-tools__write_plan` (feature `expect-window`).

**Step 2: Verify clean baseline** — `make check` → build succeeds.

---

### Task 2: Extract `LegacyWindowDetectedCallbackMatcher.matches(_:)` (pure refactor)

**Files:** Modify `Sources/AppBundle/tree/MacWindow.swift:306-334`, `Sources/AppBundle/focusCache.swift:148-170`

**Step 1:** Move the `.legacy` branch body of `WindowDetectedCallback.matches` into:

```swift
extension LegacyWindowDetectedCallbackMatcher {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        if let startupMatcher = duringAeroSpaceStartup, startupMatcher != isStartup {
            return false
        }
        if let regex = windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
            return false
        }
        if let appIds, !appIds.contains(window.app.rawAppBundleId ?? "") {
            return false
        }
        if let regex = appIdRegexSubstring, !(window.app.rawAppBundleId ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let regex = appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}
```
and make the callback's branch `case .legacy(let matcher): return await matcher.matches(window)`.

**Step 2:** In `focusCache.swift`, drop `fileprivate` from `matchesAppBeforeDetection` (it's reused by Task 4).

**Step 3:** `swift test --filter ConfigTest` and `swift test --filter NoFocusSuppressionTest` → PASS (behaviour unchanged).

**Step 4:** `make format && git commit -am "refactor: extract LegacyWindowDetectedCallbackMatcher.matches"`

---

### Task 3: `ExpectWindowCmdArgs` (CLI parsing)

**Files:**
- Create: `Sources/Common/cmdArgs/impl/ExpectWindowCmdArgs.swift`
- Modify: `Sources/Common/cmdArgs/cmdArgsManifest.swift` (add `case expectWindow = "expect-window"` to `CmdKind`, alphabetical; `result[kind.rawValue] = SubCommandParser(parseExpectWindowCmdArgs)`)
- Create: `docs/aerospace-expect-window.adoc` (copy the structure of `docs/aerospace-eval.adoc`; synopsis below), then `bash script/generate-cmd-help.sh` (produces `expect_window_help_generated`)
- Test: `Sources/AppBundleTests/command/ExpectWindowCmdArgsTest.swift`

Synopsis for the adoc:
```
aerospace expect-window [-h|--help] [--app-id <app-bundle-id>] [--app-name-regex-substring <regex>]
                        [--window-title-regex-substring <regex>] [--timeout <seconds>] [--] [<command>...]
```

**Step 1: Failing tests** (pattern: existing `*CmdArgsTest` using `parseCommand(...)`/`parseCmdArgs(...)`):
- `expect-window --app-id com.x -- 'layout floating' 'exec-and-forget echo hi'` parses: `appId == "com.x"`, `commands == ["layout floating", "exec-and-forget echo hi"]`, `timeoutSeconds == nil`.
- `--window-title-regex-substring 'PR #\d+' --timeout 5` parses the regex (`.origin == "PR #\\d+"`) and `timeoutSeconds == 5`.
- No conditions (`expect-window -- 'layout floating'`) fails with "At least one of --app-id, --app-name-regex-substring, --window-title-regex-substring is required".
- Invalid regex `--app-name-regex-substring '('` fails.
- Zero commands (`expect-window --app-id com.x`) is valid (window just doesn't take focus and skips rules).

**Step 2:** `swift test --filter ExpectWindowCmdArgsTest` → compile failure.

**Step 3: Implement**
```swift
public struct ExpectWindowCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .expectWindow,
        help: expect_window_help_generated,
        flags: [
            "--app-id": singleValueSubArgParser(\.appId, "<app-bundle-id>", Result.success),
            "--app-name-regex-substring": singleValueSubArgParser(\.appNameRegexSubstring, "<regex>", CaseInsensitiveRegex.new),
            "--window-title-regex-substring": singleValueSubArgParser(\.windowTitleRegexSubstring, "<regex>", CaseInsensitiveRegex.new),
            "--timeout": singleValueSubArgParser(\.timeoutSeconds, "<seconds>", parseUInt32),
        ],
        posArgs: [
            dashDashArg(mandatory: false),
            ArgParser(\.commands, consumeAllStrPosArgs),
        ],
        conflictingOptions: [],
    )

    public var appId: String? = nil
    public var appNameRegexSubstring: CaseInsensitiveRegex? = nil
    public var windowTitleRegexSubstring: CaseInsensitiveRegex? = nil
    public var timeoutSeconds: UInt32? = nil
    public var commands: [String] = []
    /*conforms*/ public typealias ExitCodeType = BinaryExitCode
}

public func parseExpectWindowCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ExpectWindowCmdArgs> {
    parseSpecificCmdArgs(ExpectWindowCmdArgs(rawArgs: args), args)
        .filter("At least one of --app-id, --app-name-regex-substring, --window-title-regex-substring is required") {
            $0.appId != nil || $0.appNameRegexSubstring != nil || $0.windowTitleRegexSubstring != nil
        }
}

private func consumeAllStrPosArgs(i: PosArgParserInput) -> ParsedCliArgs<[String]> {
    let args = i.args.slice(i.index...).orDie().toArray()
    return .succ(args, advanceBy: args.count)
}
```
(If `ArgParser(\.commands, …)` needs an optional key path for posArgs, follow `FullscreenCmdArgs`'s `posArgs: [ArgParser(\.toggle, parseToggleEnum)]` shape. `ExitCodeType` follows whatever the protocol requires; check `EvalCmdArgs`.)

**Step 4:** Add a stub `case .expectWindow: command = ExpectWindowCommand(args: self as! ExpectWindowCmdArgs)` to `Sources/AppBundle/command/cmdManifest.swift` and a stub `ExpectWindowCommand` returning `.succ`, so everything compiles. Tests → PASS.

**Step 5:** `make format && git add -A && git commit -m "feat(cli): parse expect-window"`

---

### Task 4: Expectation registry + pre-arm + detection hook

**Files:**
- Create: `Sources/AppBundle/windowExpectations.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift` (`tryOnWindowDetected`, plus extract `broadcastWindowDetected`)
- Modify: `Sources/AppBundle/layout/refresh.swift:190-194`
- Test: `Sources/AppBundleTests/tree/WindowExpectationTest.swift`

**Step 1: Failing tests.** `setUp`: `setUpWorkspacesForTests(); resetFocusCacheState(); resetWindowExpectations()`. Helper: `appMatcher = LegacyWindowDetectedCallbackMatcher(appId: "bobko.AeroSpace.test-app")`, and commands are built with `parseCommand("move-node-to-workspace X", allowExecAndForget: true, allowEval: false).cmdOrNil!`.
1. **Claims and runs:** focused window 1 on ws A; arm with `move-node-to-workspace X`; new window 2 → `await tryOnWindowDetected(w2)` → `w2.nodeWorkspace?.name == "X"`, `focus.windowOrNil?.windowId == 1`, `noFocusSuppression[2]?.restoreWindowId == 1`, `pendingWindowExpectations.isEmpty`.
2. **Replaces config rules:** `config.onWindowDetected = [rule moving to "Y"]`; armed expectation moves to "X" → window ends in X.
3. **One-shot:** second matching window afterwards goes through config rules (lands in Y).
4. **Non-match passes through:** expectation with `appId: "com.other"` → window untouched by it, expectation still pending, config rules ran.
5. **Title condition:** `windowTitleRegexSubstring: "PR #23"`. A window titled "inbox" is not claimed; a later one titled "Fix — PR #23" is claimed.
6. **FIFO:** two expectations (→X then →Z), both matching; first window → X, second → Z.
7. **Expiry:** arm with `now: t0, timeout: 1`; detect with `now` past the deadline → not claimed, `pendingWindowExpectations.isEmpty` (dropped).
8. **Pre-arm doesn't consume:** `preArmWindowExpectations(windowId: 9, pid: 1, appBundleId: "bobko.AeroSpace.test-app", appName: nil)` → returns true, `noFocusSuppression[9] != nil`, expectation still pending. With a title-only expectation that has no app condition, it still pre-arms (app part trivially matches). With a non-matching app it returns false and inserts no entry.

**Step 2:** `swift test --filter WindowExpectationTest` → compile failure.

**Step 3: Implement** `windowExpectations.swift`:
```swift
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
) -> Int {
    let id = nextWindowExpectationId
    nextWindowExpectationId += 1
    pendingWindowExpectations.append(WindowExpectation(id: id, matcher: matcher, commands: commands, deadline: now.addingTimeInterval(timeout)))
    focusLog("[expect-window] #\(id) armed for \(timeout)s")
    return id
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
    for candidate in pendingWindowExpectations where await candidate.matcher.matches(window) {
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
```
In `MacWindow.swift`, extract the `broadcastEvent(.windowDetected(…))` block from `onWindowDetected` into `@MainActor func broadcastWindowDetected(_ window: Window)`, call it from `onWindowDetected`, and change `tryOnWindowDetected`'s real-window branch to:
```swift
if let expectation = await takeWindowExpectation(for: window) {
    await runWindowExpectation(expectation, window)
} else {
    _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
}
```
In `refresh.swift:193`, call `_ = preArmWindowExpectations(windowId:pid:appBundleId:appName:)` immediately before the existing `preArmNoFocusSuppression(...)`. That call is a no-op when an entry already exists, so the two compose.
Use the injectable `now:` in tests 7 (arm with `now: t0`; `takeWindowExpectation(for:now:)` with a later `now`).

**Step 4:** `swift test --filter WindowExpectationTest`, then `swift test --filter NoFocusSuppressionTest` and `--filter RunCallbackCommandTest` → PASS.

**Step 5:** `make format && git add -A && git commit -m "feat: window expectation registry, pre-arm and detection hook"`

---

### Task 5: `ExpectWindowCommand` (arm from the CLI)

**Files:** `Sources/AppBundle/command/impl/ExpectWindowCommand.swift` (replace stub); test `Sources/AppBundleTests/command/ExpectWindowCommandTest.swift`

**Step 1: Failing tests**
- `expect-window --app-id bobko.AeroSpace.test-app -- 'move-node-to-workspace X'` run via `parseCommand(...).cmdOrDie.run(.defaultEnv, .emptyStdin)` → exit 0, one pending expectation with `matcher.appIds == ["bobko.AeroSpace.test-app"]`, deadline ≈ now+10s. Then `tryOnWindowDetected(newWindow)` → window in X (end-to-end).
- `--timeout 3` → deadline ≈ now+3s.
- An unparsable command (`-- 'no-such-command'`) → non-zero exit, stderr names the bad command, nothing armed.
- `'exec-and-forget true'` is accepted (armed).

**Step 2:** run → FAIL.

**Step 3: Implement**
```swift
import Common

struct ExpectWindowCommand: Command {
    let args: ExpectWindowCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        var shells: [Shell<any Command>] = []
        for raw in args.commands {
            switch parseCommand(raw, allowExecAndForget: true, allowEval: false) {
                case .cmd(let shell): shells.append(shell)
                case .help: return .fail(io.err("--help is not supported inside expect-window commands"))
                case .failure(let f): return .fail(io.err("Can't parse expect-window command \(raw.singleQuoted): \(f.msg)"))
            }
        }
        let matcher = LegacyWindowDetectedCallbackMatcher(
            appId: args.appId,
            appNameRegexSubstring: args.appNameRegexSubstring,
            windowTitleRegexSubstring: args.windowTitleRegexSubstring,
        )
        _ = armWindowExpectation(matcher: matcher, commands: .newCompound(shells, Shell<any Command>.seq), timeout: TimeInterval(args.timeoutSeconds ?? 10))
        return .succ
    }
}
```
(If `.fail(_ IoSideEffect)` doesn't exist, mirror `.succ(_:)` in `ExitCode.swift` or write `io.err(...); return .fail`.)

**Step 4:** tests → PASS; `./swift-test.sh` → `✅ Swift tests have passed successfully`.

**Step 5:** `make format && git add -A && git commit -m "feat: expect-window command arms one-shot window expectations"`

---

### Task 6: Docs

**Files:** `docs/aerospace-expect-window.adoc` (full description: one-shot semantics, AND conditions, FIFO, timeout, rules skipped, `window-detected` event still fires, the title-condition caveat, the "don't wrap in aero-helper" note, examples incl. the `exec-and-forget aero-helper label` one), `docs/commands.adoc` (add entry like the `scroll` one), `grammar/commands-bnf-grammar.txt` (add `expect-window` production), `docs/guide.adoc` (one-line cross-reference under `on-window-detected`'s `no-focus` paragraph: "for a single scripted window, see expect-window"). Run `bash script/generate-cmd-help.sh`. Commit: `docs: expect-window`.

---

### Task 7: Live verification + deploy

1. `make deploy` (rebuilds the release, installs, restarts). Prove the installed binary has the change: `aerospace expect-window --help` prints the new synopsis.
2. Live run without disturbing the user: `aerospace expect-window --app-id com.apple.TextEdit --timeout 15 -- 'move-node-to-workspace zzArc'` then `open -g -a TextEdit` (or `open -a TextEdit ~/scratch.txt`). Expect: the window appears on `zzArc`, the focused window and workspace don't change, and `/tmp/aerospace-focus-cache.log` shows `[expect-window] #N armed` → `pre-armed` → `claimed window`. Close the TextEdit window afterwards.
3. Timeout: arm with `--timeout 2`, wait, check the log shows `expired` on the next detection and that a later TextEdit window follows normal rules.
4. Push the branch, open a PR against `MintCollector/AeroSpace`, and wait for CI.

---

## Executive Summary

**What exists today:**
- `[[on-window-detected]]` rules with `no-focus = true` (`focusCache.swift`) stop windows taking focus, but only for every window of an app (or one with a matching title) for as long as the config says so. There's no way for a script to say "just the window I'm about to open".
- Custom handling exists only as config rules (`run = [...]`), so a script can't attach one-off actions to its own window.

**What we're moving to:**
- `aerospace expect-window --app-id …/--app-name-regex-substring …/--window-title-regex-substring … [--timeout s] -- '<cmd>' …` arms a one-shot, FIFO, time-limited expectation in a new registry (`windowExpectations.swift`).
- On AX create, a possibly-matching window is shielded right away by the existing no-focus machinery. At detection, the first fully-matching expectation is consumed: config rules are skipped, and its commands (including `exec-and-forget`) run with `AEROSPACE_WINDOW_ID`.

**Why:**
- Lets scripts open windows in apps the user also uses by hand (browser, kitty, Finder) without stealing focus, and route or float or label each window precisely. All of it reuses the battle-tested suppression/bounce paths instead of adding a second focus mechanism.
