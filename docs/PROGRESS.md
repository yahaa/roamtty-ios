# Execution ledger — docs/PLAN.md

- Baseline verified: remote main tree matches local Android commit.
- Workspace: new isolated repository at requested ../roamtty-ios, branch feat/ios-parity.
- Device inspection: Linux has no Apple USB device/Xcode. Mac 100.64.0.4 is reachable by SSH but rejects available key for known user zihua; no physical-device validation yet.
- Ruling: early ../itermux-ios contains custom cryptography and a simplified UI; use it only as reference for non-crypto logic, keeping planned libssh2 and SwiftTerm architecture.
- Ruling: Linux Swift 6.2 exists at /home/v/sdk/swift/usr/bin/swift; use this for cross-platform logic and live protocol tests. Apple UI requires Xcode validation.
- Pre-flight: core value types → transport → main-thread session UI; CNative provides vetted crypto/SSH/SQLite symbols to core and transport. Protocol helpers and mosh can be implemented independently in separate files after interfaces are fixed.
