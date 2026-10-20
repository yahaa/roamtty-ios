import SwiftUI
import UIKit
import ImageIO
import RoamttyCore
import RoamttyTransport

struct FilePreviewScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let host: Host
    let entry: RemoteEntry
    let connectionTarget: RemoteConnectionTarget
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
                if searchVisible { searchBar }
                if let image { ZoomableImage(image: image).accessibilityIdentifier("file-image-preview").onTapGesture(count: 2) { fullImage = true } }
                else if document != nil { documentView(fullscreen: false) }
                else if let failure {
                    EmptyMessage(icon: "exclamationmark.triangle", title: model.text("无法预览", "Unable to preview"), message: failure)
                    Button(model.text("重试", "Retry")) { reloadID += 1 }.accessibilityIdentifier("preview-retry")
                    Spacer()
                }
                else if content != nil { EmptyMessage(icon: "doc", title: model.text("二进制文件", "Binary file"), message: model.text("下载文件后使用其他应用打开。", "Download this file to open it in another app.")); Spacer() }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let content {
                    HStack {
                        Text(formattedBytes(content.size))
                        if content.truncated { Text(previewLimit == imagePreviewBytes ? model.text("图片上限 8 MiB", "Image limit: 8 MiB") : model.text("仅预览前 256 KiB", "Preview limited to 256 KiB")).foregroundStyle(Palette.warning) }
                        Spacer()
                        if let imageDimensions { Text(imageDimensions).accessibilityIdentifier("preview-image-dimensions") }
                        if let document { Text("\(document.lineCount) " + model.text("行", "lines")); Text(document.language.displayName); Text("\(Int(previewFontSize)) pt").accessibilityIdentifier("preview-font-size"); Text(model.settings.codeWrap ? model.text("换行", "Wrapped") : model.text("不换行", "No wrap")).accessibilityIdentifier("preview-wrap-status") }
                    }.font(.caption).foregroundStyle(Palette.secondary).padding(12).background(Palette.panel)
                }
            }.pageBackground().navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("preview-done") }
                    ToolbarItem(placement: .navigationBarTrailing) { Button { model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget); transfers = true } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel(model.text("下载", "Download")).accessibilityIdentifier("preview-download") }
                    ToolbarItem(placement: .navigationBarTrailing) { Menu {
                        Button(model.text("查找", "Find"), systemImage: "magnifyingglass") { rendered = false; searchVisible = true }.disabled(document == nil).accessibilityIdentifier("preview-find")
                        Toggle(model.text("自动换行", "Wrap lines"), isOn: $model.settings.codeWrap).onChange(of: model.settings.codeWrap) { _ in model.saveSettings() }.accessibilityIdentifier("preview-wrap")
                        if document?.language.mode == .markdown { Toggle(model.text("渲染 Markdown", "Render Markdown"), isOn: $rendered).accessibilityIdentifier("preview-render-markdown") }
                        if document != nil {
                            Button("A− · " + model.text("缩小字体", "Smaller text")) { model.settings.codeFontSize = max(9, previewFontSize - 1); model.saveSettings() }.disabled(previewFontSize <= 9).accessibilityIdentifier("preview-font-smaller")
                            Button("A+ · " + model.text("放大字体", "Larger text")) { model.settings.codeFontSize = min(22, previewFontSize + 1); model.saveSettings() }.disabled(previewFontSize >= 22).accessibilityIdentifier("preview-font-larger")
                        }
                        if document != nil || image != nil { Button(model.text("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right") { fullImage = true }.accessibilityIdentifier("preview-fullscreen") }
                        Button(model.text("复制路径", "Copy path"), systemImage: "link") { UIPasteboard.general.string = entry.path }.accessibilityIdentifier("preview-copy-path")
                        if let text = content?.text { Button(model.text("复制全部", "Copy all"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                        Button(model.text("重新加载", "Reload"), systemImage: "arrow.clockwise") { reloadID += 1 }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("preview-options") }
                }
        }.onChange(of: query) { _ in updateMatches() }
        .task(id: reloadID) {
            content = nil; document = nil; blocks = []; image = nil; imageDimensions = nil; failure = nil; matches = []; match = 0
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
                        let language = Languages.detect(fileName: entry.name, firstLine: text.components(separatedBy: .newlines).first ?? "")
                        let highlighted = try await performInBackground { SyntaxHighlighter.highlight(text, language) }
                        let parsed = language.mode == .markdown ? try await performInBackground { MarkdownParser.parse(text) } : []
                        try Task.checkCancellation()
                        document = highlighted; blocks = parsed; updateMatches()
                    } else if isImage {
                        failure = result.truncated ? model.text("图片超过 8 MiB，请下载后查看。", "This image exceeds 8 MiB. Download it to view the complete file.") : model.text("此图片格式无法预览，请下载后查看。", "This image format cannot be previewed. Download it to open in another app.")
                    }
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }, onCancel: { cancellation.cancel() })
        }
        .modifier(ChildModalPresence())
        .overlay { AuthenticationOverlay() }
        .fullScreenCover(isPresented: $fullImage) {
            if let image { ZStack(alignment: .topTrailing) { Color.black.ignoresSafeArea(); ZoomableImage(image: image).ignoresSafeArea().accessibilityIdentifier("file-image-fullscreen"); Button { fullImage = false } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white).padding(24) }.accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-image-close") } }
            else {
                ZStack(alignment: .topTrailing) {
                    documentView(fullscreen: true).pageBackground()
                    Button { fullImage = false } label: { Image(systemName: "xmark.circle.fill").font(.title).padding(12).background(.ultraThinMaterial, in: Circle()) }.padding(12).accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-fullscreen-close")
                }
            }
        }
        .sheet(isPresented: $transfers) { TransferScreen(transfers: model.files).environmentObject(model) }
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField(model.text("在文件中查找", "Find in file"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("preview-search")
            Text(query.isEmpty ? "" : matches.isEmpty ? model.text("无结果", "No results") : "\(match + 1)/\(matches.count)").font(.caption).fixedSize().accessibilityIdentifier("preview-search-count")
            Button { match = codeMatchIndex(current: match, delta: -1, count: matches.count) } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty).accessibilityLabel(model.text("上一个", "Previous match")).accessibilityIdentifier("preview-search-previous")
            Button { match = codeMatchIndex(current: match, delta: 1, count: matches.count) } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty).accessibilityLabel(model.text("下一个", "Next match")).accessibilityIdentifier("preview-search-next")
            Button { searchVisible = false; query = "" } label: { Image(systemName: "xmark") }.accessibilityLabel(model.text("关闭查找", "Close search")).accessibilityIdentifier("preview-search-close")
        }.padding(12).background(Palette.panel)
    }
    @ViewBuilder private func documentView(fullscreen: Bool) -> some View {
        if let document {
            if document.language.mode == .markdown && rendered {
                ScrollView { MarkdownContent(blocks: blocks, connectionTarget: connectionTarget, directory: parentRemotePath(entry.path), fontSize: previewFontSize).padding(16).frame(maxWidth: 840) }.frame(maxWidth: .infinity).accessibilityIdentifier(fullscreen ? "file-markdown-fullscreen" : "file-markdown-preview")
            } else {
                CodeTextView(document: document, fontName: model.settings.font, fontSize: previewFontSize, wrap: model.settings.codeWrap, query: query, match: match, matches: matches, identifier: fullscreen ? "file-code-fullscreen" : "file-code-preview").id(reloadID)
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
struct CodeTextView: UIViewRepresentable {
    let document: CodeDocument
    let fontName: String
    let fontSize: Double
    let wrap: Bool
    let query: String
    let match: Int
    let matches: [CodeMatch]
    let identifier: String
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.accessibilityIdentifier = identifier
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let key = "\(document.lineCount)-\(document.maxColumns)-\(fontName)-\(fontSize)-\(wrap)-\(query)-\(scheme)"
        if context.coordinator.key != key || context.coordinator.sourceMatches != matches {
            context.coordinator.key = key
            context.coordinator.sourceMatches = matches
            let font = FontCatalog.shared.font(selection: fontName, size: fontSize)
            let output = NSMutableAttributedString()
            let digits = String(document.lineCount).count
            var rowOffsets: [Int] = []
            for line in document.lines {
                let number = String(repeating: " ", count: max(0, digits - String(line.number).count)) + "\(line.number)  "
                output.append(NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
                let offset = output.length
                rowOffsets.append(offset)
                output.append(NSAttributedString(string: line.text + "\n", attributes: [.font: font, .foregroundColor: UIColor.label]))
                for index in stride(from: 0, to: line.spans.count - 2, by: 3) {
                    let start = line.spans[index], end = line.spans[index + 1]
                    guard start >= 0, end <= line.text.utf16.count, end > start else { continue }
                    output.addAttribute(.foregroundColor, value: tokenColor(TokenType(rawValue: line.spans[index + 2])), range: NSRange(location: offset + start, length: end - start))
                }
            }
            context.coordinator.matches = []
            for found in matches where rowOffsets.indices.contains(found.row) {
                let range = NSRange(location: rowOffsets[found.row] + found.start, length: found.end - found.start)
                context.coordinator.matches.append(range)
                output.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.25), range: range)
            }
            view.attributedText = output
            view.textContainer.widthTracksTextView = wrap
            view.textContainer.size = CGSize(width: wrap ? max(1, view.bounds.width - 20) : max(1000, CGFloat(document.maxColumns + digits + 4) * font.pointSize * 0.65), height: .greatestFiniteMagnitude)
        }
        if context.coordinator.lastMatch != match || context.coordinator.lastQuery != query {
            context.coordinator.lastMatch = match; context.coordinator.lastQuery = query
            if !context.coordinator.matches.isEmpty { let range = context.coordinator.matches[match % context.coordinator.matches.count]; view.selectedRange = range; view.scrollRangeToVisible(range) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var key = ""; var sourceMatches: [CodeMatch] = []; var matches: [NSRange] = []; var lastMatch = -1; var lastQuery = "" }
    private func tokenColor(_ token: TokenType?) -> UIColor {
        switch token {
        case .keyword, .constant: return UIColor.systemPurple
        case .string, .inserted: return UIColor.systemGreen
        case .comment: return UIColor.secondaryLabel
        case .number, .attribute: return UIColor.systemOrange
        case .function, .type, .heading: return UIColor.systemBlue
        case .error, .deleted: return UIColor.systemRed
        default: return UIColor.label
        }
    }
}
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let view = UIImageView(image: image); view.contentMode = .scaleAspectFit; view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view); context.coordinator.image = view
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.image?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate { weak var image: UIImageView?; func viewForZooming(in scrollView: UIScrollView) -> UIView? { image } }
}
struct MarkdownContent: View {
    let blocks: [MdBlock]
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    var fontSize: Double = 13
    var body: some View { VStack(alignment: .leading, spacing: 14) { ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) } }.font(.system(size: fontSize)).frame(maxWidth: .infinity, alignment: .leading) }
    private func blockView(_ block: MdBlock) -> AnyView {
        switch block {
        case .heading(let level, let text): return AnyView(inline(text).font(.system(size: fontSize * (level == 1 ? 1.7 : level == 2 ? 1.4 : 1.15), weight: .semibold)).padding(.top, 8))
        case .paragraph(let text): return AnyView(inline(text).textSelection(.enabled))
        case .code(_, let text): return AnyView(ScrollView(.horizontal) { Text(text).font(.system(size: fontSize, design: .monospaced)).textSelection(.enabled).padding(12) }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)))
        case .quote(let blocks): return AnyView(HStack(spacing: 12) { Rectangle().fill(Palette.accent).frame(width: 3); MarkdownContent(blocks: blocks, connectionTarget: connectionTarget, directory: directory, fontSize: fontSize) }.fixedSize(horizontal: false, vertical: true).padding(.leading, 8))
        case .listItem(let depth, let marker, let checked, let text): return AnyView(HStack(alignment: .top, spacing: 8) { Text(checked.map { $0 ? "☑" : "☐" } ?? marker); inline(text) }.padding(.leading, CGFloat(depth) * 16))
        case .table(let header, _, let rows): return AnyView(ScrollView(.horizontal) { Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) { GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, text in inline(text).bold() } }; Divider(); ForEach(Array(rows.enumerated()), id: \.offset) { _, row in GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, text in inline(text) } } } }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12)) })
        case .image(let alt, let path): return AnyView(RemoteMarkdownImage(connectionTarget: connectionTarget, directory: directory, path: path, alt: alt))
        case .rule: return AnyView(Divider())
        }
    }
    private func inline(_ value: MdText) -> Text {
        let result = NSMutableAttributedString(string: value.text)
        for span in value.spans {
            guard span.start >= 0, span.end <= result.length, span.end > span.start else { continue }
            let range = NSRange(location: span.start, length: span.end - span.start)
            switch span.style {
            case .bold: result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: range)
            case .italic: result.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: fontSize), range: range)
            case .strike: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code: result.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), range: range)
            case .link, .image:
                result.addAttribute(.foregroundColor, value: UIColor(Palette.accent), range: range)
                if let link = span.url, let url = markdownExternalURL(link) {
                    result.addAttribute(.link, value: url, range: range)
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
        }
        return Text(AttributedString(result))
    }
}
private struct RemoteMarkdownImage: View {
    @EnvironmentObject var model: AppModel
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    let path: String
    let alt: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(alt)
            } else if let destination = markdownExternalURL(path) {
                Link(destination: destination) { placeholder }
                    .buttonStyle(.plain).accessibilityAddTraits(.isLink)
            } else {
                placeholder
            }
        }.task(id: path) {
            image = nil
            // Remote documents never trigger web image requests; relative files use this SSH connection.
            guard let resolved = markdownRemoteImagePath(directory: directory, source: path) else { return }
            let cancellation = TransferCancellation()
            await withTaskCancellationHandler(operation: {
                do {
                    let ssh = try await model.connection(for: connectionTarget)
                    try Task.checkCancellation()
                    let data = try await performInBackground { try ssh.readFile(resolved, maxBytes: imagePreviewBytes, cancellation: cancellation) }
                    guard !data.truncated else { return }
                    let decoded = try await performInBackground { decodePreviewImage(data.data) }
                    try Task.checkCancellation()
                    try model.validate(connectionTarget)
                    image = decoded?.image
                } catch { }
            }, onCancel: { cancellation.cancel() })
        }
    }
    private var placeholder: some View {
        Label(alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(path.split(separator: "/").last ?? "") : alt, systemImage: "photo")
            .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
