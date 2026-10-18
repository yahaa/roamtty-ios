import Foundation
import RoamttyCore

extension SSHConnection {
    /// mosh-server inherits the authenticated SSH connection's local address (-s), not an arbitrary client-supplied endpoint.
    public func startMosh(mode: SessionMode, remoteName: String, existing: Bool = false, columns: Int, rows: Int) throws -> MoshTransport {
        if mode == .tmux, try exec(RemoteCommands.tmuxProbe).status != 0 { throw RoamError.tmuxMissing }
        // mosh-server listens only on the address this SSH login reached; resolving the name again may pick another.
        guard let peer = peerAddress else { throw RoamError.transport("mosh 不可用，使用 SSH / mosh unavailable") }
        let lifetime = mode == .tmux ? 900 : 43800
        let attached = mode == .tmux ? " -- /bin/sh -c " + RemoteCommands.shellQuote(RemoteCommands.tmuxAttach(remoteName, existing: existing)) : ""
        for locale in ["en_US.UTF-8", "C.UTF-8"] {
            let command = RemoteCommands.pathSetup + "; MOSH_SERVER_NETWORK_TMOUT=\(lifetime) mosh-server new -s -c 256 -l LANG=\(locale)" + attached
            let result = try exec("/bin/sh -c " + RemoteCommands.shellQuote(command), timeout: 15)
            let output = String(decoding: result.output, as: UTF8.self)
            for line in output.components(separatedBy: .newlines) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 4, fields[0] == "MOSH", fields[1] == "CONNECT", let port = Int(fields[2]), (60000...61000).contains(port) {
                    return try MoshTransport(host: peer, port: port, key: String(fields[3]))
                }
            }
            if !output.contains("UTF-8") { break }
        }
        throw RoamError.transport("mosh 不可用，使用 SSH / mosh unavailable")
    }
}
