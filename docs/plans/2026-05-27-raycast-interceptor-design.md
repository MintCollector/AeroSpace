# Raycast Activation Interceptor

## Problem

When Raycast activates an application that already has a window on another workspace, AeroSpace follows the macOS focus change and yanks the user to that workspace. The desired behavior is to stay on the current workspace and open a new window of the activated app.

## Design

### Detection

Track the last two `didActivateApplicationNotification` bundle IDs to detect Raycast-driven activations:

- `previousActivatedBundleId` — the bundle ID from the last activation
- `preRaycastBundleId` — what was focused before Raycast opened

When a non-Raycast app activates and the previous activation was Raycast (`com.raycast.macos`):
- If the target equals `preRaycastBundleId` → Raycast was dismissed (Escape), do nothing special
- Otherwise → Raycast-driven activation, intercept it

### Interception

On a Raycast-driven activation:
1. Fire `open -n <bundlePath>` to spawn a new instance of the target app
2. Suppress the normal refresh session (return early from `onNotif`)

By not calling `scheduleCancellableCompleteRefreshSession`, AeroSpace never calls `updateFocusCache` for this activation, so focus stays on the current workspace. The new window appears via `kAXWindowCreatedNotification` and gets tiled on the current workspace through the normal flow.

### Behavior by app type

- **Multi-instance apps** (terminals, browsers): `open -n` spawns a real new window
- **Single-instance apps** (Slack, Spotify): `open -n` just focuses the existing window — same as today, harmless

### Edge cases

- **App not running**: `open -n` launches it. Raycast may have also launched it, resulting in two instances briefly, but harmless since the fresh launch has no windows yet.
- **Raycast dismissed without picking**: Detected by comparing target to `preRaycastBundleId`. Normal focus behavior.
- **Other launchers (Spotlight, Alfred)**: Not affected — only `com.raycast.macos` triggers interception.
- **Brief workspace flicker**: macOS may visually switch before our code runs. The suppressed refresh session prevents AeroSpace from reinforcing the switch, and the new window appearing snaps back.

## Files

### New: `Sources/AppBundle/RaycastInterceptor.swift`

Contains all state and logic:
- `handleActivation(_ nsApp: NSRunningApplication) -> Bool` — returns true if intercepted
- Private state tracking (`previousActivatedBundleId`, `preRaycastBundleId`)
- Private `open -n` launcher

### Modified: `Sources/AppBundle/GlobalObserver.swift`

~4 lines in `onNotif`: extract `NSRunningApplication` from the notification, call `RaycastInterceptor.handleActivation`, return early if it returns true.

## Implementation Plan

### Step 1: Create `RaycastInterceptor.swift`

Create the new file with:
- `enum RaycastInterceptor` with private state
- `handleActivation` method implementing detection logic
- Private method to launch `open -n`

**Test**: Verify it compiles. No unit test needed — this is pure integration with macOS notifications.

### Step 2: Wire into `GlobalObserver.onNotif`

In `onNotif`, when the notification is `didActivateApplicationNotification`:
1. Extract `NSRunningApplication` from `notification.userInfo`
2. Call `RaycastInterceptor.handleActivation(nsApp)`
3. If it returns `true`, return early (skip `scheduleCancellableCompleteRefreshSession`)

**Test**: Build, install, verify:
- Open Raycast → pick app on another workspace → new window appears on current workspace
- Open Raycast → Escape → previous app stays focused, no new window
- Click an app in the Dock → normal focus behavior, no interception
