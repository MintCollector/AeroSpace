# AeroSpace — Tiling Window Manager for macOS

Swift codebase. MintCollector/AeroSpace is a fork of nikitabobko/AeroSpace.

## Build

```bash
make check          # swift build --arch arm64
make build-release  # Xcode release build → .release/
make deploy         # build-release, then install: kill, rsync bundle to /Applications, restart
make install        # install the existing .release/ build WITHOUT rebuilding (rsync + restart only)
```

`make deploy` is the one to use after code changes — it rebuilds first. `make install` only copies
the pre-built `.release/`, so it ships stale code unless you ran `build-release` yourself first.

Install uses `rsync --delete` (not `rm -rf` + `cp`) to preserve the directory inode — TCC
invalidates Accessibility grants when the app bundle gets a new inode.

### Code signing (stable local identity)

Builds are signed with a **self-signed `AeroSpace Local` identity** (not ad-hoc), giving the app a
stable designated requirement (`identifier "bobko.aerospace" and certificate leaf = <our cert>`).
macOS Accessibility/TCC keys on that requirement, so the grant **persists across rebuilds** — no more
per-deploy re-approval. The cert lives in the login keychain; recreate it (or override the identity)
per the comment in the `Makefile` (`CODESIGN_IDENTITY`). This is "Option A" — for distributing
notarized builds to other Macs you'd swap in a Developer ID cert + notarization (see quanganhdo fork).

## Help text

After editing `docs/aerospace-*.adoc`, regenerate:
```bash
bash script/generate-cmd-help.sh
```

## Key architecture

- Window classification: `Sources/AppBundle/model/AxUiElementWindowType.swift`
  - `isWindowHeuristic()` — real window vs popup
  - `isDialogHeuristic()` — real window vs floating dialog (fullscreen button heuristic + exception list)
- Window detection: `Sources/AppBundle/tree/MacWindow.swift` (`getOrRegister`)
- Refresh cycle: `Sources/AppBundle/layout/refresh.swift` (`runHeavyCompleteRefreshSession`)
- Layout normalization: `Sources/AppBundle/normalizeLayoutReason.swift` (includes `validateStillPopups()`)
- Containers: workspace (floating), TilingContainer (tiled), macosPopupWindowsContainer (unmanaged/popups)

## Config

- User config: `~/.config/aerospace/aerospace.toml`
- aero-helper profiles: `../aero-helper/profiles.toml`
- **Both files must be updated together** when changing config values (gaps, keybindings, max-window-width, etc.)

## Notable forks (features worth porting)

Full survey (548 forks, ranked + categorized): `~/code/aero-helper/docs/aerospace-fork-survey.md`.
Check upstream PR status before pulling — some may have merged since.

- **`vitorebatista/AeroSpace`** — maintained fork bundling 22 unmerged upstream PRs as `port/<N>-<slug>`
  branches (has `CHANGELOG-FORK`). Easiest cherry-pick source. High-value ports:
  - **#2012** ThreadGuarded-after-destroy RunLoop race crash · **#2098** floating windows after screen wake
  - **#2085** throttle failed app-registration retries · **#2024** floating-rule tiling flash · **#2052** GTK3 black window
  - matching: **#1665** app-id array · **#2082** app-id-regex-substring · **#2081/#2103/#1344** Emacs/Outlook/KeePassXC popups
  - commands: **#1156** resize floating windows · **#1932** `list-windows --sort` · **#2080** `layout --root` · **#1708** `%{all}` var
- **`alexnguyennn/AeroSpace`** — `O(n²)→O(n)` refresh optimization + floating-window data-race fix + startup/config crash fixes.
- **`seatedro/i4`** — architectural: immutable-tree migration, tree-store sync, native macOS tabs, workspace memory.
- **`qubeio/AeroSpace`** — BSP (komorebi-style) auto-layout + `dfs-first`/`dfs-last` focus & swap.
- **`quanganhdo/AeroSpace`** — dwindle layout + **notarized Developer-ID release workflow** (relevant: replaces our
  ad-hoc signing, ends per-deploy Accessibility re-approval).
- **`gavin-ho1/AeroSpace`** — window-sliding animations (AeroSpace ships none). Invasive.
- **`alcibiadesc/AeroSpace`** — QoL: native focused-window border, workspace HUD overlay, new-window anti-flicker.
- **`rafascar/AeroSpace`** — `workspace --view-toggle` (temp merge two workspaces), sticky windows.

Nobody else builds an external state-observer like aero-helper, so nobody else hits our AX-poll stall. Note:
upstream already uses `CGWindowListCopyWindowInfo` in `windowLevelCache.swift` (join by `kCGWindowNumber`) —
extending it to `kCGWindowBounds`/`kCGWindowName` is the stall-proof read-path (see aero-helper `todo.md`).

## PRs

Target `MintCollector/AeroSpace`, not upstream.
