import SwiftUI
import RoamttyCore
import RoamttyTransport

/// What the browser does: reading folders, searching by path, uploads handed over by the share extension, and
/// the file operations (rename, new folder, delete), one at a time and cancellable.
extension FileBrowserScreen {
    func navigate(_ path: String) { searchDismissal += 1; filter = ""; selectedOnly = false; Task { await load(path) } }
    func search(_ request: SearchRequest) async {
        searchWarning = nil
        guard !request.prefix.isEmpty else { searchEntries = []; searching = false; return }
        searching = true; searchEntries = []
        do {
            try await Task.sleep(for: .milliseconds(200))
            let ssh = try await model.connection(for: connectionTarget)
            try model.validate(connectionTarget)
            // One SFTP session for every folder the search reads, instead of a new subsystem per folder.
            let sftp = try await performInBackground { try ssh.holdSFTPSession() }
            defer { DispatchQueue.global(qos: .utility).async { sftp.close() } }
            let result = try await resolveRemoteSearchDirectories(directory: request.directory, prefix: request.prefix, showHidden: request.hidden) { path in
                try model.validate(connectionTarget)
                return try await performInBackground { try sftp.listDirectory(path) }
            }
            try Task.checkCancellation()
            try model.validate(connectionTarget)
            guard searchRequest == request else { return }
            var seen = Set<String>()
            searchEntries = result.directories.flatMap(\.entries).filter { seen.insert($0.path).inserted }
            if result.limited {
                searchWarning = model.text("搜索达到目录读取上限，请缩小路径范围。", "Search reached its folder limit. Refine the path.")
            } else if result.unreadable {
                searchWarning = model.text("部分目录无法读取。", "Some folders could not be read.")
            }
        } catch is CancellationError { return } catch { guard searchRequest == request else { return }; searchWarning = error.localizedDescription }
        if searchRequest == request { searching = false }
    }
    func load(_ path: String) async {
        revision += 1; let token = revision; loading = true; failure = nil
        do {
            let ssh = try await model.connection(for: connectionTarget)
            try Task.checkCancellation()
            let listing = try await performInBackground { try ssh.listDirectory(path) }
            guard token == revision, !Task.isCancelled else { return }
            try model.validate(connectionTarget)
            directory = listing.path; entries = listing.entries; unreadableNames = listing.unreadableNames
        } catch { if token == revision { failure = error.localizedDescription } }
        if token == revision { loading = false }
    }

    func receiveSharedUpload() {
        // Only the host-only browser selected by Root can receive this handoff. A terminal's
        // download picker or a covered browser for another host must leave the request queued.
        guard visible, !downloadSelection, sessionID == nil, initialDirectory == ".",
              model.path.last == .files(host.id), model.sheet == nil, model.authentication == nil,
              model.incomingFiles.isEmpty, model.childModalCount == 0,
              uploadURLs.isEmpty, sharedUploadID == nil, preview == nil, !transfers,
              !importer, !folderImporter, renameEntry == nil, deleteEntry == nil, !creatingFolder, mutationID == nil,
              let request = model.files.claimSharedUpload(hostID: host.id) else { return }
        sharedUploadID = request.id
        uploadURLs = request.urls
    }
    func launchHere(agent: Bool) {
        if let onLaunchDirectory { onLaunchDirectory(agent, directory) } else { model.sheet = .launch(host, agent, directory: directory) }
    }

    func toggleSelection(_ entry: RemoteEntry) {
        if selected.contains(where: { $0.path == entry.path }) { selected.removeAll { $0.path == entry.path } } else { selected.append(entry) }
    }

    /// Typed as a paste, so the shell takes the path as text; a control character in the name is refused rather than
    /// dropped, since the path left without it would name another file.
    func insertInTerminal(_ entry: RemoteEntry, runtime: SessionRuntime) {
        guard let text = terminalPathText(entry.path) else {
            actionError = model.text("路径含控制字符，无法插入终端", "The path holds control characters, so it can't be inserted in the terminal"); return
        }
        if runtime.pasteText(text) { model.path = [.host(host.id), .terminal(runtime.record.id)] }
    }
    func receiveImport(_ result: Result<[URL], Error>) {
        do { uploadURLs = try result.get() } catch { if (error as NSError).code != NSUserCancelledError { actionError = error.localizedDescription } }
    }

    // MARK: File operations

    func rename(_ entry: RemoteEntry) {
        let name = newName; renameEntry = nil
        guard isSafeRemoteEntryName(name) else { actionError = model.text("文件名不能包含路径分隔符或空名称", "Enter a file name without path separators"); return }
        let destination = joinRemotePath(directory: parentRemotePath(entry.path), name: name)
        startMutation(label: model.text("正在重命名…", "Renaming…"), removingSelection: entry.path) { ssh, token in
            try ssh.rename(entry.path, to: destination, cancellation: token)
        }
    }
    func createFolder() {
        let name = newFolderName, parent = directory
        guard isSafeRemoteEntryName(name) else { return }
        startMutation(label: model.text("正在创建文件夹…", "Creating folder…")) { ssh, token in
            try ssh.createDirectory(joinRemotePath(directory: parent, name: name), cancellation: token)
        }
    }
    func remove(_ entry: RemoteEntry) {
        deleteEntry = nil
        startMutation(label: model.text("正在删除…", "Deleting…"), removingSelection: entry.path) { ssh, token in
            try ssh.remove(entry.path, recursive: entry.isDirectory, cancellation: token)
        }
    }

    func cancelMutation() {
        guard mutationID != nil else { return }
        mutationCancelling = true
        mutationCancellation?.cancel()
        mutationTask?.cancel()
    }
    func startMutation(label: String, removingSelection: String? = nil,
                       operation: @escaping (SSHConnection, TransferCancellation) throws -> Void) {
        guard mutationID == nil else { return }
        let id = UUID(), token = TransferCancellation(), target = connectionTarget
        mutationID = id; mutationLabel = label; mutationCancellation = token; mutationCancelling = false; actionError = nil
        mutationTask = Task { @MainActor in
            await withTaskCancellationHandler(operation: {
                do {
                    let ssh = try await model.connection(for: target)
                    try Task.checkCancellation()
                    try model.validate(target)
                    try await performInBackground { try operation(ssh, token) }
                    try Task.checkCancellation()
                    try model.validate(target)
                    if let removingSelection { selected.removeAll { $0.path == removingSelection } }
                } catch {
                    if !Task.isCancelled, !token.isCancelled, mutationID == id { actionError = error.localizedDescription }
                }
            }, onCancel: { token.cancel() })
            guard mutationID == id else { return }
            mutationID = nil; mutationCancellation = nil; mutationTask = nil; mutationCancelling = false
            // Cancellation stops remaining work; a server operation already acknowledged
            // may have completed. Refresh the actual folder rather than pretending rollback.
            if visible { Task { await load(directory); receiveSharedUpload() } }
        }
    }
}
