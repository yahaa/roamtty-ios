# Desktop network information layout

**Goal:** Keep network information outside the desktop picture in portrait and landscape and use the empty space below landscape controls.
**Spec:** User screenshot and request on 2026-10-24; this layout change supersedes Android's over-picture statistics placement.
**Architecture:** Preserve `DesktopStatsText` formatting and session metrics. Move statistics into sibling layout space: a wrapping strip below the portrait viewport, and a compact, scrollable landscape sidebar below four controls. The video and input viewport continue to share the same rectangle.
**Constraints:** Keep all existing measurements, show/hide preference and poor-network warning. Preserve keyboard operation and connection status cards. Dark desktop palette; 44-point minimum buttons; normal sidebar width 72, statistics sidebar 132. Operations panel must account for the wider sidebar.

- [x] Prove current network text overlaps the video with a simulator regression.
- [x] Move statistics and warnings outside the video; compact landscape controls and update settings description.
- [x] Verify both languages, phone sizes, rotation, toggle and keyboard behavior; inspect screenshots and run core suite.
- [x] Review the change and prepare the signed Release IPA.

Delivery uses PR 47 and the existing dev OTA catalog on port 18780. Preserve historical builds and verify the HTTPS manifest and freshly downloaded IPA hash. Artifact metadata and delivery evidence live in `/tmp/roamtty-ota-2026102402/`.

## Evidence

- Baseline: clean PR 47 worktree at `d01b26d`; `statsOverlay` sits in the video ZStack, landscape buttons expand to infinite height.
- The initial simulator regression failed because `UDP 15 ms` overlapped the video. Evidence: `/tmp/roamtty-desktop-network/Red.xcresult`.
- Screenshot review exposed the landscape IME covering the sidebar. The sidebar now reserves the same keyboard inset as the workspace; the regression scrolls the encoder text into the visible area above the keyboard.
- `swift test`: 347 tests, 45 skipped integration tests, zero failures. Existing keyboard/shortcut regression passed with the final production code.
- Read-only review found no remaining blockers after the keyboard fix. Signed Release build `1.0.0 (2026102402)` and strict codesign verification passed.
- Final iPhone 17 Pro and iPhone SE (3rd generation) simulator runs each passed all three network layout regressions, covering both languages, rotation, toggles, keyboard scrolling and warnings. Evidence: `/tmp/roamtty-desktop-network/VerifiedFresh.xcresult` and `CompactVerified.xcresult`; portrait and landscape screenshots inspected. The standard simulator required a reboot after its system stopped applying rotation commands; production code was unchanged by the test-environment recovery.
