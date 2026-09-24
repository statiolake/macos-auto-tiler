# macos-auto-tiler

Drag-to-slot snap + auto reflow tiler for macOS (MVP2).

## Features

- Every native Mission Control space (per display) has its own master/stack layout.
  Space switching is left to macOS, including trackpad swipes.
- Drag a window: the remaining windows close the gap, and an overlay shows the slot the window will drop into.
  Dropping on another display moves it into that display's layout.
- Resize a tiled window: the master ratio or stack row heights follow the edge you dragged.
- While holding a window, press Option (alone) or right-click to toggle it between tiled and floating.
- Windows are re-tiled when they are created, closed, minimized or restored, when apps launch or quit,
  and after a space switch.
- Scrolling the mouse wheel over the empty desktop switches to the adjacent space.
- `Floating Rules...` in the menu: always float an app, a window type (AX role/subrole) or exclude a bundle ID.

## Run

```bash
swift build
swift run macos-auto-tiler
swift test
```

The app appears as a menu bar item (`Tiler`).
You can trigger manual reflow from menu item `Reflow Now`.

## Build `.app` bundle

```bash
./scripts/create_app_bundle.sh
```

Output:

- `dist/macos-auto-tiler.app`

## License

This project is licensed under the MIT License. See:

- `LICENSE`

## GitHub Actions

`.github/workflows/build-app.yml` builds and uploads:

- `dist/macos-auto-tiler.app`
- `dist/macos-auto-tiler.app.zip`

Triggers:

- `push` to `main` (updates prerelease `nightly`)
- `push` tag `v*` (creates/updates normal release)
- `pull_request`
- manual (`workflow_dispatch`)

## Debug logs

Logs are printed to stdout with a `[Tiler]` prefix.

- Verbose (default): `swift run macos-auto-tiler`
- Quiet debug logs: `TILER_DEBUG=0 swift run macos-auto-tiler`

## Required permissions

- Accessibility: required for AX move/resize
- Input Monitoring: required for global event tap in many environments

If drag capture fails, open System Settings and allow both permissions for the app binary.

## Architecture

Pure logic (unit tested in `Tests/`):

- `SpaceLayout.swift` — slot order and ratios of one space; slot geometry and resize-to-ratio conversion
- `TilingState.swift` — layouts of all spaces plus user-chosen floating windows; reconciliation with a snapshot
- `Gesture.swift` — mouse-down-to-mouse-up state machine: pending → drag / resize / ignored

Side effects:

- `TilerCoordinator.swift` — wires events to state changes and layouts (main thread only)
- `WindowDiscovery.swift` — on-screen windows, their space, and whether they are tilable
- `CGSSpaceService.swift` — private SkyLight bridge for spaces and the Mission Control switch shortcut
- `AXWindowActuator.swift` — applies frames through AX on a serial background queue
- `WindowLifecycleMonitor.swift` — AX and workspace notifications that trigger a reflow
- `EventTapController.swift` — global mouse/modifier/scroll event tap
- `OverlayWindowController.swift` — click-through slot preview

## Current constraints

- Drag-time movement is visual only (overlay), by design.
- Moving a window between two *visible* spaces with Mission Control (instead of dragging it) is not followed; drag it instead.
- Windows with strong size constraints may fail during apply.
- CGS private API usage can break across macOS updates and is not App Store-friendly.

## Acknowledgements

- [Amethyst](https://github.com/ianyh/Amethyst) (MIT License) has been a major reference for Space handling strategy and implementation direction. Thanks to the maintainers and contributors.
