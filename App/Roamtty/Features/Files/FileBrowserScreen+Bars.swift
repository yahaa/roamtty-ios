import SwiftUI
import UIKit
import RoamttyCore

/// The bars around the listing: the path, the summary and its sort control, landscape's own bar, the batch
/// download bar, the ⋯ menu and the progress of a file operation.
extension FileBrowserScreen {
    /// Android `FileBrowserPathBar`: the host as the root crumb, quiet parent folders, the current folder in title weight.
    var pathBar: some View {
        let components = directory.split(separator: "/").map(String.init)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    crumb(index: 0, current: components.isEmpty, path: "/") {
                        HStack(spacing: 6) { AppIcon("ic_os_server", size: 16).foregroundStyle(Palette.secondary); Text(host.name) }
                    }
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        AppIcon("ic_chevron_right", size: 14).foregroundStyle(Palette.adaptive(0x827A70, 0x9A9890))
                        crumb(index: index + 1, current: index == components.count - 1, path: "/" + components.prefix(index + 1).joined(separator: "/")) { Text(component) }
                    }
                }
            }.onChange(of: directory) { _ in DispatchQueue.main.async { proxy.scrollTo(components.count, anchor: .trailing) } }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(components.count, anchor: .trailing) } }
        }.frame(maxWidth: 260)
    }
    func crumb<Label: View>(index: Int, current: Bool, path: String, @ViewBuilder label: () -> Label) -> some View {
        Button { if !current { navigate(path) } } label: {
            label().font(current ? .system(size: 16, weight: .semibold) : .subheadline)
                .foregroundStyle(current ? Palette.foreground : Palette.secondary).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 10)
        }.buttonStyle(.plain).id(index).accessibilityAddTraits(current ? .isHeader : [])
            .accessibilityIdentifier("files-breadcrumb-" + path)
    }
    /// Android `ListingSummary`: what is shown, what is hidden, and the sort control.
    func listingSummary(_ shown: [RemoteEntry]) -> some View {
        HStack(spacing: 8) {
            Text(summary(shown)).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("files-summary")
            if loading || searching { ProgressView().scaleEffect(0.7) }
            Spacer()
            sortMenu
        }.padding(.leading, 20).padding(.trailing, 8)
    }
    /// What is shown and what is hidden: `33 个文件夹 · 31 个文件 · 64 项未显示`.
    func summary(_ shown: [RemoteEntry]) -> String {
        let folders = shown.filter(\.isDirectory).count, files = shown.count - folders
        let hidden = max(0, (searchPrefix.isEmpty && !selectedOnly ? entries.count : shown.count) - shown.count)
        let parts = [folders > 0 ? model.text("\(folders) 个文件夹", "\(folders) folders") : nil,
                     files > 0 ? model.text("\(files) 个文件", "\(files) files") : nil,
                     hidden > 0 ? model.text("\(hidden) 项未显示", "\(hidden) hidden") : nil,
                     unreadableNames > 0 ? model.text("\(unreadableNames) 个非 UTF-8 文件名未列出", "\(unreadableNames) non-UTF-8 names not listed") : nil].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
    var sortMenu: some View {
        Menu {
            sortChoice(.name, chinese: "名称", english: "Name")
            sortChoice(.modified, chinese: "修改时间", english: "Modified")
            sortChoice(.size, chinese: "大小", english: "Size")
            sortChoice(.type, chinese: "类型", english: "Type")
        } label: {
            HStack(spacing: 6) {
                AppIcon("ic_sort", size: 16)
                Text(sortLabel(model.settings.fileSort) + (model.settings.fileSortDescending ? " ↓" : " ↑")).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Palette.accent).padding(.horizontal, 10).frame(minHeight: 36)
        }.accessibilityIdentifier("files-sort")
    }

    func sortChoice(_ sort: RemoteFileSort, chinese: String, english: String) -> some View {
        Button { model.settings.chooseFileSort(sort); model.saveSettings() } label: {
            if model.settings.fileSort == sort { Label(model.text(chinese, english), systemImage: "checkmark") } else { Text(model.text(chinese, english)) }
        }.accessibilityIdentifier("files-sort-" + sort.rawValue)
    }

    func sortLabel(_ sort: RemoteFileSort) -> String {
        switch sort {
        case .name: return model.text("名称", "Name")
        case .modified: return model.text("修改时间", "Modified")
        case .size: return model.text("大小", "Size")
        case .type: return model.text("类型", "Type")
        }
    }

    /// Landscape, like the host page there: one flat bar with back, the path, the summary (cut short when it does not
    /// fit), the sort, the search field and the menu, in place of the navigation bar and the floating search.
    func landscapeBar(_ shown: [RemoteEntry]) -> some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                if downloadSelection {
                    Text(model.text("完成", "Done")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent).padding(.horizontal, 10).frame(height: 44)
                } else {
                    AppIcon("ic_chevron_left", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }.buttonStyle(.plain).accessibilityLabel(downloadSelection ? model.text("完成", "Done") : model.text("返回", "Back"))
                .accessibilityIdentifier(downloadSelection ? "files-picker-done" : "files-back")
            pathBar.disabled(mutationID != nil).layoutPriority(1)
            Spacer(minLength: 4)
            if loading || searching { ProgressView().scaleEffect(0.7) }
            Text(summary(shown)).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("files-summary")
            sortMenu.fixedSize()
            HStack(spacing: 6) {
                AppIcon("ic_search", size: 16).foregroundStyle(Palette.secondary)
                TextField(model.text("搜索文件或路径", "Search files or paths"), text: $filter).font(.subheadline).focused($searchFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("files-search")
                if !filter.isEmpty {
                    Button { filter = "" } label: { AppIcon("ic_clear", size: 16).foregroundStyle(Palette.secondary).frame(width: 28, height: 34) }.buttonStyle(.plain)
                        .accessibilityLabel(model.text("清除搜索", "Clear search"))
                }
            }.padding(.leading, 12).padding(.trailing, filter.isEmpty ? 12 : 4).frame(width: 210, height: 34)
                .background(Palette.foreground.opacity(0.08), in: Capsule())
            Menu { optionsMenu } label: { AppIcon("ic_more", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("files-options")
        }.padding(.horizontal, 6).frame(height: 48)
    }

    /// Two lines in portrait; one in landscape, where the height is short.
    var selectionBar: some View {
        let compact = verticalSizeClass == .compact
        let layout = compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            HStack {
                Button(model.text("全选", "Select all")) {
                    for entry in shown where !entry.isDirectory && !selected.contains(where: { $0.path == entry.path }) { selected.append(entry) }
                }.accessibilityIdentifier("files-select-all")
                Button(model.text("清空", "Clear")) { selected = [] }.disabled(selected.isEmpty)
                Spacer()
                Toggle(model.text("仅已选", "Selected only"), isOn: $selectedOnly).fixedSize().accessibilityIdentifier("files-selected-only")
            }.font(.subheadline)
            Button {
                let names = downloadNames(paths: selected.map(\.path))
                for entry in selected { model.files.download(entry, host: host, name: names[entry.path], connectionTarget: connectionTarget) }
                transfers = true
            } label: {
                Label(model.text("下载已选文件 (\(selected.count))", "Download selected (\(selected.count))"), systemImage: "arrow.down.circle")
            }.buttonStyle(RoamButtonStyle(primary: true)).frame(maxWidth: compact ? 280 : .infinity).disabled(selected.isEmpty).accessibilityIdentifier("files-download-selected")
        }.padding(.horizontal, 12).padding(.vertical, compact ? 6 : 12).background(Palette.panel)
    }

    @ViewBuilder var optionsMenu: some View {
        Button { launchHere(agent: false) } label: { Label { Text(model.text("打开终端", "Open terminal")) } icon: { Image("ic_sessions") } }.accessibilityIdentifier("files-open-terminal")
        Button { launchHere(agent: true) } label: { Label { Text("Agent") } icon: { Image("ic_agent") } }.accessibilityIdentifier("files-open-agent")
        Divider()
        Button { navigate(directory) } label: { Label { Text(model.text("刷新", "Refresh")) } icon: { Image("ic_refresh") } }.disabled(loading || mutationID != nil)
        Button {
            newFolderName = ""
            creatingFolder = true
        } label: {
            Label { Text(model.text("新建文件夹", "New folder")) } icon: { Image("ic_folder_add") }
        }.disabled(mutationID != nil).accessibilityIdentifier("files-new-folder")
        Menu {
            Button(model.text("上传文件", "Upload files")) { folderImporter = false; importer = true }
            Button(model.text("上传文件夹", "Upload folder")) { folderImporter = true; importer = true }
        } label: { Label { Text(model.text("上传", "Upload")) } icon: { Image("ic_upload") } }.accessibilityIdentifier("files-upload")
        Button {
            selecting.toggle()
            if !selecting { selectedOnly = false }
        } label: {
            Label { Text(selecting ? model.text("结束批量下载", "Finish batch download") : model.text("批量下载", "Batch download")) } icon: { Image("ic_download") }
        }.accessibilityIdentifier("files-select")
        Button { transfers = true } label: { Label { Text(model.text("传输", "Transfers")) } icon: { Image("ic_cloud_download") } }.accessibilityIdentifier("files-transfers")
        Button {
            UIPasteboard.general.string = directory
        } label: {
            Label { Text(model.text("复制当前路径", "Copy current path")) } icon: { Image("ic_copy") }
        }.accessibilityIdentifier("files-copy-current-path")
        if !downloadSelection && model.path.contains(.host(host.id)) {
            Button { model.path = [.host(host.id)] } label: { Label { Text(model.text("返回主机详情", "Back to host details")) } icon: { Image("ic_close") } }.accessibilityIdentifier("files-close")
        }
        Divider()
        Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).onChange(of: model.settings.showHiddenFiles) { _ in
            model.saveSettings()
        }.accessibilityIdentifier("files-show-hidden")
    }

    var mutationProgress: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(mutationCancelling ? model.text("正在取消…", "Cancelling…") : mutationLabel).font(.subheadline).accessibilityIdentifier("files-operation-status")
            Spacer()
            Button(model.text("取消", "Cancel")) { cancelMutation() }.disabled(mutationCancelling).accessibilityIdentifier("files-operation-cancel")
        }.padding(12).background(Palette.panel)
    }
}
