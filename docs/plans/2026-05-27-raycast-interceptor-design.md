# Raycast Activation Interceptor + Extension

## Problem

When Raycast activates an application that already has a window on another workspace, AeroSpace follows the macOS focus change and yanks the user to that workspace. The desired behavior is to stay on the current workspace — either by moving the existing window here or opening a new one.

Modifier keys can't differentiate these actions because Raycast consumes all modifier keys for its own shortcuts.

## Solution: Two-Component Architecture

1. **AeroSpace RaycastInterceptor** (Swift) — detects Raycast-driven activations via AXObserver. For non-extension apps, silently moves the window to the current workspace. For extension apps, launches a Raycast extension via deeplink with all window data.

2. **AeroSpace Raycast Extension** (TypeScript) — receives app context via deeplink. Presents a list: "New window" at the top, then each existing window with title and workspace. Enter on a window moves it here. Enter on "New window" runs `open -n`. Secondary actions via Cmd+K.

## Detection

AXObserver on Raycast's PID watches for `kAXWindowCreatedNotification` and `kAXUIElementDestroyedNotification`. When the panel opens, we snapshot the currently-focused app's bundle ID (`panelOpenBundleId`). When the panel closes, we record the timestamp (`panelClosedAt`).

In `GlobalObserver.onNotif`, when `didActivateApplicationNotification` fires, `handleActivation` checks if `panelClosedAt` is within 200ms. If so, this is a Raycast-driven activation.

Dismissal detection: if the activated app matches `panelOpenBundleId`, the user pressed Escape — pass through to normal behavior.

## Config

`~/.config/aerospace/raycast.toml`:

```toml
# What happens for apps NOT in extension-apps when activated via Raycast
# "move" = move existing window to current workspace
# "focus" = normal stock behavior (switch to window's workspace)
default-behavior = "move"

# Apps that route to the Raycast extension for action selection
extension-apps = [
    "net.kovidgoyal.kitty",
    "com.mitchellh.ghostty",
    "com.google.Chrome",
    "net.imput.helium",
]
```

Reloaded when the main AeroSpace config reloads.

## Routing Logic

```
if bundleId in extension-apps → launch deeplink with window data
else if default-behavior == move → moveWindowHere() silently
else → return false (pass through)
```

| Scenario | Action |
|---|---|
| Raycast + extension app | Launch Raycast extension via deeplink |
| Raycast + non-extension app, default=move | Move existing window to current workspace |
| Raycast + non-extension app, default=focus | Normal stock behavior (switch to workspace) |
| Raycast dismissed (Escape) | Normal stock behavior |
| Non-Raycast activation (Dock, Cmd+Tab) | Always normal stock behavior |

## Deeplink Handoff

The interceptor serializes window data into a Raycast deeplink:

```
raycast://extensions/aerospace/window-action?context=<url-encoded-json>
```

JSON payload:
```json
{
  "bundleId": "net.kovidgoyal.kitty",
  "appName": "kitty",
  "bundlePath": "/Applications/kitty.app",
  "windows": [
    {"id": 1234, "title": "~/code — zsh", "workspace": "3"},
    {"id": 1235, "title": "~/notes — vim", "workspace": "1"}
  ]
}
```

Built from `MacApp.allAppsMap` and `MacWindow.allWindows` in the interceptor — no CLI roundtrip needed. Opened via `NSWorkspace.shared.open(url)`.

## Raycast Extension

### UI

```
┌─────────────────────────────────────┐
│ kitty                               │
├─────────────────────────────────────┤
│ ✦ New window                        │
│   ~/code — zsh         workspace 3  │
│   ~/notes — vim        workspace 1  │
└─────────────────────────────────────┘
```

### Actions

- **Enter** on "New window" → `open -n <bundlePath>`
- **Enter** on a window → `aerospace move-node-to-workspace --window-id <id> <current> && aerospace focus --window-id <id>`
- **Cmd+K** on a window → action panel:
  - "Focus on its workspace" → `aerospace workspace <workspace-name>`
  - "Close window" → `aerospace close --window-id <id>`

Gets current workspace from `aerospace list-workspaces --focused` at launch (one CLI call).

### Project Structure

```
extensions/raycast/aerospace/
  package.json          # Raycast extension manifest + dependencies
  src/
    window-action.tsx   # Single command — receives deeplink, renders list
```

Single dependency: `@raycast/api`.

## Files (Swift Side)

### `Sources/AppBundle/RaycastInterceptor.swift`

- AXObserver setup and lifecycle
- Panel state tracking (`panelClosedAt`, `panelOpenBundleId`)
- `handleActivation` routing logic (extension-apps check, action dispatch)
- `moveWindowHere` action (tree manipulation)
- `launchExtension` action (build JSON, open deeplink)

### `Sources/AppBundle/config/RaycastConfig.swift`

- `RaycastConfig` struct with `defaultBehavior` and `extensionApps`
- `loadRaycastConfig()` TOML parser

### `Sources/AppBundle/GlobalObserver.swift`

One-line call to `RaycastInterceptor.handleActivation` in `onNotif`.

### `Sources/AppBundle/initAppBundle.swift`

`loadRaycastConfig()` + `RaycastInterceptor.install()` at startup.

### `Sources/AppBundle/command/impl/ReloadConfigCommand.swift`

`loadRaycastConfig()` on config reload.
