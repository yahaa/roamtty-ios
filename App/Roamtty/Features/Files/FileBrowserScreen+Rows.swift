import SwiftUI
import RoamttyCore

/// One entry of the listing: its row in portrait and in landscape, and what can be done with it.
extension FileBrowserScreen {
    func row(_ entry: RemoteEntry, compact: Bool) -> some View {
        HStack(spacing: 0) {
            Button { if entry.isDirectory { navigate(entry.path) } else if selecting { toggleSelection(entry) } else { preview = entry } } label: {
                if compact { landscapeRow(entry) } else { portraitRow(entry) }
            }.buttonStyle(.plain)
                .accessibilityIdentifier("files-entry-\(entry.path)").accessibilityValue(isSelected(entry) ? model.text("已选择", "Selected") : "")
            Menu { entryActions(entry) } label: { AppIcon("ic_more").foregroundStyle(Palette.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(model.text("文件操作：", "File actions: ") + entry.name).accessibilityIdentifier("files-row-menu-\(entry.name)")
        }.listRowBackground(Palette.background).listRowSeparator(compact ? .visible : .hidden).listRowSeparatorTint(Palette.outline)
            .listRowInsets(compact ? EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0) : EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 4))
            .contextMenu { entryActions(entry) }.swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleteEntry = entry } label: { Label(model.text("删除", "Delete"), systemImage: "trash") }
                Button {
                    model.files.download(entry, host: host, connectionTarget: connectionTarget)
                    transfers = true
                } label: {
                    Label(model.text("下载", "Download"), systemImage: "arrow.down.circle")
                }.tint(Palette.accent)
            }
    }

    private func isSelected(_ entry: RemoteEntry) -> Bool { selected.contains { $0.path == entry.path } }

    @ViewBuilder
    private func selectionMark(_ entry: RemoteEntry) -> some View {
        if selecting && !entry.isDirectory {
            Image(systemName: isSelected(entry) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent)
        }
    }

    private func portraitRow(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 16) {
            selectionMark(entry)
            RemoteFileIcon(name: entry.name, directory: entry.isDirectory, permissions: entry.isSymlink ? 0 : entry.permissions, link: entry.isSymlink, size: 28)
                .opacity(entry.name.hasPrefix(".") ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(Palette.foreground.opacity(entry.name.hasPrefix(".") ? 0.7 : 1)).font(.body).lineLimit(1).truncationMode(.middle)
                if selectedOnly || !searchPrefix.isEmpty { Text(parentRemotePath(entry.path)).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1) }
                let meta = entryMeta(entry)
                if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }

    /// A compact table row: the name takes the width, then the size and the modified time in their own columns.
    private func landscapeRow(_ entry: RemoteEntry) -> some View {
        let hidden = entry.name.hasPrefix(".")
        return HStack(spacing: 12) {
            selectionMark(entry)
            RemoteFileIcon(name: entry.name, directory: entry.isDirectory, permissions: entry.isSymlink ? 0 : entry.permissions, link: entry.isSymlink, size: 24)
                .opacity(hidden ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).foregroundStyle(Palette.foreground.opacity(hidden ? 0.7 : 1)).font(.body).lineLimit(1).truncationMode(.middle)
                if selectedOnly || !searchPrefix.isEmpty { Text(parentRemotePath(entry.path)).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isSymlink ? model.text("链接", "Link") : entry.isDirectory ? "" : sizeLabel(entry.size)).frame(width: 84, alignment: .trailing)
            Text(entry.mtime > 0 ? Self.mtimeFormat.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime))) : "").frame(width: 128, alignment: .trailing)
        }.font(.footnote.monospacedDigit()).foregroundStyle(Palette.secondary).lineLimit(1).frame(minHeight: 40).contentShape(Rectangle())
    }

    static let mtimeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    /// Android `RemoteFileRow` meta: 链接 · size · yyyy-MM-dd HH:mm.
    func entryMeta(_ entry: RemoteEntry) -> String {
        var parts: [String] = []
        if entry.isSymlink { parts.append(model.text("链接", "Link")) }
        if !entry.isDirectory && !entry.isSymlink, let size = entry.size, size >= 0 { parts.append(sizeLabel(size)) }
        if entry.mtime > 0 { parts.append(Self.mtimeFormat.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime)))) }
        return parts.joined(separator: " · ")
    }
    func sizeLabel(_ size: Int64?) -> String {
        guard let size, size >= 0 else { return "" }
        let value = Double(size)
        return size < 1024 ? "\(size) B" : size < 1 << 20 ? "\(size / 1024) KiB" : size < 1 << 30 ? String(format: "%.1f MiB", value / 1048576) : String(format: "%.1f GiB", value / 1073741824)
    }
    @ViewBuilder func entryActions(_ entry: RemoteEntry) -> some View {
        Button(entry.isDirectory ? model.text("打开", "Open") : model.text("查看内容", "View")) {
            if entry.isDirectory { navigate(entry.path) } else { preview = entry }
        }.accessibilityIdentifier("files-action-open")
        if entry.isDirectory && !downloadSelection {
            Button {
                if let onLaunchDirectory { onLaunchDirectory(false, entry.path) } else { model.sheet = .launch(host, false, directory: entry.path) }
            } label: {
                Label { Text(model.text("打开终端", "Open terminal")) } icon: { Image("ic_sessions") }
            }.accessibilityIdentifier("files-action-open-terminal")
            Button {
                if let onLaunchDirectory { onLaunchDirectory(true, entry.path) } else { model.sheet = .launch(host, true, directory: entry.path) }
            } label: {
                Label { Text("Agent") } icon: { Image("ic_agent") }
            }.accessibilityIdentifier("files-action-open-agent")
        }
        // iOS also downloads folders recursively, so 下载 is offered for both.
        Button(model.text("下载", "Download")) {
            model.files.download(entry, host: host, connectionTarget: connectionTarget)
            transfers = true
        }.accessibilityIdentifier("files-action-download")
        if !entry.isDirectory { Button(model.text("选择", "Select")) { selecting = true; toggleSelection(entry) } }
        Button(model.text("复制路径", "Copy path")) { UIPasteboard.general.string = entry.path }.accessibilityIdentifier("files-action-copy-path")
        if let runtime = targetRuntime {
            Button(model.text("插入终端", "Insert in terminal")) { insertInTerminal(entry, runtime: runtime) }
        }
        Button(model.text("重命名", "Rename")) { newName = entry.name; renameEntry = entry }.accessibilityIdentifier("files-action-rename")
        Divider()
        Button(model.text("删除", "Delete"), role: .destructive) { deleteEntry = entry }.accessibilityIdentifier("files-action-delete")
    }
}
