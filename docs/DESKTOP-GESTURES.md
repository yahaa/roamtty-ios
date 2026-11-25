# Remote Desktop Gestures

How touches on the desktop screen map to host mouse and window input, modeled on Apple's trackpad.

- **Engine**: `DesktopGestures` (`Sources/RoamttyDesktopCore/DesktopGestures.swift` + `DesktopGestures+*.swift`), sharing behavior with Android.
- **Tests**: Unit tests in `DesktopGesturesTests` match the tables below row by row; live multi-touch UI tests run via `DesktopGestureUITests`.

![Remote Desktop Gestures](images/desktop-gestures.svg)

## Design Principles

1. **Fingers = mouse button**: 1 finger left, 2 right, 3 middle.
2. **Taps act immediately**: nothing waits for a drag (only 2-finger tap waits 300 ms to distinguish 2-finger double-tap zoom).
3. **Hold picks up the button**: a ring fills with haptics (blue = 1 finger, red = 2 fingers); lift to right-click, move to drag.
4. **Picture vs. host**: pinch zooms only the local view; 2-finger slide always scrolls the host.
5. **Local-first cursor**: cursor renders locally with zero round-trip latency and syncs `CURSOR_POS` after 500 ms idle.
6. **Picture owns its edges**: swiping inward from the picture edge moves the cursor to the host edge (Dock/taskbar); swiping back from the left black bar works as on any iOS page (`Operations → Back` always works when zoomed). Top/bottom system edges require a second swipe.

## Gesture Reference

Switch between **Touch** (`屏幕触控`, default) and **Trackpad** (`鼠标指针`) under **Operations → Control mode**.

### Clicks & Holds

| Gesture | Touch mode | Trackpad mode |
| --- | --- | --- |
| 1-finger tap | Left click at finger | Left click at cursor |
| 1-finger double tap | Double click (2nd tap snaps within 300 ms / 20 pt) | Double click |
| 2-finger tap | Right click between fingers | Right click at cursor |
| 3-finger tap | Middle click between fingers | Middle click at cursor |
| 1-finger hold → lift | Right click (blue ring, 350 ms) | Right click (blue ring, 350 ms) |
| 1-finger hold → move | Left drag from finger | Left drag from cursor |
| 2-finger hold → move | Right drag (red ring, 500 ms) | Right drag (red ring, 500 ms) |

### Movement, Scrolling & Shortcuts

| Gesture | Touch mode | Trackpad mode |
| --- | --- | --- |
| 1-finger slide | Scroll under finger with inertia (pans picture first when zoomed) | Move cursor (velocity-scaled) |
| 2-finger slide | Scroll host with inertia (even when zoomed) | Scroll host with inertia |
| Pinch | Zoom picture up to 5× + pan (local only) | Same |
| 2-finger double tap | Toggle 2.5× zoom at point | Same |
| Picture edge swipe inward | Send cursor to host edge / hot corner | Same |
| Left black bar swipe inward | iOS Back | Same |
| 3-finger swipe up / down | All windows (Mission Control / Task View / Activities) / Show desktop | Same |
| 3-finger swipe left / right | Switch desktop (`⌃→` macOS, `Ctrl+Win+→` Win, `Ctrl+Alt+→` Linux) | Same |
| 4+ fingers | Ignored (left to iOS) | Ignored (left to iOS) |

When zoomed in, the viewport auto-follows: trackpad keeps the cursor out of the outer 15%; touch drags near the edge auto-pan (up to 600 pt/s).

## Tuning Parameters

| Parameter | Value |
| --- | --- |
| Tap / hold slop | 10 pt |
| Hold duration | 350 ms (1 finger), 500 ms (2 fingers) |
| Double tap | ≤ 300 ms, ≤ 20 pt |
| Multi-finger tap | Lifted within 350 ms, no finger moved ≥ 10 pt |
| Scroll vs. pinch threshold | Centroid 12 pt / span 24 pt |
| Edge zone | Within 16 pt of picture edge, moving inward |
| 3-finger swipe | Centroid 40 pt |
| Trackpad gain | `clamp(0.8 × (v / 150 pt/s)^0.6, 0.5, 4)` picture pt per finger pt |
| Scroll wheel | `2.5 / scale` (1/120 notch units) per pt, clamped `2..12`, batched ≥ 3 |
| Inertia | `UIScrollView` deceleration (`0.998 / ms`); disabled after > 60 ms pause or < 50 pt/s |
| Haptics | Hold/pickup: `medium`; clicks/shortcuts: `light`; mode toggle: `rigid` |
| Cursor rendering | Absolute `INPUT abs` (no host accel); `CURSOR_SHAPE` rendered at ≥ 18 pt |

> macOS host plugin sets `kCGMouseEventClickState` on press/release so double-clicks register reliably; sub-notch wheel units accumulate to whole notches on X11/Wayland.

## Live Acceptance Test

Run against a disposable Ubuntu, Windows, or macOS host with `roamtty-desktop` installed:

```sh
./scripts/test-desktop-gestures.sh .private/ubuntu.json                           # full suite
./scripts/test-desktop-gestures.sh .private/ubuntu.json testTrackpadModeGestures  # single test
./scripts/test-desktop-gestures.sh .private/ubuntu.json DesktopPipUITests         # PiP window over terminal
```

> Caution: live gesture tests act on the real host desktop (showing desktop, toggling full screen, or typing at lock screen). Use a disposable machine.
