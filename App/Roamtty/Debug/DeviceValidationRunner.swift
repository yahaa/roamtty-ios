#if DEBUG
import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport

struct DeviceFixture {
    let address: String
    let port: Int
    let username: String
    let password: String
    let fingerprint: String
    let id = "device-validation-" + UUID().uuidString

    init?(environment: [String: String]) {
        guard let address = environment["ROAMTTY_TEST_HOST"], !address.isEmpty,
              let username = environment["ROAMTTY_TEST_USERNAME"], !username.isEmpty,
              let password = environment["ROAMTTY_TEST_PASSWORD"], !password.isEmpty,
              let fingerprint = environment["ROAMTTY_TEST_FINGERPRINT"], fingerprint.hasPrefix("SHA256:"),
              fingerprint.count == 50,
              let port = Int(environment["ROAMTTY_TEST_PORT"] ?? "22"), (1...65535).contains(port) else { return nil }
        self.address = address; self.port = port; self.username = username
        self.password = password; self.fingerprint = fingerprint
    }

    func host(auth: AuthMethod) -> RoamttyCore.Host {
        RoamttyCore.Host(id: id, name: "Device validation fixture", address: address, port: port, username: username, auth: auth, mode: .shell)
    }

    func connect(auth: AuthMethod = .password) throws -> SSHConnection {
        let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host(auth: auth), credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
            switch prompt {
            case .verifyHost(let received): return received.fingerprint == fingerprint ? ["verified fixture fingerprint"] : nil
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        let timeout = DispatchWorkItem { connection.disconnect() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer { timeout.cancel() }
        do { try connection.connect(); return connection } catch { connection.disconnect(); throw error }
    }
}

struct DeviceFailure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
struct DeviceCheck: Encodable {
    let name: String
    let status: String
    let elapsedMilliseconds: Int
    let evidence: [String: String]
}
struct DeviceReport: Encodable {
    let schema = 1
    let kind = "functional-diagnostic"
    let xctestUIAutomation = false
    let startedAt: String
    var finishedAt: String?
    var status = "running"
    var checks: [DeviceCheck] = []
}

final class DeviceValidationRunner {
    let fixture: DeviceFixture
    let folder: URL
    var report: DeviceReport
    private(set) var displayMetrics: HostMetrics?

    init(fixture: DeviceFixture, folder: URL) throws {
        self.fixture = fixture; self.folder = folder
        report = DeviceReport(startedAt: ISO8601DateFormatter().string(from: Date()))
        try save()
    }

    func check(_ name: String, _ operation: () throws -> [String: String]) {
        let start = Date()
        do {
            let evidence = try operation()
            report.checks.append(DeviceCheck(name: name, status: "passed", elapsedMilliseconds: Int(Date().timeIntervalSince(start) * 1000), evidence: evidence))
        } catch {
            report.checks.append(DeviceCheck(name: name, status: "failed", elapsedMilliseconds: Int(Date().timeIntervalSince(start) * 1000), evidence: ["reason": Self.safeReason(error)]))
        }
        try? save()
    }

    func finish() {
        report.finishedAt = ISO8601DateFormatter().string(from: Date())
        report.status = report.checks.allSatisfy { $0.status == "passed" } ? "passed" : "failed"
        try? save()
    }

    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }

    static func safeReason(_ error: Error) -> String {
        if let failure = error as? DeviceFailure { return failure.reason }
        guard let failure = error as? RoamError else { return "Local operation failed" }
        switch failure {
        case .authentication: return "Authentication failed"
        case .cancelled: return "Operation cancelled or watchdog expired"
        case .timeout: return "Transport timed out"
        case .hostKeyChanged, .rejected: return "Fixture fingerprint verification failed"
        case .tmuxMissing: return "Fixture tmux unavailable"
        case .transport(let message):
            let safeMessages = ["无法连接主机 / Cannot reach host", "SSH allocation failed", "Missing host key", "Network wait failed", "SSH connection is not authenticated"]
            if safeMessages.contains(message) { return message }
            if message.range(of: #"^SSH operation failed \(-?[0-9]+\)$"#, options: .regularExpression) != nil { return message }
            return "Transport operation failed"
        default: return "Transport or validation operation failed"
        }
    }

    func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try condition() else { throw DeviceFailure(reason) }
    }

    func run() {
        check("keychain_share_inbox_roundtrip") {
            ["result": try ShareInboxStore.runDeviceSelfTest()]
        }
        var client: SSHConnection?
        check("password_authentication_and_exec") {
            let ssh = try fixture.connect(); client = ssh
            let result = try ssh.exec("printf 'DEVICE-%s' SSH", timeout: 8)
            try require(result.status == 0 && result.output == Data("DEVICE-SSH".utf8), "SSH command result mismatch")
            return ["hostTrust": "Exact configured SHA256 fingerprint; isolated memory pin store", "stdoutMatched": "true", "exitStatus": "0"]
        }
        defer { client?.disconnect() }
        check("keyboard_interactive_authentication") {
            let ssh = try fixture.connect(auth: .interactive); defer { ssh.disconnect() }
            let result = try ssh.exec("printf 'INTERACTIVE-%d' 42", timeout: 8)
            try require(result.status == 0 && result.output == Data("INTERACTIVE-42".utf8), "Interactive command result mismatch")
            return ["stdoutMatched": "true", "exitStatus": "0"]
        }
        check("remote_metrics") {
            guard let ssh = client else { throw DeviceFailure("Password connection unavailable") }
            let result = try ssh.exec(RemoteCommands.shell(HostMetrics.script), timeout: 10)
            let metrics = HostMetrics.parse(result.text)
            try require(result.status == 0 && (metrics.cpus ?? 0) > 0 && (metrics.memTotalBytes ?? 0) > 0, "Metrics response was incomplete")
            // Only numeric system readings enter the screenshot. Process names,
            // remote paths, hostname, user lists and raw output are discarded.
            var display = HostMetrics()
            display.cpus = metrics.cpus; display.cpuPercent = metrics.cpuPercent
            display.memTotalBytes = metrics.memTotalBytes; display.memAvailableBytes = metrics.memAvailableBytes
            display.load = metrics.load; displayMetrics = display
            return ["cpuCountPresent": "true", "memoryTotalPresent": "true", "rawRemoteOutputStored": "false"]
        }
        check("ssh_pty_input_and_resize") {
            try terminal(mode: .shell, name: "") { ssh, output in
                try require(ssh.write(Data("stty -echo; printf 'DEVICE-PTY-%d\\n' $((6*7))\r".utf8)), "PTY input was rejected")
                try output.expect("DEVICE-PTY-42", timeout: 8)
                ssh.resize(columns: 101, rows: 39)
                try require(ssh.write(Data("stty size\r".utf8)), "PTY resize command was rejected")
                try output.expect("39 101", timeout: 8)
            }
            return ["evaluatedOutputMatched": "true", "columns": "101", "rows": "39"]
        }
        if let client {
            sftp(client)
            tmux(client)
            mosh(client)
            agentHooks(client)
        } else {
            for name in ["sftp_binary_roundtrip", "tmux_isolation_and_reattach", "mosh_udp_roundtrip", "agent_hooks_status_restart_kill"] {
                check(name) { throw DeviceFailure("Password connection unavailable") }
            }
        }
    }

    /// What starting an agent writes on the host, the status poll, the pane restart and closing, as the app runs them.
    func agentHooks(_ ssh: SSHConnection) {
        check("agent_hooks_status_restart_kill") {
            func sh(_ script: String) throws -> (Int32, String) {
                let result = try ssh.exec(RemoteCommands.stdinShell, input: Data((RemoteCommands.pathSetup + "\n" + script).utf8), timeout: 15)
                return (result.status, result.text)
            }
            try require(try sh("command -v tmux").0 == 0, "Fixture tmux unavailable")
            let name = "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            defer { _ = try? sh(RemoteCommands.killTmux(name)) }
            for (file, content, executable) in [(AgentHooks.scriptName, AgentHooks.script, false), (AgentHooks.hostFile(.claude).name, AgentHooks.hostFile(.claude).content, false)] {
                guard let command = RemoteCommands.writeHostFile(file, executable: executable) else { throw DeviceFailure("Invalid hook file name") }
                try require(try ssh.exec(command, input: Data(content.utf8), timeout: 10).status == 0, "Writing \(file) failed")
            }
            try require(try sh("cd /tmp && tmux new-session -d -s \(name) -x 80 -y 24 && tmux send-keys -t \(name) 'sleep 600' Enter && sleep 1").0 == 0, "tmux session did not start")
            let pane = try sh("tmux display-message -p -t \(name) '#{pane_id}'").1.trimmingCharacters(in: .whitespacesAndNewlines)
            for (event, json) in [("prompt", #"{"prompt":"device check"}"#), ("tool", #"{"tool_name":"Bash","tool_input":{"command":"make test"}}"#)] {
                try require(try sh("printf '%s' '\(json)' | TMUX_PANE='\(pane)' sh \"$HOME/.roamtty/agent-hook.sh\" claude \(event)").0 == 0, "Hook \(event) failed")
            }
            let poll = try ssh.exec(RemoteCommands.agentStatus(name), input: Data(), timeout: 10).text
            guard let status = AgentStatus.parse(poll) else { throw DeviceFailure("No agent status reported") }
            try require(status.state == .working && status.task == "device check" && agentActivity(status) == "Running make test", "Agent status mismatch")
            let restart = try ssh.exec(RemoteCommands.restartPane(name), input: Data(), timeout: 10)
            try require(restart.status == 0 && restart.trimmedText == "sleep 600", "Pane restart did not report its program")
            try require(try sh(RemoteCommands.killTmux(name)).0 == 0 && (try sh("tmux has-session -t =\(name) 2>/dev/null").0) != 0, "tmux session was not ended")
            return ["hooksInstalled": "true", "statusWorking": "true", "restartReportedProgram": "true", "sessionEnded": "true"]
        }
    }

    func terminal(mode: SessionMode, name: String, body: (SSHConnection, DeviceOutput) throws -> Void) throws {
        let ssh = try fixture.connect()
        let output = DeviceOutput()
        let done = DispatchSemaphore(value: 0)
        defer { ssh.disconnect(); _ = done.wait(timeout: .now() + 2) }
        try ssh.openTerminal(mode: mode, remoteName: name, columns: 80, rows: 24)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try ssh.runTerminal { output.append($0) } } catch { output.finish(error) }
        }
        try output.expectAny(timeout: 8)
        if mode == .tmux { try waitForTmuxClient(ssh, name: name) }
        try body(ssh, output)
    }

    func waitForTmuxClient(_ ssh: SSHConnection, name: String) throws {
        let command = RemoteCommands.pathSetup + "; tmux list-clients -t " + RemoteCommands.shellQuote("=" + name) + " -F '#{client_tty}'"
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let result = try ssh.exec(command, timeout: 2)
            if result.status == 0 && !result.output.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DeviceFailure("Owned tmux client did not attach")
    }
}

final class DeviceOutput {
    let condition = NSCondition()
    var bytes = Data()
    var failure: Error?
    func append(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        bytes.append(data)
        if bytes.count > 512 * 1024 { bytes.removeFirst(bytes.count - 512 * 1024) }
        condition.broadcast()
    }
    func finish(_ error: Error) { condition.lock(); failure = error; condition.broadcast(); condition.unlock() }
    func throwIfFailed() throws { condition.lock(); defer { condition.unlock() }; if let failure { throw failure } }
    func expect(_ value: String, timeout: TimeInterval) throws { try wait(timeout: timeout, label: value) { String(decoding: $0, as: UTF8.self).contains(value) } }
    func expectAny(timeout: TimeInterval) throws { try wait(timeout: timeout, label: "initial terminal state") { !$0.isEmpty } }
    func wait(timeout: TimeInterval, label: String, matches: (Data) -> Bool) throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !matches(bytes) {
            if let failure { throw failure }
            guard condition.wait(until: deadline) else { throw DeviceFailure("Expected fixture output timed out: " + label) }
        }
    }
}
#endif
