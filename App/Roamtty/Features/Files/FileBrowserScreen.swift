import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore
import RoamttyTransport

/// A host's remote folders: browsing, searching, previewing, transfers and file operations. The screen's parts
/// are in `FileBrowserScreen+*.swift`, which is why its state is not private.
struct FileBrowserScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.dismiss) var dismiss
    let host: Host
    var sessionID: String?
    var initialDirectory = "."
    var downloadSelection = false
    var onLaunchDirectory: ((Bool, String) -> Void)?
    @State var connectionTarget: RemoteConnectionTarget
    @State var directory = "."
    @State var entries: [RemoteEntry] = []
    /// Names in this folder that are not UTF-8; they are left out, since no path built from them would be exact.
    @State var unreadableNames = 0
    @State var loading = false
    @State var failure: String?
    @State var actionError: String?
    @State var filter = ""
    @State var searchDismissal = 0
    @FocusState var searchFocused: Bool
    @State var preview: RemoteEntry?
    @State var renameEntry: RemoteEntry?
    @State var newName = ""
    @State var deleteEntry: RemoteEntry?
    @State var importer = false
    @State var folderImporter = false
    @State var transfers = false
    @State var uploadURLs: [URL] = []
    @State var showTransfersAfterUpload = false
    @State var sharedUploadID: UUID?
    @State var visible = false
    @State var revision = 0
    @State var searchEntries: [RemoteEntry] = []
    @State var searching = false
    @State var searchWarning: String?
    @State var selecting = false
    @State var selected: [RemoteEntry] = []
    @State var selectedOnly = false
    @State var creatingFolder = false
    @State var newFolderName = ""
    @State var mutationID: UUID?
    @State var mutationLabel = ""
    @State var mutationCancellation: TransferCancellation?
    @State var mutationTask: Task<Void, Never>?
    @State var mutationCancelling = false

    init(host: Host, sessionID: String? = nil, initialDirectory: String = ".", downloadSelection: Bool = false,
         connectionTarget: RemoteConnectionTarget, onLaunchDirectory: ((Bool, String) -> Void)? = nil) {
        self.host = host; self.sessionID = sessionID; self.initialDirectory = initialDirectory; self.downloadSelection = downloadSelection
        self.onLaunchDirectory = onLaunchDirectory
        _connectionTarget = State(initialValue: connectionTarget)
    }

    struct SearchRequest: Equatable {
        let directory: String
        let prefix: String
        let hidden: Bool
        let revision: Int
    }
    var searchPrefix: String { filter.lastIndex(of: "/").map { String(filter[...$0]) } ?? "" }
    var searchRequest: SearchRequest { SearchRequest(directory: directory, prefix: searchPrefix, hidden: model.settings.showHiddenFiles, revision: revision) }
    var targetRuntime: SessionRuntime? {
        guard let sessionID, let runtime = connectionTarget.runtime, runtime.record.id == sessionID, runtime.host.id == host.id else { return nil }
        do { try model.validate(connectionTarget) } catch { return nil }
        return runtime
    }
    /// The entries on screen: filtered, ranked and sorted, which walks every entry of a large folder.
    var shown: [RemoteEntry] {
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
        // Worked out once per update: the summary, the list and its empty state all show the same entries.
        let shown = self.shown
        let compact = verticalSizeClass == .compact
        let page = VStack(spacing: 0) {
            if compact { landscapeBar(shown) } else { listingSummary(shown) }
            if mutationID != nil { mutationProgress }
            if let actionError { errorBanner(actionError) }
            if let searchWarning { Text(searchWarning).font(.caption).foregroundStyle(Palette.warning).padding(.horizontal, 16).accessibilityIdentifier("files-search-warning") }
            if let failure { failureNotice(failure) } else { listing(shown, compact: compact) }
            if selecting { selectionBar }
        }
        return dialogs(sheets(lifecycle(chrome(page, compact: compact))))
    }

    // MARK: Content

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message).font(.footnote).foregroundStyle(Palette.warning).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("files-operation-error")
            Button {
                actionError = nil
            } label: {
                Image(systemName: "xmark.circle")
            }.accessibilityLabel(model.text("关闭错误", "Dismiss error")).accessibilityIdentifier("files-operation-error-dismiss")
        }.padding(12).background(Palette.panel)
    }

    private func failureNotice(_ failure: String) -> some View {
        VStack(spacing: 8) {
            Text(failure).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            Button(model.text("重试", "Retry")) { navigate(directory) }.buttonStyle(TextActionStyle())
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listing(_ shown: [RemoteEntry], compact: Bool) -> some View {
        List(shown) { entry in row(entry, compact: compact) }
            .listStyle(.plain).scrollContentBackground(.hidden).disabled(mutationID != nil).refreshable { if mutationID == nil { await load(directory) } }
            .overlay { placeholder(empty: shown.isEmpty) }
    }

    /// What the list says while it has nothing to show.
    @ViewBuilder
    private func placeholder(empty: Bool) -> some View {
        if !loading && !searching && empty {
            VStack(spacing: 12) {
                RemoteFileIcon(name: "", directory: true, size: 56).opacity(0.5)
                Text(entries.isEmpty ? model.text("此目录为空", "This folder is empty") : !filter.isEmpty ? model.text("没有匹配的项目",
                    "No matching items") : model.text("没有可显示的项目", "Nothing to show"))
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
        } else if loading && entries.isEmpty {
            VStack(spacing: 16) { ProgressView(); Text(model.text("正在读取远端目录…", "Reading the remote folder…")).font(.subheadline).foregroundStyle(Palette.secondary) }
        }
    }

    // MARK: Navigation bar, lifecycle and presentations

    private func chrome(_ content: some View, compact: Bool) -> some View {
        content.pageBackground().navigationTitle(model.text("文件", "Files")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar)
            // Landscape has its own bar, with the search field in it.
            .toolbar(compact ? .hidden : .visible, for: .navigationBar)
            .modifier(FileBrowserSearchDismissal(request: searchDismissal))
            .modifier(FileBrowserSearchField(enabled: !compact, text: $filter, prompt: model.text("搜索文件或路径", "Search files or paths")))
            .modifier(FileBrowserSearchToolbarBehavior())
            .onChange(of: searchDismissal) { _ in searchFocused = false }
            .toolbar {
                ToolbarItem(placement: .principal) { pathBar.disabled(mutationID != nil) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu { optionsMenu } label: { AppIcon("ic_more", size: 24) }.accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("files-options")
                }
            }
    }

    private func lifecycle(_ content: some View) -> some View {
        content
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
    }

    private func sheets(_ content: some View) -> some View {
        content
            .fileImporter(isPresented: $importer, allowedContentTypes: folderImporter ? [.folder] : [.item], allowsMultipleSelection: true) { result in folderImporter = false; receiveImport(result) }
            .onChange(of: importer) { if !$0 { folderImporter = false } }
            .sheet(item: $preview, onDismiss: receiveSharedUpload) { entry in FilePreviewScreen(host: host, entry: entry, connectionTarget: connectionTarget).environmentObject(model) }
            .sheet(isPresented: $transfers, onDismiss: { navigate(directory); receiveSharedUpload() }) { TransferScreen(transfers: model.files).environmentObject(model) }
            .sheet(isPresented: Binding(get: { !uploadURLs.isEmpty }, set: { if !$0 { uploadURLs = [] } }), onDismiss: {
                if let sharedUploadID { model.files.finishSharedUpload(sharedUploadID); self.sharedUploadID = nil }
                if showTransfersAfterUpload { showTransfersAfterUpload = false; transfers = true } else { receiveSharedUpload() }
            }) {
                UploadFilesSheet(host: host, urls: uploadURLs, initialDirectory: directory == "." ? initialDirectory : directory,
                    sessionID: sessionID, insertionRuntime: targetRuntime, connectionTarget: connectionTarget) {
                    showTransfersAfterUpload = true
                    uploadURLs = []
                }.environmentObject(model)
            }
    }

    private func dialogs(_ content: some View) -> some View {
        content
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
            .alert(deleteEntry?.isDirectory == true ? model.text("删除文件夹？", "Delete folder?") : model.text("删除文件？", "Delete file?"),
                isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }),
                presenting: deleteEntry) { entry in
                Button(model.text("取消", "Cancel"), role: .cancel) { deleteEntry = nil }
                Button(model.text("删除", "Delete"), role: .destructive) { remove(entry) }.accessibilityIdentifier("files-delete-confirm")
            } message: { entry in
                Text(entry.path + "\n\n" + (entry.isDirectory ? model.text("将永久删除远端目录及其全部内容，此操作不可撤销。",
                    "The remote folder and everything in it will be deleted permanently. This cannot be undone.") : model.text("将永久删除远端文件，此操作不可撤销。",
                    "The remote file will be deleted permanently. This cannot be undone.")))
            }
    }
}
