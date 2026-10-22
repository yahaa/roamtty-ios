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
| 1 (this PR, first commits) | `RoamttyDesktopCore`: protocol, state, UDP wire/crypto/FEC/reassembly, UDP link + BSD socket transport, HID + modifier latch, gestures/viewport, latency meter, plugin manifest + SHA-256 pin; golden fixtures; Xcode target | yes (all) |
| 2 | Plugin install / probe / serve over the existing SSH (`RoamttyTransport`) and SFTP layers: read-only probe + 7-day cache, host download or phone download + SFTP upload, SHA-256 check, OpenH264 fetch (Linux/Windows), macOS permission polling, Windows service hint + copy command, `serve` stream ↔ `FrameParser`, UDP upgrade/fallback (3 s silence → SSH and back), resume token (30 s), take-over | logic parts yes (with a container fixture + released plugin, as the existing SSH integration tests do); the real host matrix no |
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
| 3 s silence → SSH fallback and back | `UdpLink.alive` / `silentUs` provided; the switch lives in the connection (phase 2) | todo |
| `HidUsage` + `fromAndroid(KeyEvent)` | `HidUsage` + `fromKeyboardHIDUsage(UIKey.keyCode)` (iOS already reports HID usages; same key set, plus ISO 0x64) | done |
| `ModifierLatch` (tap = once, hold = locked, combo ≤ 4, modifiers first) | `ModifierLatch` | done |
| `DesktopGestures` / `Viewport` (touch & trackpad modes, long press 500 ms, tap-hold-drag 300 ms, two-finger scroll 4 units/pt, pinch ≤5×, pan when zoomed then scroll past edge) | `DesktopGestures`, `Viewport` | done — Android's gesture tests ported 1:1 |
| `LatencyMeter` (端到端 · 主机端 · 网络 · 手机端, quickest-ping clock offset) | `LatencyMeter` | done |
| `PluginManifest` (pin, `targetFor(uname)`, OpenH264 file names) | `PluginManifest` + `bundled()` + `verify` (SHA-256) | done |
| `UdpPluginIntegrationTest` (real plugin on loopback with X display) | — | todo (needs a built plugin + X display; could run on this Linux box in phase 2) |

### Plugin install / start (DesktopConnection.kt)

| Android | iOS | Status |
|---|---|---|
| Read-only probe on session connect / host page; result cached 7 days | — | todo (phase 2) |
| Install: host downloads; fallback phone downloads + SFTP upload; SHA-256 pinned | `PluginManifest.verify` ready | todo (phase 2) |
| OpenH264 from Cisco where needed | file names ready | todo (phase 2) |
| macOS 屏幕录制 / 辅助功能 permission guidance, polled every 1 s | — | todo |
| Windows: 「请先在这台电脑上登录桌面」; administrator command with 复制命令 for the service | — | todo |
| Reinstall a stale plugin once; reload a missing macOS agent once | — | todo |
| `serve`, hello, UDP offer → `UdpLink`, keyframe on loss, ACK | protocol pieces ready | todo (phase 2–3) |

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
| Drop → resume with session token for 30 s; network change → reconnect / UDP rebind | `UdpLink.rebind` ready | todo (phase 5) |
| Second device takes over (STATE `kicked`) | `StateMessage.kicked` ready | todo (phase 5) |
| Session card desktop icon tag (shown per `DesktopButton.derive`, lit orange with dot when open) | `DesktopButton` ready | todo (phase 5) |
| Host page 「桌面」, hosts list 远程桌面 tag | — | todo (phase 5) |
| Terminal menu 「打开桌面」 | — | todo (phase 5) |
| 设置 › 实验功能 › 远程桌面, **off by default** | — | todo (phase 5) |
| Per-host prefs: pointer mode, quality, fps, lock on close; global showStats | — | todo (phase 5) |
| Android notification row "MacBook 桌面 · 已连接" | iOS has no persistent notification; Live Activity optional | n/a (decide later) |
| Android back gesture excluded over the picture | iOS edge-swipe back disabled on the desktop page | todo |

## Verification

Linux (this box, Swift 6.0.3, swift-crypto 4.3.1): `swift build` and `swift test --filter RoamttyDesktopCoreTests`
pass, 50 tests, 0 failures. The whole package also builds; the only failing tests in the full run are 4 in
`PrivateKeysTests`, which fail identically on `main` on this box (no `ssh-keygen` here).

Not verified (needs Xcode on a Mac): the generated Xcode project with the new `RoamttyDesktopCore` static library and the
`desktop-plugin.json` app resource; CryptoKit (instead of swift-crypto) builds of `UdpCrypto`/`PluginManifest`.
Suggested check: `python3 scripts/generate-project.py && xcodebuild -scheme Roamtty -destination 'generic/platform=iOS Simulator' build`,
then `swift test --filter RoamttyDesktopCoreTests` on macOS.
