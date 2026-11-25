# Development & Testing

## Bootstrap & Build on macOS

Dependencies are version-pinned and SHA-256 verified. Generated `Roamtty.xcodeproj` is checked in; regenerate after adding or moving files.

```sh
./scripts/bootstrap-native.sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID python3 scripts/generate-project.py
open Roamtty.xcodeproj
```

### Signing Modes (`xcodebuild`)

- **Development (no App Group — uses shared Keychain access group):**
  ```sh
  xcodebuild -project Roamtty.xcodeproj -scheme Roamtty \
    -destination 'generic/platform=iOS' -derivedDataPath DeviceBuild \
    ROAMTTY_ENTITLEMENTS=App/Support/Development.entitlements build
  ```
- **App Group (`group.com.roamtty.shared` enabled on both bundle IDs):**
  ```sh
  xcodebuild -project Roamtty.xcodeproj -scheme Roamtty \
    -destination 'generic/platform=iOS' -derivedDataPath DeviceBuild \
    ROAMTTY_ENTITLEMENTS=App/Support/Roamtty.entitlements \
    ROAMTTY_APP_GROUP_ENABLED=YES -allowProvisioningUpdates build
  ```

## Lint

```sh
./scripts/lint.sh   # SwiftLint (.swiftlint.yml) with --strict: any warning fails
```

## Unit & Transport Tests

```sh
# macOS SwiftPM tests (live SSH tests skip without fixture env vars)
swift test

# With Docker SSH fixture (./scripts/serve-container-fixture.sh)
ROAMTTY_TEST_PASSWORD_FILE=$PWD/.private/container-fixture/password ROAMTTY_TEST_PORT=22993 \
  ROAMTTY_TEST_KEYS=../roamtty/ssh-core/src/test/resources/keys swift test

# Linux (Swift 6+, CMake, OpenSSL/zlib dev headers)
./scripts/bootstrap-linux-native.sh && swift test
./scripts/test-linux.sh              # uses Android repo's itermux_test fixture

# Pinned SwiftTerm URL, wide-cell, scrollback & accessibility suite
./scripts/test-terminal-url.sh
```

`mosh` tests locate `mosh-server` / `tmux` via PATH, Homebrew, or `ROAMTTY_MOSH_SERVER` / `ROAMTTY_TMUX`.

## Simulator UI Suite

1. Provide `.private/device-fixture.json` (`host`, `port`, `username`, `password`, UTF-8 locale, TCP forwarding allowed, `tmux` + `mosh-server` + Python 3), **or** start the local Docker fixture:
   ```sh
   ./scripts/serve-container-fixture.sh
   ROAMTTY_FIXTURE_JSON=.private/container-fixture.json ./scripts/test-simulator.sh
   ```
2. Optional recovery & plugin fixtures use `.private/recovery-environment.json` and `.private/plugin-environment.json`.
3. Run a single class: `./scripts/test-simulator.sh -only-testing:RoamttyUITests/NativeFileWorkflowUITests`.
4. Override device/runtime with `ROAMTTY_TEST_SIMULATOR`, `ROAMTTY_SIM_DEVICE_TYPE`, or `ROAMTTY_SIM_RUNTIME`. Results stay in gitignored `TestResults/`. Historical logs: [reviews/simulator-coverage.md](reviews/simulator-coverage.md).

## Targeted Script Suites

| Check | Command |
| --- | --- |
| **Desktop live gestures** | `./scripts/test-desktop-gestures.sh .private/ubuntu.json [testName\|DesktopPipUITests]` |
| **Privileged sudo cancel** | `ROAMTTY_TEST_HOST=<IP> ROAMTTY_TEST_PORT=23016 ROAMTTY_TEST_AUTH=interactive ROAMTTY_TEST_SUDO_FIXTURE=1 ROAMTTY_TEST_PASSWORD_FILE=../roamtty/.private/test-password swift test --filter SSHExecTests.testSudo` |
| **CoreText custom fonts** | `swiftc App/Roamtty/Features/Settings/Fonts/CustomFontStore.swift scripts/test-font-catalog.swift -o /tmp/roamtty-font-checks && /tmp/roamtty-font-checks App/Roamtty/Resources/Fonts/JetBrainsMono-Regular.ttf App/Roamtty/Resources/Fonts/FiraCode-Regular.ttf` |
| **Share inbox (Foundation)** | `swiftc App/Shared/ShareInboxStore.swift scripts/test-share-inbox.swift -o /tmp/roamtty-share-tests && /tmp/roamtty-share-tests` |
| **Share worker (macOS)** | `swiftc App/Shared/ShareInboxStore.swift App/Shared/ShareInboxWorker.swift App/Roamtty/Services/SharedInbox.swift scripts/test-share-worker.swift -o /tmp/roamtty-share-worker-tests && /tmp/roamtty-share-worker-tests` |
| **Terminal interaction** | `swiftc App/Roamtty/Features/Terminal/Input/TerminalInteraction.swift scripts/test-terminal-interaction.swift -o /tmp/roamtty-terminal-check && /tmp/roamtty-terminal-check` |
