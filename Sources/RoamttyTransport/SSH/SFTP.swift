import Foundation
import CNative
import RoamttyCore

extension SSHConnection {
    private func withSFTP<T>(cancellation: TransferCancellation? = nil, _ body: (OpaquePointer, Int) throws -> T) throws -> T {
        let epoch = transferEpoch()
        try transferCheck(epoch, cancellation)
        let sftp = try openSFTP(cancelled: { epoch != self.transferEpoch() || cancellation?.isCancelled == true })
        defer { settle(timeout: 10) { libssh2_sftp_shutdown(sftp) } }
        try transferCheck(epoch, cancellation)
        do { return try body(sftp, epoch) }
        catch {
            // A request that timed out still holds libssh2's shared send slot; nothing else could get through.
            if error as? RoamError == .timeout { disconnect() }
            throw error
        }
    }
    /// libssh2 keeps a started SFTP request in the session's one send slot until it goes out, and no other channel
    /// can send before it does. Cancellation is therefore honored before a request starts, never part-way through.
    @discardableResult private func request(_ epoch: Int, _ cancellation: TransferCancellation?, _ operation: () -> Int32) throws -> Int32 {
        try transferCheck(epoch, cancellation)
        return try retry(operation)
    }
    private func requestHandle(_ epoch: Int, _ cancellation: TransferCancellation?, _ operation: () -> OpaquePointer?) throws -> OpaquePointer {
        try transferCheck(epoch, cancellation)
        return try pointer(operation)
    }
    /// Cleanup that may fail quietly, unless it is left half-sent: then the connection is no longer usable.
    @discardableResult private func settle(timeout: TimeInterval, _ operation: () -> Int32) -> Bool {
        do { try retry(timeout: timeout, operation); return true }
        catch { if error as? RoamError == .timeout { disconnect() }; return false }
    }
    /// A remote name or path exactly as its bytes; nil when they are not UTF-8.
    private func remoteString(_ bytes: ArraySlice<CChar>) -> String? {
        String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
    private func validatePath(_ path: String, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !path.isEmpty), path.utf8.count <= 16384, !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { throw RoamError.invalid("无效的远端路径 / Invalid remote path") }
    }
    private func transferCheck(_ epoch: Int, _ cancellation: TransferCancellation? = nil) throws {
        guard epoch == transferEpoch(), !isStopped, cancellation?.isCancelled != true else { throw RoamError.cancelled }
    }
    private func sftpStat(_ sftp: OpaquePointer, _ path: String, follow: Bool = true) throws -> LIBSSH2_SFTP_ATTRIBUTES {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        try retry { libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &attrs) }
        return attrs
    }
    private func knownSize(_ attrs: LIBSSH2_SFTP_ATTRIBUTES) -> Int64? {
        let regular = attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFREG)
        guard regular, attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0, attrs.filesize > 0, attrs.filesize <= UInt64(Int64.max) else { return nil }
        return Int64(attrs.filesize)
    }
    private func closeFile(_ handle: OpaquePointer) { settle(timeout: 10) { libssh2_sftp_close_handle(handle) } }
    public func listDirectory(_ path: String, cancellation: TransferCancellation? = nil) throws -> RemoteDirectory {
        try validatePath(path, allowEmpty: true)
        return try withSFTP(cancellation: cancellation) { sftp, epoch in
            let requested = path.isEmpty ? "." : path
            var realBuffer = [CChar](repeating: 0, count: 16385)
            let length = try request(epoch, cancellation) { libssh2_sftp_symlink_ex(sftp, requested, UInt32(requested.utf8.count), &realBuffer, UInt32(realBuffer.count - 1), LIBSSH2_SFTP_REALPATH) }
            guard let real = remoteString(realBuffer.prefix(Int(length))) else { throw RoamError.invalid("远端路径不是 UTF-8 编码，无法打开 / The remote path is not UTF-8") }
            let handle = try requestHandle(epoch, cancellation) { libssh2_sftp_open_ex(sftp, real, UInt32(real.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR) }
            defer { closeFile(handle) }
            var entries: [RemoteEntry] = []; var unreadable = 0
            while true {
                try transferCheck(epoch, cancellation)
                var attrs = LIBSSH2_SFTP_ATTRIBUTES(); var bytes = [CChar](repeating: 0, count: 16385)
                let n = try request(epoch, cancellation) { libssh2_sftp_readdir_ex(handle, &bytes, bytes.count - 1, nil, 0, &attrs) }
                if n == 0 { break }
                // A lossy decode maps distinct names to one path, so the entry's actions would reach another file.
                guard let name = remoteString(bytes.prefix(Int(n))) else { unreadable += 1; continue }
                guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { continue }
                let full = joinRemotePath(directory: real, name: name)
                let symlink = attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFLNK)
                if symlink {
                    // A dangling link keeps its own attributes; a stat left half-sent ends the listing.
                    do { attrs = try sftpStat(sftp, full) } catch { if error as? RoamError == .timeout { throw error } }
                }
                entries.append(RemoteEntry(name: name, path: full,
                    isDirectory: attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFDIR),
                    isSymlink: symlink, size: attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) == 0 ? nil : Int64(clamping: attrs.filesize),
                    mtime: Int64(clamping: attrs.mtime), permissions: UInt32(truncatingIfNeeded: attrs.permissions)))
            }
            return RemoteDirectory(path: real, entries: entries.sorted(by: remoteEntryPrecedes), unreadableNames: unreadable)
        }
    }
    public func readFile(_ path: String, maxBytes: Int = 2_097_152, cancellation: TransferCancellation? = nil) throws -> RemoteFileContent {
        try validatePath(path)
        guard maxBytes > 0, maxBytes <= 32 * 1024 * 1024 else { throw RoamError.invalid("Invalid preview size") }
        return try withSFTP(cancellation: cancellation) { sftp, epoch in
            let handle = try requestHandle(epoch, cancellation) { libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
            defer { closeFile(handle) }
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            // The size is optional, but a stat left half-sent is not.
            do { try retry { libssh2_sftp_fstat_ex(handle, &attrs, 0) } } catch { if error as? RoamError == .timeout { throw error } }
            var content = Data(); var buffer = [UInt8](repeating: 0, count: 32768)
            while content.count <= maxBytes {
                try transferCheck(epoch, cancellation)
                let want = min(buffer.count, maxBytes + 1 - content.count)
                let count = try request(epoch, cancellation) { buffer.withUnsafeMutableBytes { Int32(libssh2_sftp_read(handle, $0.bindMemory(to: CChar.self).baseAddress, want)) } }
                if count == 0 { break }
                content.append(contentsOf: buffer[0..<Int(count)])
            }
            let truncated = content.count > maxBytes
            if truncated { content.removeLast() }
            return RemoteFileContent(data: content, size: knownSize(attrs), truncated: truncated)
        }
    }
    public func download(_ path: String, to url: URL, progress: @escaping (Int64, Int64?) -> Void, cancellation: TransferCancellation? = nil) throws {
        try validatePath(path)
        // withoutOverwriting prevents a second task from truncating a selected file.
        try Data().write(to: url, options: .withoutOverwriting)
        do {
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            try withSFTP(cancellation: cancellation) { sftp, epoch in
                let handle = try requestHandle(epoch, cancellation) { libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
                defer { closeFile(handle) }
                var attrs = LIBSSH2_SFTP_ATTRIBUTES()
                try request(epoch, cancellation) { libssh2_sftp_fstat_ex(handle, &attrs, 0) }
                let total = knownSize(attrs); var count: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 65536)
                progress(0, total)
                while true {
                    try transferCheck(epoch, cancellation)
                    let n = try request(epoch, cancellation) { buffer.withUnsafeMutableBytes { Int32(libssh2_sftp_read(handle, $0.bindMemory(to: CChar.self).baseAddress, $0.count)) } }
                    if n == 0 { break }
                    try file.write(contentsOf: Data(buffer[0..<Int(n)])); count += Int64(n); progress(count, total)
                }
                try transferCheck(epoch, cancellation)
                if let total, total != count { throw RoamError.transport("文件大小发生变化，下载不完整 / Incomplete download") }
                try file.synchronize()
                progress(count, total)
            }
        } catch {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw RoamError.transport("下载失败，无法删除本地未完成文件 / Could not remove partial download") }
            throw error
        }
    }
    public func upload(_ url: URL, to path: String, progress: @escaping (Int64, Int64?) -> Void, cancellation: TransferCancellation? = nil) throws {
        try validatePath(path)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        try withSFTP(cancellation: cancellation) { sftp, epoch in
            let temp = joinRemotePath(directory: parentRemotePath(path), name: ".roamtty-" + UUID().uuidString + ".part")
            let handle = try requestHandle(epoch, cancellation) { libssh2_sftp_open_ex(sftp, temp, UInt32(temp.utf8.count), UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL), 0o600, LIBSSH2_SFTP_OPENFILE) }
            var closed = false
            do {
                var count: Int64 = 0; progress(0, size)
                while let block = try file.read(upToCount: 65536), !block.isEmpty {
                    try transferCheck(epoch, cancellation)
                    var sent = 0
                    while sent < block.count {
                        let n = try block.withUnsafeBytes { raw in
                            try request(epoch, cancellation) {
                                Int32(libssh2_sftp_write(handle, raw.bindMemory(to: CChar.self).baseAddress!.advanced(by: sent), block.count - sent))
                            }
                        }
                        guard n > 0 else { throw RoamError.transport("Upload made no progress") }
                        sent += Int(n); count += Int64(n); progress(count, size)
                    }
                }
                try transferCheck(epoch, cancellation)
                if let size, count != size { throw RoamError.transport("上传源文件发生变化 / Upload source changed") }
                try retry {
                    let result = libssh2_sftp_close_handle(handle)
                    // libssh2 consumes the handle on every result other than EAGAIN, including errors.
                    if result != LIBSSH2_ERROR_EAGAIN { closed = true }
                    return result
                }
                try transferCheck(epoch, cancellation)
                // Standard SFTP v3 rename with zero flags refuses an existing destination, including symlinks.
                try retry { libssh2_sftp_rename_ex(sftp, temp, UInt32(temp.utf8.count), path, UInt32(path.utf8.count), 0) }
                progress(count, size)
            } catch {
                let wasStopped = isStopped
                if !closed { closeFile(handle) }
                let cleanup = !isStopped && settle(timeout: 10) { libssh2_sftp_unlink_ex(sftp, temp, UInt32(temp.utf8.count)) }
                if !cleanup && !wasStopped { throw RoamError.transport("上传失败，远端临时文件未能清理 / Could not remove remote partial upload") }
                throw error
            }
        }
    }
    public func rename(_ path: String, to destination: String, cancellation: TransferCancellation? = nil) throws {
        try validatePath(path); try validatePath(destination)
        guard isSafeRemoteDeletePath(path), isSafeRemoteDeletePath(destination) else { throw RoamError.invalid("不允许重命名该路径 / Unsafe rename path") }
        _ = try withSFTP(cancellation: cancellation) { sftp, epoch in
            try request(epoch, cancellation) { libssh2_sftp_rename_ex(sftp, path, UInt32(path.utf8.count), destination, UInt32(destination.utf8.count), 0) }
        }
    }
    public func createDirectory(_ path: String, cancellation: TransferCancellation? = nil) throws {
        try validatePath(path)
        guard isSafeRemoteDeletePath(path) else { throw RoamError.invalid("无效的文件夹路径 / Invalid directory path") }
        _ = try withSFTP(cancellation: cancellation) { sftp, epoch in
            try request(epoch, cancellation) {
                libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), 0o755)
            }
        }
    }
    public func remove(_ path: String, recursive: Bool = false, cancellation: TransferCancellation? = nil) throws {
        try validatePath(path)
        guard isSafeRemoteDeletePath(path), path.hasPrefix("/") else { throw RoamError.invalid("不允许删除该路径 / Unsafe delete path") }
        try withSFTP(cancellation: cancellation) { sftp, epoch in
            func removeOne(_ item: String, depth: Int) throws {
                try transferCheck(epoch, cancellation)
                guard depth < 128 else { throw RoamError.invalid("Directory nesting limit exceeded") }
                let attrs = try sftpStat(sftp, item, follow: false)
                if attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFDIR) {
                    if recursive {
                        let directory = try listDirectory(item, cancellation: cancellation)
                        // Those entries cannot be named, so the folder could never be emptied; touch nothing in it.
                        guard directory.unreadableNames == 0 else { throw RoamError.invalid("文件夹中有无法识别的文件名（非 UTF-8），未删除 / The folder holds names that are not UTF-8; nothing was deleted") }
                        for entry in directory.entries { try removeOne(entry.path, depth: depth + 1) }
                    }
                    try request(epoch, cancellation) { libssh2_sftp_rmdir_ex(sftp, item, UInt32(item.utf8.count)) }
                } else { try request(epoch, cancellation) { libssh2_sftp_unlink_ex(sftp, item, UInt32(item.utf8.count)) } }
            }
            try removeOne(path, depth: 0)
        }
    }
}
