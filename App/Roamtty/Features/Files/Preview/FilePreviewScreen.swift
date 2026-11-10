import SwiftUI
import UIKit
import ImageIO
import RoamttyCore
import RoamttyTransport

struct FilePreviewScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let host: Host
    let entry: RemoteEntry
    let connectionTarget: RemoteConnectionTarget
    /// A line to show and mark (1-based), as a tapped `path:line` in the terminal names it; 0 for none.
    var line: Int = 0
    @State private var content: RemoteFileContent?
    @State private var document: CodeDocument?
    @State private var blocks: [MdBlock] = []
    @State private var image: UIImage?
    @State private var imageDimensions: String?
    @State private var failure: String?
    @State private var rendered = true
    @State private var query = ""
    @State private var searchVisible = false
    @State private var match = 0
    @State private var matches: [CodeMatch] = []
    @State private var fullImage = false
    @State private var transfers = false
    @State private var reloadID = 0
    @State private var previewLimit = textPreviewBytes
    private var previewFontSize: Double { model.settings.codeFontSize }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if compact { landscapeBar }
                if searchVisible { searchBar }
                if let image {
                    ZoomableImage(image: image).accessibilityIdentifier("file-image-preview").onTapGesture(count: 2) { fullImage = true }
                } else if document != nil {
                    documentView(fullscreen: false)
                } else if let failure {
                    EmptyMessage(icon: "exclamationmark.triangle", title: model.text("无法预览", "Unable to preview"), message: failure)
                    Button(model.text("重试", "Retry")) { reloadID += 1 }.accessibilityIdentifier("preview-retry")
                    Spacer()
                } else if content != nil {
                    EmptyMessage(icon: "doc", title: model.text("二进制文件", "Binary file"), message: model.text("下载文件后使用其他应用打开。", "Download this file to open it in another app."))
                    Spacer()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let content, !compact {
                    HStack {
                        Text(formattedBytes(content.size))
                        if content.truncated {
                            Text(previewLimit == imagePreviewBytes ? model.text("图片上限 8 MiB", "Image limit: 8 MiB") : model.text("仅预览前 256 KiB",
                                "Preview limited to 256 KiB")).foregroundStyle(Palette.warning)
                        }
                        Spacer()
                        if let imageDimensions { Text(imageDimensions).accessibilityIdentifier("preview-image-dimensions") }
                        if let document {
                            Text("\(document.lineCount) " + model.text("行", "lines"))
                            Text(document.language.displayName)
                            Text("\(Int(previewFontSize)) pt").accessibilityIdentifier("preview-font-size")
                            Text(model.settings.codeWrap ? model.text("换行", "Wrapped") : model.text("不换行", "No wrap")).accessibilityIdentifier("preview-wrap-status")
                        }
                    }.font(.caption).foregroundStyle(Palette.secondary).padding(12).background(Palette.panel)
                }
            }.pageBackground().navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                .toolbar(compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { doneButton }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { download() } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel(model.text("下载", "Download")).accessibilityIdentifier("preview-download")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) { Menu { optionsMenu } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("preview-options") }
                }
        }.onChange(of: query) { _ in updateMatches() }
        .task(id: reloadID) {
            content = nil; document = nil; blocks = []; image = nil; imageDimensions = nil; failure = nil; matches = []; match = 0
            // A line to show is a line of the source, so Markdown opens as source there.
            if line > 0 && reloadID == 0 { rendered = false }
            let cancellation = TransferCancellation()
            await withTaskCancellationHandler(operation: {
                do {
                    let ssh = try await model.connection(for: connectionTarget)
                    try Task.checkCancellation()
                    let isImage = entry.kind == .image
                    previewLimit = isImage ? imagePreviewBytes : textPreviewBytes
                    let result = try await performInBackground { try ssh.readFile(entry.path, maxBytes: isImage ? imagePreviewBytes : textPreviewBytes, cancellation: cancellation) }
                    try Task.checkCancellation()
                    try model.validate(connectionTarget)
                    content = result
                    if isImage && !result.truncated {
                        let decoded = try await performInBackground { decodePreviewImage(result.data) }
                        try Task.checkCancellation()
                        image = decoded?.image; imageDimensions = decoded?.dimensions
                        if decoded != nil { return }
                    }
                    // SVG and other text-backed image formats retain a bounded source preview.
                    let textResult = result.data.count <= textPreviewBytes ? result : RemoteFileContent(data: Data(result.data.prefix(textPreviewBytes)), size: result.size, truncated: true)
                    if let text = textResult.text {
                        content = textResult; previewLimit = textPreviewBytes
                        let language = Languages.detect(fileName: entry.name, firstLine: String(text.prefix { !$0.isNewline }))
                        let highlighted = try await performInBackground { SyntaxHighlighter.highlight(text, language) }
                        let parsed = language.mode == .markdown ? try await performInBackground { MarkdownParser.parse(text) } : []
                        try Task.checkCancellation()
                        document = highlighted; blocks = parsed; updateMatches()
                    } else if isImage {
                        failure = result.truncated ? model.text("图片超过 8 MiB，请下载后查看。",
                            "This image exceeds 8 MiB. Download it to view the complete file.") : model.text("此图片格式无法预览，请下载后查看。",
                            "This image format cannot be previewed. Download it to open in another app.")
                    }
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }, onCancel: { cancellation.cancel() })
        }
        .modifier(ChildModalPresence())
        .overlay { AuthenticationOverlay() }
        .fullScreenCover(isPresented: $fullImage) {
            if let image {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    ZoomableImage(image: image).ignoresSafeArea().accessibilityIdentifier("file-image-fullscreen")
                    Button { fullImage = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white).padding(24)
                    }.accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-image-close")
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    documentView(fullscreen: true).pageBackground()
                    Button { fullImage = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).padding(12).background(.ultraThinMaterial, in: Circle())
                    }.padding(12).accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-fullscreen-close")
                }
            }
        }
        .sheet(isPresented: $transfers) { TransferScreen(transfers: model.files).environmentObject(model) }
    }
    private var compact: Bool { verticalSizeClass == .compact }
    private var doneButton: some View { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("preview-done") }
    private func download() { model.files.download(entry, host: host, connectionTarget: connectionTarget); transfers = true }
    @ViewBuilder private var optionsMenu: some View {
            Button(model.text("查找", "Find"), systemImage: "magnifyingglass") { rendered = false; searchVisible = true }.disabled(document == nil).accessibilityIdentifier("preview-find")
            Toggle(model.text("自动换行", "Wrap lines"), isOn: $model.settings.codeWrap).onChange(of: model.settings.codeWrap) { _ in model.saveSettings() }.accessibilityIdentifier("preview-wrap")
            if document?.language.mode == .markdown { Toggle(model.text("渲染 Markdown", "Render Markdown"), isOn: $rendered).accessibilityIdentifier("preview-render-markdown") }
            if document != nil {
                Button("A− · " + model.text("缩小字体", "Smaller text")) {
                    model.settings.codeFontSize = max(9, previewFontSize - 1)
                    model.saveSettings()
                }.disabled(previewFontSize <= 9).accessibilityIdentifier("preview-font-smaller")
                Button("A+ · " + model.text("放大字体", "Larger text")) {
                    model.settings.codeFontSize = min(22, previewFontSize + 1)
                    model.saveSettings()
                }.disabled(previewFontSize >= 22).accessibilityIdentifier("preview-font-larger")
            }
            if document != nil || image != nil {
                Button(model.text("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right") { fullImage = true }.accessibilityIdentifier("preview-fullscreen")
            }
            Button(model.text("复制路径", "Copy path"), systemImage: "link") { UIPasteboard.general.string = entry.path }.accessibilityIdentifier("preview-copy-path")
            if let text = content?.text { Button(model.text("复制全部", "Copy all"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
            Button(model.text("重新加载", "Reload"), systemImage: "arrow.clockwise") { reloadID += 1 }
    }
    /// Landscape: one flat bar in place of the navigation bar and the status line under the file: done, the name with
    /// its size, lines and language after it, then download and the menu. The file keeps the rest of the height.
    private var landscapeBar: some View {
        LandscapeBar(title: entry.name, detail: content.map(details)) { doneButton.buttonStyle(TextActionStyle()) } trailing: {
            if let content, content.truncated {
                Text(previewLimit == imagePreviewBytes ? model.text("图片上限 8 MiB", "Image limit: 8 MiB") : model.text("仅预览前 256 KiB", "Preview limited to 256 KiB"))
                    .font(.footnote).foregroundStyle(Palette.warning).lineLimit(1)
            }
            BarIconButton(icon: "ic_download", label: model.text("下载", "Download"), id: "preview-download") { download() }
            Menu { optionsMenu } label: { AppIcon("ic_more", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("preview-options")
        }
    }
    /// The status line's words, joined for the landscape bar.
    private func details(_ content: RemoteFileContent) -> String {
        var parts = [formattedBytes(content.size)]
        if let imageDimensions { parts.append(imageDimensions) }
        if let document {
            parts += ["\(document.lineCount) " + model.text("行", "lines"), document.language.displayName, "\(Int(previewFontSize)) pt",
                      model.settings.codeWrap ? model.text("换行", "Wrapped") : model.text("不换行", "No wrap")]
        }
        return parts.joined(separator: " · ")
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField(model.text("在文件中查找", "Find in file"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("preview-search")
            Text(query.isEmpty ? "" : matches.isEmpty ? model.text("无结果", "No results") : "\(match + 1)/\(matches.count)").font(.caption).fixedSize().accessibilityIdentifier("preview-search-count")
            Button {
                match = codeMatchIndex(current: match, delta: -1, count: matches.count)
            } label: {
                Image(systemName: "chevron.up")
            }.disabled(matches.isEmpty).accessibilityLabel(model.text("上一个", "Previous match")).accessibilityIdentifier("preview-search-previous")
            Button {
                match = codeMatchIndex(current: match, delta: 1, count: matches.count)
            } label: {
                Image(systemName: "chevron.down")
            }.disabled(matches.isEmpty).accessibilityLabel(model.text("下一个", "Next match")).accessibilityIdentifier("preview-search-next")
            Button { searchVisible = false; query = "" } label: { Image(systemName: "xmark") }.accessibilityLabel(model.text("关闭查找", "Close search")).accessibilityIdentifier("preview-search-close")
        }.padding(12).background(Palette.panel)
    }
    @ViewBuilder private func documentView(fullscreen: Bool) -> some View {
        if let document {
            if document.language.mode == .markdown && rendered {
                GeometryReader { viewport in
                    ScrollView {
                        MarkdownContent(blocks: blocks, connectionTarget: connectionTarget,
                                        directory: parentRemotePath(entry.path), fontSize: previewFontSize,
                                        viewport: viewport.size, coordinateSpace: fullscreen ? "markdown-fullscreen" : "markdown-normal",
                                        imagesEnabled: fullscreen || !fullImage)
                            .padding(16).frame(maxWidth: 840)
                    }.coordinateSpace(name: fullscreen ? "markdown-fullscreen" : "markdown-normal")
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(fullscreen ? "file-markdown-fullscreen" : "file-markdown-preview")
                }
            } else {
                CodeTextView(document: document, fontName: model.settings.font, fontSize: previewFontSize, wrap: model.settings.codeWrap,
                    query: query, match: match, matches: matches, identifier: fullscreen ? "file-code-fullscreen" : "file-code-preview", markedLine: line).id(reloadID)
            }
        }
    }
    private func updateMatches() {
        matches = document.map { findCodeMatches($0, query: query) } ?? []
        match = 0
    }
}
private struct DecodedPreviewImage {
    let image: UIImage
    let dimensions: String
}
private func decodePreviewImage(_ data: Data) -> DecodedPreviewImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
    return DecodedPreviewImage(image: UIImage(cgImage: thumbnail), dimensions: "\(width.intValue) × \(height.intValue)")
}
