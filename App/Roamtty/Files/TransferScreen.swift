import SwiftUI
import UIKit

struct TransferScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var transfers: FileTransferModel
    @State private var share: SharedArtifact?
    @State private var export: SharedArtifact?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if transfers.jobs.isEmpty { EmptyMessage(icon: "arrow.up.arrow.down", title: model.text("暂无传输", "No transfers"), message: model.text("上传和下载的进度将显示在这里。", "Uploads and downloads appear here.")) }
                    ForEach(transfers.jobs) { job in
                        Panel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Image(systemName: job.uploading ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(Palette.accent); Text(job.name).font(.headline).lineLimit(1); Spacer(); if job.state == .running { Button(model.text("取消", "Cancel")) { transfers.cancel(job) } } }
                                Text(job.remotePath).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2).textSelection(.enabled)
                                if job.state == .running { if let fraction = job.fraction { ProgressView(value: fraction) } else { ProgressView() } }
                                HStack { Text(status(job)).accessibilityIdentifier("transfer-status-\(job.uploading ? "upload" : "download")-\(job.name)"); Spacer(); Text(formattedBytes(job.bytes)); if let total = job.total { Text("/ \(formattedBytes(total))") }; if job.state == .running { Text(job.speed) } }.font(.caption).foregroundStyle(job.state == .failed ? Palette.danger : Palette.secondary)
                                if let error = job.message { Text(error).font(.footnote).foregroundStyle(Palette.danger).textSelection(.enabled) }
                                if job.uploading && job.state == .complete {
                                    if job.pendingInsertion != nil { Text(model.text("路径尚未插入。请重试插入或复制远程路径。", "The path was not inserted. Retry Insert or copy the remote path.")).font(.footnote).foregroundStyle(Palette.warning) }
                                    HStack {
                                        Button(model.text("复制路径", "Copy path")) { UIPasteboard.general.string = job.remotePath }.accessibilityIdentifier("transfer-copy-path-\(job.name)")
                                        Spacer()
                                        if job.pendingInsertion != nil { Button(model.text("插入终端", "Insert in terminal")) { transfers.insertPath(job.id, model: model) }.disabled(!transfers.canInsertPath(job, model: model)).accessibilityIdentifier("transfer-insert-path-\(job.name)") }
                                    }.font(.subheadline)
                                }
                                if let url = job.localURL {
                                    HStack { Button(model.text("分享", "Share")) { share = SharedArtifact(url: url) }.accessibilityIdentifier("transfer-share-\(job.name)"); Spacer(); Button(model.text("存储到文件", "Save to Files")) { export = SharedArtifact(url: url) } }.font(.subheadline)
                                }
                            }.padding(16)
                        }
                    }
                }.padding(16)
            }.pageBackground().navigationTitle(model.text("传输", "Transfers")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model.text("清除已完成", "Clear finished")) { transfers.clearFinished() } }
                    ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("transfer-done") }
                }
        }.modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }.sheet(item: $share) { ShareActivity(items: [$0.url]) }.sheet(item: $export) { ExportDocuments(urls: [$0.url]) }
    }
    private func status(_ job: TransferJob) -> String {
        switch job.state { case .running: return job.uploading ? model.text("上传中", "Uploading") : model.text("下载中", "Downloading"); case .complete: return model.text("已完成", "Completed"); case .failed: return model.text("失败", "Failed"); case .cancelled: return model.text("已取消", "Cancelled") }
    }
}
struct SharedArtifact: Identifiable { let id = UUID(); let url: URL }
struct ShareActivity: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct ExportDocuments: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: urls, asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
