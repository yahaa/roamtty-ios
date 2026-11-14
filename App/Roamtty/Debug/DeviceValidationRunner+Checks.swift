#if DEBUG
import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport

/// The checks against the fixture host: SFTP transfers, tmux sessions and mosh.
extension DeviceValidationRunner {
    func sftp(_ ssh: SSHConnection) {
        let remote = "/tmp/roamtty-device-" + UUID().uuidString
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-device-" + UUID().uuidString)
        var created = false
        defer {
            try? FileManager.default.removeItem(at: local)
            if created {
                check("sftp_fixture_cleanup") {
                    let result = try ssh.exec("rm -rf -- " + RemoteCommands.shellQuote(remote), timeout: 8)
                    try require(result.status == 0, "Fixture directory cleanup failed")
                    return ["removedOwnedUUIDDirectory": "true"]
                }
            }
        }
        check("sftp_binary_roundtrip_truncation_and_no_overwrite") { try sftpRoundtrip(ssh, remote: remote, local: local, created: &created) }
        check("sftp_cancel_cleanup_and_connection_reuse") {
            try require(created, "SFTP fixture directory unavailable")
            return try sftpCancellation(ssh, remote: remote, local: local)
        }
    }

    private func sftpRoundtrip(_ ssh: SSHConnection, remote: String, local: URL, created: inout Bool) throws -> [String: String] {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let result = try ssh.exec("mkdir -m 700 -- " + RemoteCommands.shellQuote(remote), timeout: 8)
        try require(result.status == 0, "Fixture directory creation failed"); created = true
        let bytes = Data((0..<250_000).map { UInt8($0 % 251) })
        let source = local.appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let path = remote + "/中文 ' * ? \\ fixture.bin"
        try ssh.upload(source, to: path) { _, _ in }
        var refusedOverwrite = false
        do { try ssh.upload(source, to: path) { _, _ in } } catch { refusedOverwrite = true }
        try require(refusedOverwrite, "SFTP replaced an existing destination")
        let downloaded = local.appendingPathComponent("download.bin")
        try ssh.download(path, to: downloaded) { _, _ in }
        let actual = try Data(contentsOf: downloaded)
        try require(actual == bytes, "SFTP binary roundtrip mismatch")
        let preview = try ssh.readFile(path, maxBytes: 37)
        try require(preview.truncated && preview.data == bytes.prefix(37), "SFTP preview truncation mismatch")
        try require(try ssh.listDirectory(remote).entries.count == 1, "SFTP left an unexpected partial file")
        return ["bytesCompared": "250000", "literalFilenameRoundtrip": "true", "truncatedPreviewBytes": "37", "existingDestinationPreserved": "true"]
    }

    private func sftpCancellation(_ ssh: SSHConnection, remote: String, local: URL) throws -> [String: String] {
        let source = local.appendingPathComponent("source.bin")
        let uploadToken = TransferCancellation()
        var uploadCancelled = false
        do {
            try ssh.upload(source, to: remote + "/cancelled.bin", progress: { count, _ in if count > 0 { uploadToken.cancel() } }, cancellation: uploadToken)
        } catch RoamError.cancelled { uploadCancelled = true }
        try require(uploadCancelled, "Upload cancellation was not observed")
        let listing = try ssh.listDirectory(remote)
        try require(listing.entries.count == 1 && !listing.entries.contains(where: { $0.name.contains(".part") || $0.name == "cancelled.bin" }), "Cancelled upload left a remote partial")
        let destination = local.appendingPathComponent("cancelled-download.bin")
        let downloadToken = TransferCancellation()
        var downloadCancelled = false
        do {
            try ssh.download(remote + "/中文 ' * ? \\ fixture.bin", to: destination, progress: { count, _ in if count > 0 { downloadToken.cancel() } }, cancellation: downloadToken)
        } catch RoamError.cancelled { downloadCancelled = true }
        try require(downloadCancelled && !FileManager.default.fileExists(atPath: destination.path), "Cancelled download left a local partial")
        let probe = try ssh.exec("printf connected", timeout: 8)
        try require(probe.output == Data("connected".utf8), "Cancellation invalidated the SSH connection")
        return ["uploadCancelled": "true", "remotePartialRemoved": "true", "downloadCancelled": "true", "localPartialRemoved": "true", "sshStillUsable": "true"]
    }

    func tmux(_ ssh: SSHConnection) {
        let prefix = "roamtty-device-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let names = (1...8).map { prefix + "-\($0)" }
        var created: [String] = []
        defer {
            check("tmux_fixture_cleanup") {
                for name in created {
                    let result = try ssh.exec(RemoteCommands.killTmux(name), timeout: 8)
                    try require(result.status == 0, "Owned tmux session cleanup failed")
                }
                return ["ownedSessionsRemoved": String(created.count)]
            }
        }
        check("tmux_eight_independent_sessions_and_reattach") {
            try require(try ssh.exec(RemoteCommands.tmuxProbe, timeout: 8).status == 0, "Fixture tmux is unavailable")
            var ids = Set<String>()
            for name in names {
                let create = try ssh.exec(RemoteCommands.pathSetup + "; tmux new-session -d -s " + RemoteCommands.shellQuote(name), timeout: 8)
                try require(create.status == 0, "Owned tmux session creation failed"); created.append(name)
                let identity = try ssh.exec("tmux display-message -p -t " + RemoteCommands.shellQuote("=" + name + ":") + " '#{session_id}'", timeout: 8)
                try require(identity.status == 0, "tmux identity query failed")
                ids.insert(identity.trimmedText)
            }
            try require(ids.count == 8, "tmux session identities were not independent")
            try terminal(mode: .tmux, name: names[0]) { channel, output in
                try require(channel.write(Data("export ROAMTTY_DEVICE_TOKEN=42; printf 'TMUX-CREATED-%s\\n' \"$ROAMTTY_DEVICE_TOKEN\"\r".utf8)), "tmux input rejected")
                try output.expect("TMUX-CREATED-42", timeout: 8)
            }
            try terminal(mode: .tmux, name: names[0]) { channel, output in
                try require(channel.write(Data("printf 'TMUX-REATTACHED-%s\\n' \"$ROAMTTY_DEVICE_TOKEN\"\r".utf8)), "tmux reattach input rejected")
                try output.expect("TMUX-REATTACHED-42", timeout: 8)
            }
            return ["distinctRemoteSessionIDs": "8", "persistentShellVariableAfterReconnect": "42"]
        }
    }

    func mosh(_ ssh: SSHConnection) {
        let name = "roamtty-device-mosh-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sizeFile = "/tmp/" + name + ".size"
        defer {
            check("mosh_fixture_cleanup") {
                let cleanup = "rm -f -- " + RemoteCommands.shellQuote(sizeFile) + "; " + RemoteCommands.killTmux(name)
                let result = try ssh.exec(cleanup, timeout: 8)
                try require(result.status == 0, "Owned mosh fixture cleanup failed")
                return ["ownedSessionAndSizeFileRemoved": "true"]
            }
        }
        check("mosh_udp_input_resize_and_roaming_probe") {
            let transport = try ssh.startMosh(mode: .tmux, remoteName: name)
            let output = DeviceOutput()
            let done = DispatchSemaphore(value: 0)
            defer { transport.close(); _ = done.wait(timeout: .now() + 2) }
            DispatchQueue.global().async {
                defer { done.signal() }
                do { try transport.run(columns: 80, rows: 24, firstContactTimeout: 8, silenceTimeout: 12, stallTimeout: 5) { output.append($0) } } catch { output.finish(error) }
            }
            try output.expectAny(timeout: 10)
            try waitForTmuxClient(ssh, name: name)
            try require(transport.write(Data("stty -echo; printf 'DEVICE-MOSH-%d\\n' $((40+2))\r".utf8)), "mosh input rejected")
            try output.expect("DEVICE-MOSH-42", timeout: 8)
            transport.resize(columns: 91, rows: 33); transport.probe()
            let resized = try poll(seconds: 8) { try ssh.exec(Self.paneSizeCommand(name), timeout: 2).trimmedText == "33 91" }
            try require(resized, "mosh tmux pane resize timed out")
            // Mosh emits screen diffs, which may split visible text with cursor
            // controls. Verify the command's numeric result through its own
            // UUID fixture file instead of mistaking raw diffs for plain text.
            try require(transport.write(Data(("stty size > " + RemoteCommands.shellQuote(sizeFile) + "\r").utf8)), "mosh resize command rejected")
            let sizeMatched = try poll(seconds: 8) {
                let result = try ssh.exec("cat -- " + RemoteCommands.shellQuote(sizeFile) + " 2>/dev/null", timeout: 2)
                if result.status == 0 && result.trimmedText == "33 91" { return true }
                try output.throwIfFailed()
                return false
            }
            try require(sizeMatched, "mosh shell resize result timed out")
            try require(transport.write(Data("exit\r".utf8)), "mosh exit input rejected")
            try require(done.wait(timeout: .now() + 8) == .success, "mosh remote shutdown timed out")
            done.signal() // Leave the completion signal available for the cleanup defer.
            try output.throwIfFailed()
            return ["bootstrap": "SSH startMosh", "authenticatedUDPOutput": "true", "evaluatedOutputMatched": "true", "columns": "91", "rows": "33",
                "sourcePortProbe": "true", "remoteShutdown": "true"]
        }
    }

    /// tmux updates its layout before resizing the pane's underlying PTY: this asks for the kernel's dimensions,
    /// not merely tmux's layout metadata.
    private static func paneSizeCommand(_ name: String) -> String {
        RemoteCommands.pathSetup + "; pane=$(tmux display-message -p -t " + RemoteCommands.shellQuote("=" + name + ":")
            + " '#{pane_tty}'); stty -F \"$pane\" size 2>/dev/null || stty -f \"$pane\" size 2>/dev/null"
    }

    /// Asks every 50 ms until `done` says yes; false once `seconds` have passed.
    private func poll(seconds: TimeInterval, _ done: () throws -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try done() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
#endif
