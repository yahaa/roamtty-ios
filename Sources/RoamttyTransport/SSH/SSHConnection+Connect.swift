import Foundation
import CNative
import RoamttyCore

/// Connecting: the TCP socket and the handshake, the host key against its pin, then the login.
extension SSHConnection {
    public func connect() throws {
        _ = Self.initialized
        _ = try host.validated()
        onPhase?(.connecting)
        do {
            let ssh = try openSession()
            onPhase?(.verifying)
            try verifyHostKey(ssh)
            guard !isStopped else { throw RoamError.cancelled }
            onPhase?(.authenticating)
            try authenticate(ssh)
            credentials.clear()
            libssh2_keepalive_config(ssh, 1, 15)
            stateLock.lock()
            let cancelledAfterAuthentication = stopped
            if !cancelledAfterAuthentication { authenticated = true }
            stateLock.unlock()
            guard !cancelledAfterAuthentication else { throw RoamError.cancelled }
            onPhase?(.connected)
        } catch {
            credentials.clear()
            if case RoamError.hostKeyChanged = error { onPhase?(.hostKeyChanged) } else if case RoamError.authentication = error { onPhase?(.authFailed) } else { onPhase?(.failed) }
            disconnect(); throw error
        }
    }

    /// Connects the socket and completes the SSH handshake on a session with this app's algorithm choices.
    private func openSession() throws -> OpaquePointer {
        let fd = roam_tcp_connect(host.hostname, Int32(host.port), 20_000)
        guard fd >= 0 else { throw RoamError.transport("无法连接主机 / Cannot reach host") }
        stateLock.lock(); socket = fd; let cancelled = stopped; stateLock.unlock()
        guard !cancelled else { throw RoamError.cancelled }
        guard let heap = roam_ssh_heap_create(Unmanaged.passUnretained(self).toOpaque()) else { throw RoamError.transport("SSH allocation failed") }
        guard let ssh = roam_ssh_session_init(heap) else { _ = roam_ssh_heap_destroy(heap, nil); throw RoamError.transport("SSH allocation failed") }
        self.heap = heap; session = ssh
        libssh2_session_set_blocking(ssh, 0)
        libssh2_session_set_timeout(ssh, 20_000)
        // No DSA, RSA/SHA1, CBC, group1 or SHA1 key-exchange downgrade.
        _ = libssh2_session_method_pref(ssh, LIBSSH2_METHOD_HOSTKEY, "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256")
        _ = libssh2_session_method_pref(ssh, LIBSSH2_METHOD_KEX,
            // swiftlint:disable:next line_length - libssh2 takes the algorithm list as one string
            "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512")
        for method in [LIBSSH2_METHOD_CRYPT_CS, LIBSSH2_METHOD_CRYPT_SC] {
            _ = libssh2_session_method_pref(ssh, method, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr")
        }
        try retry { libssh2_session_handshake(ssh, fd) }
        return ssh
    }

    /// Checks the host's key against its pin; a new host asks the user.
    private func verifyHostKey(_ ssh: OpaquePointer) throws {
        var keyLength = 0; var keyType: Int32 = 0
        guard let bytes = libssh2_session_hostkey(ssh, &keyLength, &keyType), keyLength > 0 else { throw RoamError.transport("Missing host key") }
        let algorithm = libssh2_session_methods(ssh, LIBSSH2_METHOD_HOSTKEY).map { String(cString: $0) } ?? "unknown"
        let pin = HostPin(endpoint: host.endpoint, algorithm: algorithm, key: Data(bytes: bytes, count: keyLength))
        try TrustPolicy(store: pins).verify(pin) { self.prompt(.verifyHost(pin)) != nil }
    }

    private func authenticate(_ ssh: OpaquePointer) throws {
        switch host.auth {
        case .password:
            guard let password = credentials.password else { throw RoamError.authentication }
            _ = try password.withUnsafeBytes { raw in
                try retry(timeout: 140) {
                    libssh2_userauth_password_ex(ssh, host.username, UInt32(host.username.utf8.count), raw.bindMemory(to: CChar.self).baseAddress, UInt32(password.count), nil)
                }
            }
        case .key:
            guard let key = credentials.privateKey else { throw RoamError.authentication }
            _ = try key.withUnsafeBytes { raw in
                try retry(timeout: 140) {
                    libssh2_userauth_publickey_frommemory(ssh, host.username, host.username.utf8.count, nil, 0,
                        raw.bindMemory(to: CChar.self).baseAddress, key.count, credentials.passphrase)
                }
            }
        case .interactive:
            try authenticateInteractively(ssh)
        }
    }

    /// Keyboard-interactive: the server's prompts go to the user, the answers back in libssh2's own memory.
    private func authenticateInteractively(_ ssh: OpaquePointer) throws {
        try retry(timeout: 140) {
            libssh2_userauth_keyboard_interactive_ex(ssh, host.username, UInt32(host.username.utf8.count)) { _, _, instruction, length, count, prompts, responses, abstract in
                guard let opaque = roam_ssh_user(abstract), let prompts, let responses, count >= 0, count <= 128 else { return }
                let owner = Unmanaged<SSHConnection>.fromOpaque(opaque).takeUnretainedValue()
                let labels = (0..<Int(count)).map { i in
                    prompts[i].text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(prompts[i].length)), as: UTF8.self) } ?? ""
                }
                let echo = (0..<Int(count)).map { prompts[$0].echo != 0 }
                let text = instruction.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: max(0, Int(length))), as: UTF8.self) } ?? ""
                guard let answers = owner.prompt(.keyboard(instruction: text, labels: labels, echo: echo)), answers.count == Int(count) else { return }
                for i in 0..<answers.count {
                    let bytes = answers[i].utf8CString
                    // libssh2 frees the answers with the session's own allocator.
                    guard bytes.count <= 1_048_577, let memory = roam_ssh_alloc(abstract, bytes.count) else { continue }
                    bytes.withUnsafeBufferPointer { buffer in _ = memcpy(memory, buffer.baseAddress!, buffer.count) }
                    responses[i].text = memory.assumingMemoryBound(to: CChar.self)
                    responses[i].length = UInt32(bytes.count - 1)
                }
            }
        }
    }
}
