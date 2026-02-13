# macos-auto-tiler

Drag-to-slot snap + auto reflow tiler for macOS (MVP2).

## What is implemented

- `MVP0`:
  - Menu bar app skeleton (`AppKit`)
  - Accessibility permission prompt helper
  - Window discovery via `CGWindowListCopyWindowInfo`
- `MVP1`:
  - Global drag detection via `CGEvent.tapCreate` (`down/dragged/up`)
  - Transparent top overlay with slot highlights and ghost preview
  - Overlay passes mouse through (`ignoresMouseEvents = true`)
- `MVP2`:
  - Drop-time slot insert/reflow (`Trello`-style card insert)
  - Target frame calculation from slots
  - Batch move/resize via AX (`kAXPositionAttribute`, `kAXSizeAttribute`)
  - Startup auto reflow (runs once shortly after launch)

## Run

```bash
swift build
swift run macos-auto-tiler
```

The app appears as a menu bar item (`Tiler`).
You can trigger manual reflow from menu item `Reflow Now`.

## Debug logs

Logs are printed to stdout with a `[Tiler]` prefix.

- Verbose (default): `swift run macos-auto-tiler`
- Quiet debug logs: `TILER_DEBUG=0 swift run macos-auto-tiler`

## Required permissions

- Accessibility: required for AX move/resize
- Input Monitoring: required for global event tap in many environments

If drag capture fails, open System Settings and allow both permissions for the app binary.

## Architecture

- `Sources/MacOSAutoTiler/WindowDiscovery.swift`
  - External window list + geometry (`windowID`, `pid`, `bounds`, title/app)
- `Sources/MacOSAutoTiler/EventTapController.swift`
  - Global mouse event tap (`leftMouseDown/Dragged/Up`)
- `Sources/MacOSAutoTiler/LayoutEngine.swift`
  - Slot generation, hit testing, reflow order, target frame mapping
- `Sources/MacOSAutoTiler/OverlayWindowController.swift`
  - Top-most transparent overlay for hover/ghost rendering
- `Sources/MacOSAutoTiler/AXWindowActuator.swift`
  - AX window resolution + position/size application
- `Sources/MacOSAutoTiler/TilerCoordinator.swift`
  - Orchestration of drag lifecycle and drop-time batch apply

## Current constraints

- Drag-time movement is visual only (overlay), by design.
- AX matching is heuristic (`CG` frame nearest `AX` frame).
- Windows with strong size constraints may fail during apply.
- Spaces/full-screen edge cases are not handled yet.
