# AeroSpace — Tiling Window Manager for macOS

Swift codebase. MintCollector/AeroSpace is a fork of nikitabobko/AeroSpace.

## Build

```bash
make check          # swift build --arch arm64
make build-release  # Xcode release build
make deploy-quick   # kill, rm -rf app bundle, copy to /Applications, restart
```

Must `rm -rf /Applications/AeroSpace.app` before copy (codesign caching). `deploy-quick` handles this.

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
- aero-helper profiles: `~/code/aero-helper/profiles.toml`

## PRs

Target `MintCollector/AeroSpace`, not upstream.
