import SwiftUI
import UIKit
import RoamttyCore
import RoamttyTransport

struct MarkdownContent: View {
    let blocks: [MdBlock]
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    var fontSize: Double = 13
    let viewport: CGSize
    let coordinateSpace: String
    let imagesEnabled: Bool
    // Flatten quotes into rows so one long quote cannot eagerly instantiate all images.
    private struct Row { let block: MdBlock; let quoteDepth: Int }
    private func rows(_ blocks: [MdBlock], depth: Int = 0) -> [Row] {
        blocks.flatMap { block in
            if case .quote(let children) = block { return rows(children, depth: depth + 1) }
            return [Row(block: block, quoteDepth: depth)]
        }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows(blocks).enumerated()), id: \.offset) { _, row in
                blockView(row.block).padding(.leading, CGFloat(row.quoteDepth) * 23)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 20) {
                            ForEach(0..<row.quoteDepth, id: \.self) { _ in Rectangle().fill(Palette.accent).frame(width: 3) }
                        }.padding(.leading, 8)
                    }
            }
        }.font(.system(size: fontSize)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func blockView(_ block: MdBlock) -> AnyView {
        switch block {
        case .heading(let level, let text): return AnyView(inline(text).font(.system(size: fontSize * (level == 1 ? 1.7 : level == 2 ? 1.4 : 1.15), weight: .semibold)).padding(.top, 8))
        case .paragraph(let text): return AnyView(inline(text).textSelection(.enabled))
        case .code(_, let text): return AnyView(ScrollView(.horizontal) {
            Text(text).font(.system(size: fontSize, design: .monospaced)).textSelection(.enabled).padding(12)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)))
        case .quote: return AnyView(EmptyView()) // Flattened above.
        case .listItem(let depth, let marker, let checked, let text): return AnyView(HStack(alignment: .top, spacing: 8) {
            Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
            inline(text)
        }.padding(.leading, CGFloat(depth) * 16))
        case .table(let header, _, let rows): return AnyView(ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, text in inline(text).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, text in inline(text) } } }
            }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        })
        case .image(let alt, let path):
            return AnyView(RemoteMarkdownImage(connectionTarget: connectionTarget, directory: directory, path: path, alt: alt,
                                               viewport: viewport, coordinateSpace: coordinateSpace, enabled: imagesEnabled))
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
private struct MarkdownImageFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct RemoteMarkdownImage: View {
    @EnvironmentObject var model: AppModel
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    let path: String
    let alt: String
    let viewport: CGSize
    let coordinateSpace: String
    let enabled: Bool
    @StateObject private var demand = MarkdownImageDemand()
    @State private var frame: CGRect = .zero
    @State private var appeared = false
    private struct DemandKey: Equatable {
        let path: String?
        let generation: UUID
        let visible: Bool
    }
    private var demandKey: DemandKey {
        let generation: UUID
        switch connectionTarget {
        case .host(let id): generation = model.logins.hostGeneration(id)
        case .session(let id, _): generation = model.logins.ownerGeneration(id)
        }
        return DemandKey(path: markdownRemoteImagePath(directory: directory, source: path), generation: generation,
                         visible: appeared && enabled && !frame.isEmpty && frame.intersects(CGRect(origin: .zero, size: viewport)))
    }
    private var imageHeight: CGFloat? {
        guard let size = demand.pixelSize, size.width > 0 else { return nil }
        return min(480, max(1, frame.width) * size.height / size.width)
    }
    var body: some View {
        Group {
            if let display = demand.display {
                MarkdownImageView(display: display, label: alt)
                    .accessibilityLabel(alt).accessibilityAddTraits(.isImage)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let destination = markdownExternalURL(path) {
                Link(destination: destination) { placeholder }
                    .buttonStyle(.plain).accessibilityAddTraits(.isLink)
            } else {
                placeholder
            }
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: imageHeight)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: MarkdownImageFrameKey.self, value: geometry.frame(in: .named(coordinateSpace)))
            })
            .onPreferenceChange(MarkdownImageFrameKey.self) { frame = $0 }
            .onAppear { appeared = true }
            .onChange(of: demandKey) { _ in updateDemand() }
            .onDisappear { appeared = false; demand.stop() }
    }
    private func updateDemand() {
        let key = demandKey
        if key.visible, let path = key.path { demand.start(resolver: model, target: connectionTarget, path: path) } else { demand.stop() }
    }
    private var placeholder: some View {
        Label(alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(path.split(separator: "/").last ?? "") : alt, systemImage: "photo")
            .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
