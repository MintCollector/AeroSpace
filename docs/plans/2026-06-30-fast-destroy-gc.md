# Fast Destroy→Relayout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use auto:executing-plans to implement this plan task-by-task.

**Goal:** When a window is destroyed, GC it immediately in the observer callback instead of waiting for a full heavy refresh — and don't cancel any in-flight refresh while doing so.

**Architecture:** Capture the windowId via the AXObserver refCon pointer at subscription time. When `kAXUIElementDestroyedNotification` fires, extract the windowId from refCon, call `garbageCollect` immediately on MainActor, then schedule a refresh only if one isn't already running. This avoids both the `_AXUIElementGetWindow`-returns-nil problem and the interference problem where destroy notifications cancel in-flight creation refreshes.

**Tech Stack:** Swift, macOS Accessibility API (AXObserver, AXObserverAddNotification)

**Worktree:** `EnterWorktree` with name `fast-destroy-gc` (branch: `feature/fast-destroy-gc`)

**Principles:**
- DRY, YAGNI, TDD, frequent commits
- No backwards-compat wrappers, deprecation shims, or legacy API preservation — delete old interfaces, rename freely, update all callers directly. Clean code over migration paths.
- Complete code in every step — no placeholders like "add validation here"
- Exact file paths and exact commands with expected output
- Thorough logging so we can observe fast-path behavior in production

---

### Task 1: Set Up Worktree

**Step 1: Validate You Are In A Worktree**
Validate work is being done in a worktree. If not use the `EnterWorktree` tool with `name: "fast-destroy-gc"` to create an isolated worktree.

**Step 2: Verify clean baseline**
```bash
make check
```
Expected: all checks pass. If not, investigate before proceeding.

---

### Task 2: Add refCon support to AxSubscription

**Files:**
- Modify: `Sources/AppBundle/util/AxSubscription.swift`

The `subscribe` method currently hardcodes `nil` as the 4th argument to `AXObserverAddNotification`. Add a `refCon` parameter so callers can pass through a user-data pointer.

**Step 1: Modify `subscribe` to accept refCon**

Change the private `subscribe` method (line 17) to accept an optional refCon and pass it through:

```swift
private func subscribe(_ key: String, refCon: UnsafeMutableRawPointer? = nil) throws -> Bool {
    axThreadToken.checkEquals(axTaskLocalAppThreadToken)
    if AXObserverAddNotification(obs, ax, key as CFString, refCon) == .success {
        notifKeys.insert(key)
        return true
    } else {
        return false
    }
}
```

**Step 2: Modify `bulkSubscribe` to accept and pass through refCon**

Change `bulkSubscribe` (line 27) to accept an optional refCon parameter with a default of `nil`, and pass it through to `subscribe`:

```swift
static func bulkSubscribe(
    _ nsApp: NSRunningApplication,
    _ ax: AXUIElement,
    _ job: RunLoopJob,
    _ handlerToNotifKeyMapping: HandlerToNotifKeyMapping,
    refCon: UnsafeMutableRawPointer? = nil,
) throws -> [AxSubscription] {
```

In the inner loop (line 42), pass refCon:
```swift
if try !subscription.subscribe(key, refCon: refCon) { return [] }
```

**Step 3: Verify build**
```bash
make check
```
Expected: passes — the default `nil` keeps all existing call sites working.

**Step 4: Commit**

---

### Task 3: Pass windowId as refCon in per-window observer registration

**Files:**
- Modify: `Sources/AppBundle/tree/MacApp.swift` (inside `AxWindow.new`, ~line 474)

**Step 1: Box windowId into refCon and pass to bulkSubscribe**

In `AxWindow.new` (line 474), box the `windowId` as a raw pointer and pass it to `bulkSubscribe`. `UnsafeMutableRawPointer(bitPattern:)` stores the integer value directly in the pointer bits — no allocation, no deallocation, thread-safe. WindowId 0 is already filtered out by `getOrRegisterAxWindow` so the nil-for-zero edge case can't occur.

```swift
static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
    let handlers: HandlerToNotifKeyMapping = unsafe [
        (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
        (movedObs, [kAXMovedNotification]),
        (resizedObs, [kAXResizedNotification]),
    ]
    let refCon = UnsafeMutableRawPointer(bitPattern: UInt(windowId))
    let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers, refCon: refCon)
    return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
}
```

The app-level `bulkSubscribe` call in `MacApp.getOrRegister` (line 111) stays unchanged — it uses the default `nil` refCon.

**Step 2: Verify build**
```bash
make check
```

**Step 3: Commit**

---

### Task 4: Add fast-path destroy handler and non-cancelling refresh scheduling

**Files:**
- Modify: `Sources/AppBundle/layout/refresh.swift`

This is the core change. Three pieces:

#### Step 1: Add `refreshSessionIsActive` flag

Add a flag near the existing `activeRefreshTask` (line 5) to track whether a heavy refresh is currently executing:

```swift
@MainActor
private var refreshSessionIsActive = false
```

#### Step 2: Set the flag in `runHeavyCompleteRefreshSession`

At the top of `runHeavyCompleteRefreshSession` (line 31), set the flag and clear it on exit:

```swift
@MainActor
func runHeavyCompleteRefreshSession(...) async {
    refreshSessionIsActive = true
    defer { refreshSessionIsActive = false }
    // ... existing body unchanged ...
}
```

#### Step 3: Add `scheduleRefreshUnlessBusy`

Add a new function after `scheduleCancellableCompleteRefreshSession`:

```swift
@MainActor
func scheduleRefreshUnlessBusy(_ event: RefreshSessionEvent) {
    if refreshSessionIsActive {
        eprint("[fast-destroy] refresh already active — skipping schedule (in-flight refresh will pick up GC'd state)")
        return
    }
    eprint("[fast-destroy] no refresh active — scheduling refresh")
    scheduleCancellableCompleteRefreshSession(event)
}
```

If a refresh is already running, skip scheduling — the running refresh will see the GC'd window state (it's already removed from `allWindowsMap`) when it reaches `refresh()` → the `for window in MacWindow.allWindows` loop and `layoutWorkspaces()`.

If no refresh is running, schedule one normally to handle relayout.

#### Step 4: Modify `refreshObs` for fast-path destroy

Replace the current `refreshObs` (lines 168-174) with a version that checks for refCon and handles destroy notifications on the fast path:

```swift
func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, refCon: UnsafeMutableRawPointer?) {
    let notif = notif as String
    if notif == kAXUIElementDestroyedNotification as String, let refCon {
        let windowId = UInt32(UInt(bitPattern: refCon))
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            guard let window = MacWindow.allWindowsMap[windowId] else {
                eprint("[fast-destroy] wid:\(windowId) not in allWindowsMap — already GC'd or never registered")
                return
            }
            eprint("[fast-destroy] wid:\(windowId) (\(window.app.name ?? "?")) — fast-path GC")
            window.garbageCollect(skipClosedWindowsCache: false)
            scheduleRefreshUnlessBusy(.ax(notif))
        }
    } else {
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            scheduleCancellableCompleteRefreshSession(.ax(notif))
        }
    }
}
```

Logic:
- **Destroy + refCon present** (per-window observer): extract windowId, GC immediately, schedule non-cancelling refresh
- **Destroy without refCon** (shouldn't happen, but safe): fall through to existing behavior
- **Non-destroy notifications** (deminiaturized, miniaturized): existing behavior — these need a full refresh cycle, and their AXUIElement is still alive

#### Step 5: Verify build
```bash
make check
```

#### Step 6: Commit

---

### Task 5: Deploy and verify

**Step 1: Deploy**
```bash
make deploy
```

**Step 2: Manual verification**

Open a terminal and watch stderr:
```bash
log stream --process AeroSpace --level debug 2>&1 | grep fast-destroy
```

Then:
1. Open a new app window (e.g. Terminal) — should tile normally via regular refresh
2. Close that window — should see `[fast-destroy] wid:XXXX — fast-path GC` in logs
3. Open a window, then quickly open and close a popup (e.g. Cmd+O open dialog, then Escape) — the popup's destroy should NOT cancel the window's creation refresh (verify the log shows `refresh already active — skipping schedule`)
4. Verify windows relayout correctly after closing a tiled window

**Step 3: Commit any fixes if needed**

---

## Executive Summary

**What exists today:**
- When `kAXUIElementDestroyedNotification` fires, `refreshObs` discards the AXUIElement and refCon, then calls `scheduleCancellableCompleteRefreshSession` which cancels any in-flight refresh and starts a full heavy refresh. The heavy refresh probes ALL apps for alive windows before GC'ing the dead one.
- This means: (a) destroyed windows linger in the tree until the heavy refresh completes, (b) destroying a popup cancels an in-flight refresh that was handling a new window creation.
- Previous approaches failed: CG snapshot lags AX, `_AXUIElementGetWindow` returns nil for dead elements, and cancelling in-flight refreshes caused interference.

**What we're moving to:**
- The windowId is captured at observer subscription time via the `AXObserverAddNotification` refCon parameter — no need to query the dead element.
- On destroy, `garbageCollect` runs immediately (removes from tree, handles focus, caches closed window), then a refresh is scheduled only if one isn't already running.
- In-flight refreshes are never cancelled by destroy events. A running refresh naturally sees the updated `allWindowsMap` state.

**Why:**
- Faster layout response when windows close (no full heavy refresh needed for GC)
- Eliminates the interference problem where popup destroys slow down new window placement
- Provides the foundation for further fast-path optimizations (e.g. fast relayout without heavy refresh)
