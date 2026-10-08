import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore
import RoamttyTransport

struct FileBrowserScreen: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    var sessionID: String? = nil
    var initialDirectory = "."
    var downloadSelection = false
    var onLaunchDirectory: ((Bool, String) -> Void)?
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var directory = "."
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var actionError: String?
    @State private var filter = ""
    @State private var searchDismissal = 0
    @State private var preview: RemoteEntry?
    @State private var renameEntry: RemoteEntry?
    @State private var newName = ""
    @State private var deleteEntry: RemoteEntry?
    @State private var importer = false
    @State private var folderImporter = false
    @State private var transfers = false
    @State private var uploadURLs: [URL] = []
    @State private var showTransfersAfterUpload = false
    @State private var sharedUploadID: UUID?
    @State private var visible = false
    @State private var revision = 0
    @State private var searchEntries: [RemoteEntry] = []
    @State private var searching = false
    @State private var searchWarning: String?
    @State private var selecting = false
    @State private var selected: [RemoteEntry] = []
    @State private var selectedOnly = false
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var mutationID: UUID?
    @State private var mutationLabel = ""
    @State private var mutationCancellation: TransferCancellation?
    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationCancelling = false
    init(host: Host, sessionID: String? = nil, initialDirectory: String = ".", downloadSelection: Bool = false, connectionTarget: RemoteConnectionTarget, onLaunchDirectory: ((Bool, String) -> Void)? = nil) {
        self.host = host; self.sessionID = sessionID; self.initialDirectory = initialDirectory; self.downloadSelection = downloadSelection
        self.onLaunchDirectory = onLaunchDirectory
        _connectionTarget = State(initialValue: connectionTarget)
    }
    private struct SearchRequest: Equatable {
        let directory: String
        let prefix: String
        let hidden: Bool
        let revision: Int
    }
    private var searchPrefix: String { filter.lastIndex(of: "/").map { String(filter[...$0]) } ?? "" }
    private var searchRequest: SearchRequest { SearchRequest(directory: directory, prefix: searchPrefix, hidden: model.settings.showHiddenFiles, revision: revision) }
    private var targetRuntime: SessionRuntime? {
        guard let sessionID, let runtime = connectionTarget.runtime, runtime.record.id == sessionID, runtime.host.id == host.id else { return nil }
        do { try model.validate(connectionTarget) } catch { return nil }
        return runtime
    }
    private var shown: [RemoteEntry] {
        let source = selectedOnly ? selected : searchPrefix.isEmpty ? entries : searchEntries
        let query = selectedOnly ? filter : remotePathSearch(directory: directory, query: filter).name
        return source.compactMap { entry -> (RemoteEntry, Int)? in
            guard selectedOnly || model.settings.showHiddenFiles || !entry.name.hasPrefix("."),
                  let rank = remoteNameMatchRank(name: selectedOnly ? entry.path : entry.name, query: query) else { return nil }
            return (entry, rank)
        }.sorted { lhs, rhs in
            if !query.isEmpty, lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return model.settings.fileSort.orders(lhs.0, before: rhs.0, descending: model.settings.fileSortDescending)
        }.map { $0.0 }
    }
    var body: some View {
        VStack(spacing: 0) {
            pathBar.disabled(mutationID != nil)
            HStack { Text(model.text("\(shown.count) 项", "\(shown.count) items")).font(.caption); Spacer(); if loading || searching { ProgressView().scaleEffect(0.8) } }.foregroundStyle(Palette.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            if mutationID != nil { mutationProgress }
            if let actionError {
                HStack(alignment: .top, spacing: 12) {
                    Text(actionError).font(.footnote).foregroundStyle(Palette.warning).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("files-operation-error")
                    Button { self.actionError = nil } label: { Image(systemName: "xmark.circle") }.accessibilityLabel(model.text("关闭错误", "Dismiss error")).accessibilityIdentifier("files-operation-error-dismiss")
                }.padding(12).background(Palette.panel)
            }
            if let searchWarning { Text(searchWarning).font(.caption).foregroundStyle(Palette.warning).padding(.horizontal, 16).accessibilityIdentifier("files-search-warning") }
            if let failure { EmptyMessage(icon: "exclamationmark.triangle", title: model.text("无法读取目录", "Unable to read folder"), message: failure); Button(model.text("重试", "Retry")) { navigate(directory) }; Spacer() }
            else {
                List(shown) { entry in
                    Button { if entry.isDirectory { navigate(entry.path) } else if selecting { toggleSelection(entry) } else { preview = entry } } label: {
                        HStack(spacing: 12) {
                            if selecting && !entry.isDirectory { Image(systemName: selected.contains(where: { $0.path == entry.path }) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent) }
                            Image(systemName: fileIcon(entry)).font(.system(size: 23)).foregroundStyle(entry.isDirectory ? Palette.accent : Palette.secondary).frame(width: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).foregroundStyle(Palette.foreground).font(.subheadline).lineLimit(1)
                                if selectedOnly || !searchPrefix.isEmpty { Text(parentRemotePath(entry.path)).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1) }
                                HStack { Text(entry.isDirectory ? model.text("文件夹", "Folder") : formattedBytes(entry.size)); if entry.mtime > 0 { Text(Date(timeIntervalSince1970: TimeInterval(entry.mtime)), style: .date) }; if entry.isSymlink { Image(systemName: "link") } }.font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer(minLength: 4)
                            if entry.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary) }
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("files-entry-\(entry.path)").accessibilityValue(selected.contains(where: { $0.path == entry.path }) ? model.text("已选择", "Selected") : "").listRowBackground(Palette.panel).contextMenu { entryActions(entry) }.swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteEntry = entry } label: { Label(model.text("删除", "Delete"), systemImage: "trash") }
                        Button { model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget); transfers = true } label: { Label(model.text("下载", "Download"), systemImage: "arrow.down.circle") }.tint(Palette.accent)
                    }
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden).disabled(mutationID != nil).refreshable { if mutationID == nil { await load(directory) } }
                    .overlay { if !loading && !searching && shown.isEmpty { EmptyMessage(icon: "folder", title: model.text("没有文件", "No files"), message: filter.isEmpty ? model.text("使用上传按钮添加文件。", "Use Upload to add files.") : model.text("没有匹配的文件。", "No matching files.")) } }
            }
            if selecting { selectionBar }
        }.pageBackground().navigationTitle(model.text("文件", "Files")).navigationBarTitleDisplayMode(.inline)
            .modifier(FileBrowserSearchDismissal(request: searchDismissal))
            .searchable(text: $filter, prompt: model.text("搜索文件或路径", "Search files or paths"))
            .modifier(FileBrowserSearchToolbarBehavior())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button { selecting.toggle(); if !selecting { selectedOnly = false } } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle") }.accessibilityLabel(model.text("选择多个文件", "Select files")).accessibilityIdentifier("files-select") }
                ToolbarItem(placement: .navigationBarTrailing) { Menu {
                    Button(model.text("上传文件", "Upload files"), systemImage: "doc.badge.arrow.up") { folderImporter = false; importer = true }
                    Button(model.text("上传文件夹", "Upload folder"), systemImage: "folder.badge.plus") { folderImporter = true; importer = true }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(model.text("上传", "Upload")).accessibilityIdentifier("files-upload") }
                ToolbarItem(placement: .navigationBarTrailing) { Button { transfers = true } label: { Image(systemName: "arrow.up.arrow.down.circle") }.accessibilityLabel(model.text("传输", "Transfers")) }
                ToolbarItem(placement: .navigationBarTrailing) { Menu {
                    Button(model.text("新建文件夹", "New folder"), systemImage: "folder.badge.plus") { newFolderName = ""; creatingFolder = true }.disabled(mutationID != nil).accessibilityIdentifier("files-new-folder")
                    Button(model.text("复制当前路径", "Copy current path"), systemImage: "doc.on.doc") { UIPasteboard.general.string = directory }.accessibilityIdentifier("files-copy-current-path")
                    Button(model.text("在此打开终端", "Open terminal here"), systemImage: "terminal") { launchHere(agent: false) }.accessibilityIdentifier("files-open-terminal")
                    Button(model.text("在此启动 AI 助手", "Start AI agent here"), systemImage: "sparkles") { launchHere(agent: true) }.accessibilityIdentifier("files-open-agent")
                    Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).onChange(of: model.settings.showHiddenFiles) { _ in model.saveSettings() }.accessibilityIdentifier("files-show-hidden")
                    Menu(model.text("排序", "Sort")) {
                        sortChoice(.name, chinese: "名称", english: "Name")
                        sortChoice(.size, chinese: "大小", english: "Size")
                        sortChoice(.modified, chinese: "修改时间", english: "Modified")
                        sortChoice(.type, chinese: "类型", english: "Type")
                    }.accessibilityIdentifier("files-sort")
                    Toggle(model.text("降序", "Descending"), isOn: $model.settings.fileSortDescending).onChange(of: model.settings.fileSortDescending) { _ in model.saveSettings() }.accessibilityIdentifier("files-sort-descending")
                    Button(model.text("刷新", "Refresh"), systemImage: "arrow.clockwise") { navigate(directory) }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("files-options") }
            }
            .task { if downloadSelection { selecting = true }; await load(initialDirectory == "~" ? "." : initialDirectory) }
            .onAppear { visible = true; receiveSharedUpload() }
            .onDisappear { visible = false; cancelMutation() }
            .onReceive(model.files.$pendingSharedUploads) { _ in
                // @Published emits before storage changes. Receive on the next main-queue turn.
                DispatchQueue.main.async { receiveSharedUpload() }
            }
            .onChange(of: model.path) { _ in receiveSharedUpload() }
            .onChange(of: model.sheet?.id) { _ in receiveSharedUpload() }
            .onChange(of: model.childModalCount) { _ in receiveSharedUpload() }
            .onChange(of: model.authentication?.id) { _ in receiveSharedUpload() }
            .task(id: searchRequest) { await search(searchRequest) }
            .fileImporter(isPresented: $importer, allowedContentTypes: folderImporter ? [.folder] : [.item], allowsMultipleSelection: true) { result in folderImporter = false; receiveImport(result) }
            .onChange(of: importer) { if !$0 { folderImporter = false } }
            .sheet(item: $preview, onDismiss: receiveSharedUpload) { entry in FilePreviewScreen(host: host, entry: entry, connectionTarget: connectionTarget).environmentObject(model) }
            .sheet(isPresented: $transfers, onDismiss: { navigate(directory); receiveSharedUpload() }) { TransferScreen(transfers: model.files).environmentObject(model) }
            .sheet(isPresented: Binding(get: { !uploadURLs.isEmpty }, set: { if !$0 { uploadURLs = [] } }), onDismiss: {
                if let sharedUploadID { model.files.finishSharedUpload(sharedUploadID); self.sharedUploadID = nil }
                if showTransfersAfterUpload { showTransfersAfterUpload = false; transfers = true }
                else { receiveSharedUpload() }
            }) {
                UploadFilesSheet(host: host, urls: uploadURLs, initialDirectory: directory == "." ? initialDirectory : directory, sessionID: sessionID, insertionRuntime: targetRuntime, connectionTarget: connectionTarget) { showTransfersAfterUpload = true; uploadURLs = [] }.environmentObject(model)
            }
            .alert(model.text("重命名", "Rename"), isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
                TextField(model.text("文件名", "Name"), text: $newName).accessibilityIdentifier("files-rename-name")
                Button(model.text("保存", "Save")) { if let entry = renameEntry { rename(entry) } }.accessibilityIdentifier("files-rename-save")
                Button(model.text("取消", "Cancel"), role: .cancel) { renameEntry = nil }
            }
            .alert(model.text("新建文件夹", "New folder"), isPresented: $creatingFolder) {
                TextField(model.text("文件夹名称", "Folder name"), text: $newFolderName).accessibilityIdentifier("files-folder-name")
                Button(model.text("创建", "Create")) { createFolder() }.disabled(!isSafeRemoteEntryName(newFolderName)).accessibilityIdentifier("files-create-folder")
                Button(model.text("取消", "Cancel"), role: .cancel) { newFolderName = "" }
            }
            .confirmationDialog(model.text("删除 \(deleteEntry?.name ?? "")？", "Delete \(deleteEntry?.name ?? "")?"), isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }), titleVisibility: .visible) {
                Button(model.text("永久删除", "Delete permanently"), role: .destructive) { if let entry = deleteEntry { remove(entry) } }.accessibilityIdentifier("files-delete-confirm")
            } message: { Text(model.text("此操作会删除服务器上的文件。", "This deletes files on the server.")) }
    }
    private func receiveSharedUpload() {
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
    private func launchHere(agent: Bool) {
        if let onLaunchDirectory { onLaunchDirectory(agent, directory) }
        else { model.sheet = .launch(host, agent, directory: directory) }
    }
    private var selectionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(model.text("全选", "Select all")) { for entry in shown where !entry.isDirectory && !selected.contains(where: { $0.path == entry.path }) { selected.append(entry) } }.accessibilityIdentifier("files-select-all")
                Button(model.text("清空", "Clear")) { selected = [] }.disabled(selected.isEmpty)
                Spacer()
                Toggle(model.text("仅已选", "Selected only"), isOn: $selectedOnly).fixedSize().accessibilityIdentifier("files-selected-only")
            }.font(.subheadline)
            Button {
                let names = downloadNames(paths: selected.map(\.path))
                for entry in selected { model.files.download(entry, host: host, model: model, name: names[entry.path], connectionTarget: connectionTarget) }
                transfers = true
            } label: {
                Label(model.text("下载已选文件 (\(selected.count))", "Download selected (\(selected.count))"), systemImage: "arrow.down.circle")
            }.buttonStyle(RoamButtonStyle(primary: true)).disabled(selected.isEmpty).accessibilityIdentifier("files-download-selected")
        }.padding(12).background(Palette.panel)
    }
    private func toggleSelection(_ entry: RemoteEntry) {
        if selected.contains(where: { $0.path == entry.path }) { selected.removeAll { $0.path == entry.path } }
        else { selected.append(entry) }
    }
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { navigate("/") } label: { Image(systemName: "internaldrive") }.frame(width: 36, height: 40)
                let components = directory.split(separator: "/").map(String.init)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.secondary)
                    Button(component) { navigate("/" + components.prefix(index + 1).joined(separator: "/")) }.font(.subheadline).lineLimit(1).accessibilityIdentifier("files-breadcrumb-/" + components.prefix(index + 1).joined(separator: "/"))
                }
            }.padding(.horizontal, 16)
        }.background(Palette.panel)
    }
    @ViewBuilder private func entryActions(_ entry: RemoteEntry) -> some View {
        Button(model.text("下载", "Download"), systemImage: "arrow.down.circle") { model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget); transfers = true }.accessibilityIdentifier("files-action-download")
        Button(model.text("复制路径", "Copy path"), systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
        if let runtime = targetRuntime {
            Button(model.text("插入终端", "Insert in terminal"), systemImage: "terminal") { if runtime.send(shellQuote(entry.path)) { model.path = [.host(host.id), .terminal(runtime.record.id)] } }
        }
        if !entry.isDirectory { Button(model.text("选择", "Select"), systemImage: "checkmark.circle") { selecting = true; toggleSelection(entry) } }
        Button(model.text("重命名", "Rename"), systemImage: "pencil") { newName = entry.name; renameEntry = entry }.accessibilityIdentifier("files-action-rename")
        Button(model.text("删除", "Delete"), systemImage: "trash", role: .destructive) { deleteEntry = entry }.accessibilityIdentifier("files-action-delete")
    }
    private func fileIcon(_ entry: RemoteEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) { return "photo" }
        if ["zip", "tar", "gz", "xz", "7z"].contains(ext) { return "doc.zipper" }
        if ["swift", "py", "js", "ts", "go", "rs", "c", "h", "sh", "json", "yaml"].contains(ext) { return "curlybraces" }
        return "doc.text"
    }
    private func receiveImport(_ result: Result<[URL], Error>) {
        do { uploadURLs = try result.get() }
        catch { if (error as NSError).code != NSUserCancelledError { actionError = error.localizedDescription } }
    }
    private func navigate(_ path: String) { searchDismissal += 1; filter = ""; selectedOnly = false; Task { await load(path) } }
    private func search(_ request: SearchRequest) async {
        searchWarning = nil
        guard !request.prefix.isEmpty else { searchEntries = []; searching = false; return }
        searching = true; searchEntries = []
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            let ssh = try await model.connection(for: connectionTarget)
            let result = try await resolveRemoteSearchDirectories(directory: request.directory, prefix: request.prefix, showHidden: request.hidden) { path in
                try model.validate(connectionTarget)
                return try await performInBackground { try ssh.listDirectory(path) }
            }
            try Task.checkCancellation()
            try model.validate(connectionTarget)
            guard searchRequest == request else { return }
            var seen = Set<String>()
            searchEntries = result.directories.flatMap(\.entries).filter { seen.insert($0.path).inserted }
            if result.limited { searchWarning = model.text("搜索达到目录读取上限，请缩小路径范围。", "Search reached its folder limit. Refine the path.") }
            else if result.unreadable { searchWarning = model.text("部分目录无法读取。", "Some folders could not be read.") }
        } catch is CancellationError { return }
        catch { guard searchRequest == request else { return }; searchWarning = error.localizedDescription }
        if searchRequest == request { searching = false }
    }
    private func load(_ path: String) async {
        revision += 1; let token = revision; loading = true; failure = nil
        do {
            let ssh = try await model.connection(for: connectionTarget)
            try Task.checkCancellation()
            let listing = try await performInBackground { try ssh.listDirectory(path) }
            guard token == revision, !Task.isCancelled else { return }
            try model.validate(connectionTarget)
            directory = listing.path; entries = listing.entries
        } catch { if token == revision { failure = error.localizedDescription } }
        if token == revision { loading = false }
    }
    private func rename(_ entry: RemoteEntry) {
        let name = newName; renameEntry = nil
        guard isSafeRemoteEntryName(name) else { actionError = model.text("文件名不能包含路径分隔符或空名称", "Enter a file name without path separators"); return }
        let destination = joinRemotePath(directory: parentRemotePath(entry.path), name: name)
        startMutation(label: model.text("正在重命名…", "Renaming…"), removingSelection: entry.path) { ssh, token in
            try ssh.rename(entry.path, to: destination, cancellation: token)
        }
    }
    private func createFolder() {
        let name = newFolderName, parent = directory
        guard isSafeRemoteEntryName(name) else { return }
        startMutation(label: model.text("正在创建文件夹…", "Creating folder…")) { ssh, token in
            try ssh.createDirectory(joinRemotePath(directory: parent, name: name), cancellation: token)
        }
    }
    private func remove(_ entry: RemoteEntry) {
        deleteEntry = nil
        startMutation(label: model.text("正在删除…", "Deleting…"), removingSelection: entry.path) { ssh, token in
            try ssh.remove(entry.path, recursive: entry.isDirectory, cancellation: token)
        }
    }
    private func sortChoice(_ sort: RemoteFileSort, chinese: String, english: String) -> some View {
        Button { model.settings.chooseFileSort(sort); model.saveSettings() } label: {
            if model.settings.fileSort == sort { Label(model.text(chinese, english), systemImage: "checkmark") }
            else { Text(model.text(chinese, english)) }
        }.accessibilityIdentifier("files-sort-" + sort.rawValue)
    }
    private var mutationProgress: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(mutationCancelling ? model.text("正在取消…", "Cancelling…") : mutationLabel).font(.subheadline).accessibilityIdentifier("files-operation-status")
            Spacer()
            Button(model.text("取消", "Cancel")) { cancelMutation() }.disabled(mutationCancelling).accessibilityIdentifier("files-operation-cancel")
        }.padding(12).background(Palette.panel)
    }
    private func cancelMutation() {
        guard mutationID != nil else { return }
        mutationCancelling = true
        mutationCancellation?.cancel()
        mutationTask?.cancel()
    }
    private func startMutation(label: String, removingSelection: String? = nil,
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

/// Read the search environment inside `.searchable`; clearing its text alone leaves
/// native search active and can hide both the folder tools and the picker's Done button.
private struct FileBrowserSearchDismissal: ViewModifier {
    @Environment(\.dismissSearch) private var dismissSearch
    let request: Int
    func body(content: Content) -> some View {
        content.onChange(of: request) { _ in dismissSearch() }
    }
}

private struct FileBrowserSearchToolbarBehavior: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}
