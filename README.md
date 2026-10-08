# Roamtty iOS

Swift iOS client for Roamtty: saved SSH hosts, monitoring, independent shell/tmux sessions, native terminal, mosh, SFTP, file previews and transfers, coding-agent launchers, and sharing from iOS.

Behavior reference: Android `yahaa/roamtty` main `bee299d82249e255be7169d7c9f1d60c4c5f5609`. The implementation uses SwiftUI, UIKit/SwiftTerm, libssh2, OpenSSL, SQLite, and device-only Keychain. Requires iOS 16 or later.

## Build on macOS

```sh
./scripts/bootstrap-native.sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID python3 scripts/generate-project.py
open Roamtty.xcodeproj
```

Select the Roamtty scheme. The app and share extension use a shared Keychain access group for their durable file inbox. A development profile supporting wildcard Keychain groups can build without an App Group:

```sh
xcodebuild -project Roamtty.xcodeproj -scheme Roamtty \
  -destination 'generic/platform=iOS' -derivedDataPath DeviceBuild \
  ROAMTTY_ENTITLEMENTS=App/Support/Development.entitlements build
```

For App Group storage, enable `group.com.roamtty.shared` for both bundle identifiers in the signing profiles, then build with both settings:

```sh
xcodebuild -project Roamtty.xcodeproj -scheme Roamtty \
  -destination 'generic/platform=iOS' -derivedDataPath DeviceBuild \
  ROAMTTY_ENTITLEMENTS=App/Support/Roamtty.entitlements \
  ROAMTTY_APP_GROUP_ENABLED=YES \
  -allowProvisioningUpdates build
```

Dependencies are version-pinned; native downloads are SHA-256 checked. Generated project files are checked in; regenerate when adding sources. Native build artifacts stay outside version control.

## Tests

```sh
# macOS Core and transport tests
swift test

# Linux: Swift 6+, CMake, OpenSSL/zlib development headers
./scripts/bootstrap-linux-native.sh
swift test

# Live OpenSSH tests use the Android project's dedicated itermux_test fixture account.
# Fixture credentials remain in ../roamtty/.private/test-password.
./scripts/test-linux.sh
```

The mosh tests exercise wire-format vectors and an installed `mosh-server`, when available. Live SSH tests cover password/interactive/encrypted-key authentication, PTY, concurrent SFTP, no-overwrite and cancellation. Tests requiring unavailable services explicitly skip. XCTest UI tests are in `App/UITests`; sign simulator builds with `CODE_SIGN_IDENTITY=-` and the development entitlements so credential storage is exercised.

For the complete native simulator suite, put the dedicated server's `host`, `port`, `username`, and `password` in the ignored `.private/device-fixture.json`. Authorize the Android fixture's public keys on that server and keep `tmux`, `mosh-server`, and Python 3 available. Then run on the Mac:

```sh
./scripts/test-simulator.sh
```

The script creates or reuses **Roamtty Validation**, builds and installs the app and extension, seeds Photos, native Files documents and the encrypted test key, and executes the UI suite serially. It defaults to an iPhone 17 on the newest installed iOS runtime. Override `ROAMTTY_TEST_SIMULATOR` with an existing simulator UUID, or `ROAMTTY_SIM_DEVICE_TYPE` / `ROAMTTY_SIM_RUNTIME` when creating one. `ROAMTTY_TEST_ENCRYPTED_KEY` overrides the adjacent Android fixture's key path. The font import test uses the Mac's Andale Mono font. Results and private XCTest logs stay under ignored `TestResults`; the script prints only test outcomes. See [simulator coverage](docs/SIMULATOR-COVERAGE.md) for actual executed results.

The complete suite also needs two disposable Linux fixtures. Start these on an address reachable by the Mac (the recovery fixture requires OpenSSH and permission to run the dedicated test account; the plugin fixture requires Docker, Python 3 and OpenSSH clients):

```sh
sudo -n python3 scripts/serve-recovery-fixture.py --bind YOUR_LAN_IP --lifetime 7200
python3 scripts/serve-plugin-fixture.py --bind YOUR_LAN_IP
```

Copy the private JSON paths printed by these processes to the Mac's ignored `.private/recovery-environment.json` and `.private/plugin-environment.json`. The runner injects their strictly checked fields without printing values. Recovery tests use real changed host keys, closed TCP connections and unreachable mosh UDP. Plugin tests install real packages inside disposable containers and cancel an actual throttled download. Restart the plugin fixture and copy its new JSON before repeating its install test, because a successful run has installed tmux. Stop only the fixture supervisor processes when finished; their lifetimes are bounded. Individual classes can be selected with `./scripts/test-simulator.sh -only-testing:RoamttyUITests/NativeFileWorkflowUITests`.

The two privileged exec cancellation tests explicitly skip in the ordinary SSH suite. Run them against the disposable cancellation container, while no UI test is using it:

```sh
ROAMTTY_TEST_HOST=YOUR_LAN_IP ROAMTTY_TEST_PORT=23016 \
  ROAMTTY_TEST_AUTH=interactive ROAMTTY_TEST_SUDO_FIXTURE=1 \
  ROAMTTY_TEST_PASSWORD_FILE=../roamtty/.private/test-password \
  swift test --filter SSHExecTests.testSudo
```

These checks stop a real sudo command and a real apt download, verify the package remains absent, and keep another exec on the same SSH connection running.

The custom font checks use real CoreText on macOS:

```sh
swiftc App/Roamtty/Settings/CustomFontStore.swift scripts/test-font-catalog.swift -o /tmp/roamtty-font-checks
/tmp/roamtty-font-checks
```

The Foundation-only share recovery checks also run on Linux:

```sh
swiftc App/Shared/ShareInboxStore.swift scripts/test-share-inbox.swift -o /tmp/roamtty-share-tests
/tmp/roamtty-share-tests
```

`docs/PLAN.md` records the intended parity scope; `docs/PROGRESS.md` records verification and remaining work. Device and visual checks require Xcode and a paired device. See `THIRD_PARTY_NOTICES.md` for licenses.

## Data and lifecycle

Host metadata, settings, host-key pins and tmux session records live in SQLite. Passwords and imported keys use non-synchronizing Keychain entries bound to this device. Key passphrases and terminal output do not persist. Unknown host keys require explicit approval; a changed key stops authentication until the user deliberately clears its old pin.

The share extension publishes at most 20 files, totaling 64 MiB, per transaction. App Group storage is used when explicitly enabled; otherwise the extension and app exchange chunks through a separate, device-only shared Keychain group. Host credentials stay in the app's private Keychain group. Files stay queued across app restarts until uploaded or explicitly removed.

iOS can suspend background execution. tmux preserves the remote session for reattachment; mosh handles UDP roaming and resumes probing on return. The app does not promise an indefinitely running background process.
