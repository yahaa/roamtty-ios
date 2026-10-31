# Remote desktop gestures

How touches on the desktop page become mouse input on the host, after Apple's trackpad.
The engine is `DesktopGestures` (Sources/RoamttyDesktopCore/DesktopGestures.swift); its unit tests
(`DesktopGesturesTests`) follow the tables below row by row, and `DesktopGestureUITests` makes every
gesture with real touches against a live host.

## Principles

1. **The number of fingers is the mouse button**: one finger left, two right, three middle.
2. **Taps act at once.** Nothing waits to find out whether a drag follows. The one exception is the
   two-finger tap: its right click waits 300 ms, because a second two-finger tap zooms instead.
3. **Holding picks the button up**, as touch-and-hold does on iOS: a ring fills under the finger,
   then turns solid with a haptic tap. Lift without moving for a right click; move to drag.
4. **The picture and the host are separate**: pinching zooms the picture only and never reaches the
   host; two fingers sliding always scroll the host, zoomed in or not.
5. **The phone answers first**: the cursor is the phone's own and moves before the host answers; holds and shortcuts
   have haptics and a ring.
6. **The desktop owns the screen's edges**: the system's edge gestures (back, Control Centre, home)
   need a second swipe while the desktop shows. 操作 › 返回 leaves the page.

## The gestures

### Clicks

| Gesture | Trackpad mode (鼠标指针) | Touch mode (屏幕触控) |
|---|---|---|
| One-finger tap | Left click where the cursor is | Left click where the finger landed |
| One-finger double tap | Double click | Double click; a second tap within 300 ms and 20 pt lands on the first one's pixel |
| Two-finger tap | Right click at the cursor | Right click between the fingers |
| Three-finger tap | Middle click | Middle click between the fingers |

### Holds (350 ms for one finger, 500 ms for two; blue ring for left, red for right)

| Gesture | Effect |
|---|---|
| Hold one finger, lift without moving | Right click |
| Hold one finger, then move | Left-button drag; lifting drops. Touch mode presses where the finger landed |
| Hold two fingers, then move | Right-button drag |

### Moving and scrolling

| Gesture | Trackpad mode | Touch mode |
|---|---|---|
| One finger slides | Moves the cursor, faster the faster the finger | The cursor follows the finger, nothing pressed (hover) |
| Two fingers slide | Scrolls the host, with inertia after a flick | Same |

### The picture and shortcuts (on the phone, not sent as mouse input)

| Gesture | Effect |
|---|---|
| Pinch | Zooms the picture (up to 5×); moving while pinching moves it |
| Two-finger double tap | Zooms in 2.5× on that spot, or back out to the whole screen |
| Swipe in from an edge of the picture | Puts the cursor on the host's edge there (Dock, taskbar, menu bar); from a corner, in the corner (hot corners) |
| Three fingers up | Every window: Mission Control / Task View / Activities |
| Three fingers down | Show the desktop |
| Three fingers left / right | The desktop on the right / left: ⌃→ on macOS, Ctrl+Win+→ on Windows, Ctrl+Alt+→ on Linux |
| Four or more fingers | Nothing: left to iOS |

Zoomed in, the picture follows: in trackpad mode it keeps the cursor out of the outer 15% of the
view; in touch mode, a drag held near the picture's edge slides it along (up to 600 pt/s).

## Parameters

| | Value |
|---|---|
| Movement before a touch stops being a tap or hold | 10 pt |
| Hold | 350 ms (one finger), 500 ms (two: they often rest before scrolling) |
| Double tap | 300 ms, 20 pt |
| Multi-finger tap | lifted within 350 ms, no finger moved 10 pt |
| Scroll / pinch decided by | centroid moving 12 pt / span changing 24 pt |
| Edge zone | 16 pt from the picture view's edge, moving inward |
| Three-finger swipe | centroid moving 40 pt |
| Pointer gain | clamp(0.8 × (v / 150 pt/s)^0.6, 0.5, 4), in picture points per finger point |
| Wheel | 2.5 / scale units (1/120 notch) per point, 2…12; sent three or more at a time |
| Inertia | UIScrollView's normal deceleration, 0.998 per ms; none after a pause over 60 ms or below 50 pt/s |
| Haptics | hold and pickup: medium; right / middle click and shortcuts: light; switching mode: rigid |

## The cursor

Moves go out as absolute positions (`INPUT abs`), from a cursor the phone keeps. The host adds no
acceleration of its own (Windows and X11 would to relative moves), so the cursor the phone draws is
exactly where the host's is, with no round trip. The host's own position (`CURSOR_POS`) is taken
whenever the phone has not moved the cursor for 500 ms: an app warped it, or someone used the
host's mouse. The phone draws the host's cursor image (`CURSOR_SHAPE`) at its hot spot, at the
picture's scale but at least 18 pt; the video carries no cursor.

## The host side

On macOS the plugin must set the click count (`kCGMouseEventClickState`) on presses and releases,
or no double click ever registers and window buttons ignore clicks (roamtty-desktop
`fix/mac-click-count`). Wheel units below a notch are smooth on macOS and Windows and add up to whole
notches on X11 and Wayland.
