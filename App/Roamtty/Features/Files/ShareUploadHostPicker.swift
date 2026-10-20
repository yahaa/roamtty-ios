import SwiftUI

/// Asks which saved host the files shared into the app go to; cancelling drops them.
struct ShareUploadHostPicker: View {
    @EnvironmentObject var model: AppModel
    let onPick: (Host) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section(model.text("选择上传主机", "Choose an upload host")) {
                    ForEach(model.hosts) { host in
                        Button(host.name) { onPick(host) }.accessibilityIdentifier("share-host-\(host.id)")
                    }
                }
            }.navigationTitle(model.text("共享文件", "Shared files"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { model.incomingFiles = [] } } }
        }
    }
}
