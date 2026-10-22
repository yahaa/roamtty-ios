# Remote desktop (iOS port of roamtty #218)

Scope: everything in [yahaa/roamtty#218](https://github.com/yahaa/roamtty/pull/218) ("Remote desktop: SSH + UDP, Linux, macOS,
Windows and Wayland hosts"), item by item, with copy and interactions from roamtty `docs/design/remote-desktop/`
(`index.html`, `keyboard.html`, `shots/`). Android reference: #218 head `a4731b4` (branch `feat/remote-desktop-platforms`).

Plugin pin: `Sources/RoamttyDesktopCore/Resources/desktop-plugin.json` is Android's `app/src/main/assets/desktop-plugin.json`
byte for byte. At `a4731b4` that is **roamtty-desktop 0.8.0** (the PR title/body still mention 0.7.0 for the Windows
service; #218 has since moved the pin to 0.8.0 in a53f9a3). Re-copy the file whenever Android re-pins.

Status legend: **done** = implemented and tested on Linux with `swift test`; **done (unverified)** = implemented but needs
Xcode / a device; **todo** = not implemented yet (later phase); **n/a** = Android-only, iOS equivalent noted.

## Phases

| Phase | Content | Verifiable on Linux |
|---|---|---|
| 1 (done) | `RoamttyDesktopCore`: protocol, state, UDP wire/crypto/FEC/reassembly, UDP link + BSD socket transport, HID + modifier latch, gestures/viewport, latency meter, plugin manifest + SHA-256 pin; golden fixtures; Xcode target | yes (all) |
| 2 (done) | Plugin install / probe / serve over the existing SSH (`RoamttyTransport`) and SFTP layers: read-only probe, host download or phone download + SFTP upload, SHA-256 check, OpenH264 fetch (Linux/Windows), macOS permission polling, Windows service hint + copy command (data/strings), `serve` stream ↔ `FrameParser`, UDP upgrade/fallback (3 s silence → SSH and back), resume token (30 s), take-over | yes on Linux: local-shell and fake-host tests, the real 0.8.0 plugin on Xvfb, and the whole flow over the box's OpenSSH fixture. Real macOS / Windows / Wayland hosts no |
| 3 | VideoToolbox H.264 decode (`VTDecompressionSession` / `AVSampleBufferDisplayLayer`), keyframe requests on loss, ACK with recv/decoded times, render time for `LatencyMeter` | no — needs Xcode + device |
| 4 | Desktop page UI (SwiftUI/UIKit): right rail / portrait tab bar, 操作 panel, both keyboard pages, virtual mouse, local cursor, stats overlay, connecting/needs/failed/recovering card, hardware keyboard & pointer | no — needs Xcode, simulator, device |
| 5 | Lifecycle (5/10/30 min keep-alive, background pause, `NWPathMonitor` network change → `UdpLink.rebind`, resume, take-over) + entry points + 设置 › 实验功能 › 远程桌面 (default off) | state logic yes; UIKit lifecycle no |

## Android ↔ iOS parity

### Protocol and transport (desktop-core)

| Android (#218) | iOS | Status |
|---|---|---|
| `DesktopProtocol`: hello line, `u8 type \| u24 len` frames, all client messages (CONFIG, INPUT abs/rel/button/wheel/key/text, ACTION, REQ, ACK, CLIP_SET, PING, PONG) | `DesktopProtocol` + push-based `FrameParser` | done — byte-equal to the plugin's golden `.bin` files |
| Server messages VIDEO, CURSOR_POS, CURSOR_SHAPE, STATE (kicked/clip/needs/locked/error/timing), PING, PONG | `DesktopProtocol.decode` → `ServerMessage` | done |
| `Hello` (displays, enc, hw, needs, resume_token, `udp {port,key}`), `Start.Failed` codes | `Hello`, `Start` | done |
| `DesktopState`: probe (yes/no/nologin, 7-day cache), `DesktopPhase`, `DesktopButton.derive` (§4.3 table) | `DesktopState.swift` | done — every row of Android's table test |
| `UdpWire`: AES-128-GCM per datagram, nonce `dir,0,0,0,seq`, header as AAD | `UdpCrypto` (CryptoKit on Apple, swift-crypto on Linux) | done — sealed golden matches the plugin |
| Replay window (1024) | `ReplayWindow` | done |
| Reed-Solomon FEC (GF(2^8)/0x11d, Cauchy) | `Fec` | done — random loss test + plugin golden fragments |
| Fragmentation (1150-byte shards, ≤160 per block), parity ratio | `UdpWire.fragment`, `parityFor` | done — byte-equal to `udp-frags.bin` |
| Reassembler: feedback reports, settle 50 ms, NACK after overtaken + 5 ms or fallback, expiry | `Reassembler` | done |
| `UdpLink`: reliable (odd ids) resend until RACK, max(2×RTT, 80 ms), 10 tries; heartbeats 4/s; RTT probe answered at once; NACK ≤3 per block when RTT < 40 ms; loss over 1 s (≥50 shards); `alive` = rx within 3 s; `rebind` + 3 heartbeats; one send thread | `UdpLink` (I/O behind `UdpTransport`, clock injectable) + `UdpSocketTransport` (BSD sockets) | done — loss test in memory and over a loopback UDP socket, rebind test |
| FEC ratio policy 5–30 %, keyframes ≥ 30 %; GCC; pacing | host side (plugin) | n/a (plugin) |
| 3 s silence → SSH fallback and back | `DesktopSession.send` (UDP while `alive`, else SSH); SSH channel closing while UDP is alive keeps the desktop on UDP | done — fake host (fallback measured 2.7–3.6 s) and the real plugin (≈2.8 s) |
| `HidUsage` + `fromAndroid(KeyEvent)` | `HidUsage` + `fromKeyboardHIDUsage(UIKey.keyCode)` (iOS already reports HID usages; same key set, plus ISO 0x64) | done |
| `ModifierLatch` (tap = once, hold = locked, combo ≤ 4, modifiers first) | `ModifierLatch` | done |
| `DesktopGestures` / `Viewport` (touch & trackpad modes, long press 500 ms, tap-hold-drag 300 ms, two-finger scroll 4 units/pt, pinch ≤5×, pan when zoomed then scroll past edge) | `DesktopGestures`, `Viewport` | done — Android's gesture tests ported 1:1 |
| `LatencyMeter` (端到端 · 主机端 · 网络 · 手机端, quickest-ping clock offset) | `LatencyMeter` | done |
| `PluginManifest` (pin, `targetFor(uname)`, OpenH264 file names) | `PluginManifest` + `bundled()` + `verify` (SHA-256) | done |
| `UdpPluginIntegrationTest` (real plugin on loopback with X display) | `UdpPluginIntegrationTests` (same three tests, env-gated: `ROAMTTY_DESKTOP_BIN`, `ROAMTTY_DESKTOP_HOME`, `DISPLAY`) | done — passes on this box against the released 0.8.0 plugin on Xvfb (5 % loss with FEC, fallback ≈2.8 s, roam 0.4–0.7 s, SSH close keeps UDP, pointer, no NACKs without loss) |

### Plugin install / start (DesktopPluginInstaller.kt, HostPluginProbe, WindowsDesktop.kt, DesktopConnection.kt)

| Android | iOS | Status |
|---|---|---|
| Read-only probe: graphical session of this user (X/Wayland socket, logind, macOS console), `uname -sm`, plugin `--version`; POSIX first, then PowerShell | `DesktopProbeScript` (same script text and markers) + `WindowsDesktop.probeCommand`; `HostDesktop.version` | done — runs in a local `sh`, over SSH, and parses Windows output. **Deviation:** a standalone probe (Android folds it into the tmux/mosh `HostPluginProbe`; iOS's plugin probe has no Windows path, so it is left untouched until phase 5 wiring) |
| Probe result cached 7 days, shown on the session card / host page | `DesktopProbe.cacheMs` ready | todo (phase 5: storage + UI) |
| Install: host downloads (curl/wget → `gzip -dc`, `--max-time 10`); fallback phone downloads + SFTP upload; SHA-256 pinned, checked on the phone and again on the host (`sha256sum`/`shasum`), atomic rename | `DesktopPluginInstaller` (scripts verbatim) + `HTTPFetch` (URLSession) + pure-Swift `Gzip` + `SSHDesktopHost.upload` (existing SFTP `upload`, temp + rename) | done — Android's installer tests ported; phone path over the real SFTP fixture with the pinned 0.8.0 archive; host path downloads the real release over SSH |
| macOS notarized app (`.zip`): `ditto` into `~/.roamtty`, link the binary, `install` loads the LaunchAgent | same scripts | done (script text + unit test); **not run on a Mac** |
| OpenH264 from Cisco where needed (plugin fetches; else phone downloads the `.bz2` and uploads, `install --openh264`) | same, `Build.pinned` adds the Cisco URL for Linux/Windows targets | done — fallback tested with a fake plugin; the real plugin fetched `openh264 ok` over SSH on this box |
| Windows: PowerShell `-EncodedCommand` scripts (mkdir, host download with `curl.exe`, `Get-FileHash`, stop task, `Move-Item`, `install`), `cmd /c` serve, exit 9009 = not installed | `PowerShell.command`, `WindowsDesktop` | done — Android's `WindowsDesktopTest` ported + install flow against a scripted host; **not run on Windows** |
| macOS 屏幕录制 / 辅助功能 permission guidance; serve retried every 1.5 s until granted | `DesktopSession` (`needsAction`, retry), `DesktopText.needs` (exact copy, both languages) | done (logic + copy); card UI phase 4; **not run on a Mac** |
| Windows: 「请先在这台电脑上登录桌面」; one forced install (sets up the service) when nobody is signed in; administrator command with 复制命令 | `DesktopSession.windowsHost`, `DesktopText.showsWindowsServiceHint`, `.windowsServiceHint`, `.copyCommand`, `WindowsDesktop.SERVICE_INSTALL` | done (data/strings); UI phase 4 |
| Start errors: exit 127/9009 → install; `encoder_failed`/`proto_unsupported` → forced install; `no_desktop`; `not_logged_in` → macOS agent reload once / Windows service once / wait; other → 桌面插件出错; 3 tries | `DesktopSession.loggedIn` | done — fake-host tests for each |
| `serve --proto 1 --client WxH@dpi [--resume S --token T]` on an exec channel; hello; CONFIG {display,fps,quality,lock_on_close}; ping 250 ms tick, RTT smoothing, poor-network rule, 5 s to clear; keyframe ≤1/s; ACK with recv/decoded times | `DesktopSession` + `SSHExecStream` (long-lived libssh2 exec channel) | done — fake host + real plugin over a local shell + real plugin over SSH |
| UDP offer → `UdpLink`, `udp_client_port` CONFIG, frames over UDP while alive | `DesktopSession.startUdp` (`UdpSocketTransport` injectable) | done |
| Drop → recovering, resume with session token, give up after 30 s (连接中断超过 30 秒，桌面已断开) | `DesktopSession.runLoop` (`RECOVER_LIMIT_MS`) | done — fake host (limit shortened) and real plugin (same session id after resume) |
| Take-over: STATE `kicked` → 已在另一台设备上打开, no resume | `DesktopSession` | done |
| Pause / resume (REQ), keep-alive timer, network change (UDP rebind + keyframe, or drop SSH and resume) | `DesktopSession.pause/resume/networkChanged` | done (logic); app lifecycle hooks phase 5 |

### Video

| Android | iOS | Status |
|---|---|---|
| MediaCodec H.264, real timestamps, render callback for 手机端 | VideoToolbox decode + display layer | todo (phase 3) — **cannot be verified on Linux** |

### Desktop page (DesktopPage.kt, design D1–D11)

| Android | iOS | Status |
|---|---|---|
| Right rail: 操作 · 键盘 · 显示桌面 · 所有窗口; portrait bottom tab bar | — | todo (phase 4) |
| 操作 panel: header ✕, 返回 (连接保持), 文件 (上传和下载), 剪贴板 (发送手机剪贴板 / 获取远程剪贴板), 仅观看, 操作方式 屏幕触控 / 鼠标指针, 虚拟鼠标, 帧率 30/60/90/120, 画质 自动/流畅/清晰/原画 + 预估流量, 显示器, 断开后锁定电脑, 显示网络状态, red 断开连接 | — | todo (phase 4) |
| Keyboard: 输入法 page (system IME, nothing sent while composing, Backspace/Enter on empty field) and 电脑键盘 page (HID by position, modifiers, 组合键, Esc/Tab/F1–F12/arrows/Home/End/PgUp/PgDn/Del) | `ModifierLatch`, `HidUsage` ready | todo (phase 4). Note: `keyboard.html` proposes a single IME + collapsible shortcut bar; #218 ships the two-page design — iOS follows #218 |
| Local cursor (CURSOR_POS / CURSOR_SHAPE), pinch zoom, two-finger scroll/pan, drag, hardware keyboard and pointer | gestures ready | todo (phase 4) |
| Stats lines top-left (端到端/主机端/网络/手机端, fps, bitrate) when 显示网络状态 on; 网络较差 / 恢复中 chip otherwise | `LatencyMeter` ready | todo (phase 4) |
| Connecting / needs / failed / recovering card (fixed size, one log line) | `DesktopPhase` ready | todo (phase 4) |

### Lifecycle, entry points, settings

| Android | iOS | Status |
|---|---|---|
| Leaving pauses and keeps the link 5/10/30 min (setting 离开后保持 N 分钟) | — | todo (phase 5) |
| Drop → resume with session token for 30 s; network change → reconnect / UDP rebind | `DesktopSession` (done in phase 2) | hook to `NWPathMonitor` / scene phase: todo (phase 5) |
| Second device takes over (STATE `kicked`) | `DesktopSession` → failed 已在另一台设备上打开 | done (logic); UI phase 4 |
| Session card desktop icon tag (shown per `DesktopButton.derive`, lit orange with dot when open) | `DesktopButton` ready | todo (phase 5) |
| Host page 「桌面」, hosts list 远程桌面 tag | — | todo (phase 5) |
| Terminal menu 「打开桌面」 | — | todo (phase 5) |
| 设置 › 实验功能 › 远程桌面, **off by default** | — | todo (phase 5) |
| Per-host prefs: pointer mode, quality, fps, lock on close; global showStats | — | todo (phase 5) |
| Android notification row "MacBook 桌面 · 已连接" | iOS has no persistent notification; Live Activity optional | n/a (decide later) |
| Android back gesture excluded over the picture | iOS edge-swipe back disabled on the desktop page | todo |

## Phase 2 notes and deviations from #218

- Threads instead of coroutines: `DesktopSession` runs Android's attempt loop on one worker thread, and per stream a reader,
  a writer and a 250 ms ticker; `DesktopHost` / `DesktopStream` are blocking (as the iOS SSH layer is). Callbacks go out on one
  serial queue in order. Same states, same timings (`Timings` defaults are Android's constants; tests shorten them).
- The probe is standalone (see the table); merging it into the session card's plugin probe is phase 5.
- The phone unpacks `linux-*.gz` with a small pure-Swift inflater (`Gzip`, CRC-32 checked) instead of `GZIPInputStream`.
- `SSHConnection.openChannel` and `error(_:)` went from `private` to internal so `SSHExecStream` (same module) can open a
  long-lived exec channel; nothing else in the SSH layer changed. Closing the stream drops the channel without a signal, as
  JSch's `disconnect` does on Android, so the plugin keeps the desktop for a resume.
- `RoamttyTransport` now depends on `RoamttyDesktopCore` (Package.swift and the Xcode generator).
- Messages are `DesktopText` values with Android's zh text and AppLocale's English; the phase carries the text in the
  configured language (`Config.english`), `DesktopSession.failure` keeps the value.
- Per-host settings persistence (quality, fps, lock on close, keep-alive minutes, UDP host override, test loss) is passed in
  through `Config`; storing them is phase 5.

## Verification

Linux (this box, Swift 6.0.3, swift-crypto 4.3.1), `swift build` and `swift test`:

- `RoamttyDesktopCoreTests`: 100 tests (phase 1: 50; phase 2: 50), 0 failures. Of these, 4 need the plugin fixture
  (`ROAMTTY_DESKTOP_BIN=…/roamtty-desktop ROAMTTY_DESKTOP_HOME=… DISPLAY=:37`, the released 0.8.0 `linux-x86_64` with
  OpenH264 installed, Xvfb, `xdotool`, `xterm`) and skip without it.
- `RoamttyTransportTests/SSHDesktopHostTests`: 5 tests against the OpenSSH fixture (`ROAMTTY_TEST_PASSWORD_FILE`); the end-to-end
  one also needs `ROAMTTY_TEST_DESKTOP_SSH=1`, network access and an X display owned by the fixture user. It logged in,
  probed, had the host download 0.8.0 from GitHub and OpenH264 from Cisco, started `serve`, upgraded to UDP and decoded frames
  (no real decoder: frames are counted).
- Whole package: 331 tests, 7 skipped (mosh / sudo / key fixtures not present), 1 failing:
  `PrivateKeysTests.testGreetingNeedsAValidVersionLine` (RoamttyCore, not touched by this PR; fails the same way on `main` on this box).

Not verified (needs Xcode on a Mac, a device, or real hosts):
- the generated Xcode project (new files, `RoamttyTransport` → `RoamttyDesktopCore` dependency) and CryptoKit / URLSession on iOS;
- macOS hosts (notarized app install, LaunchAgent reload, 屏幕录制 / 辅助功能 prompts), Windows hosts (PowerShell scripts, `cmd /c`
  serve, service install), Wayland portal approval — only script text and scripted-host tests here;
- real phone networks (Wi-Fi ↔ cellular roaming, NAT); loopback only here;
- VideoToolbox decode, the desktop page and lifecycle hooks (phases 3–5).

Suggested check on a Mac: `python3 scripts/generate-project.py && xcodebuild -scheme Roamtty -destination 'generic/platform=iOS Simulator' build`,
then `swift test --filter RoamttyDesktopCoreTests`.
