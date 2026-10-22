import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore

struct SettingsScreen: View {
    private enum ImportKind { case font, downloadFolder }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var fonts = FontCatalog.shared
    @State private var importKind = ImportKind.font
    @State private var showImporter = false
    @State private var fontError: String?
    @State private var downloadFolderError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Panel(title: model.text("外观", "Appearance")) {
                        themeRow(.system, model.text("跟随系统", "System")).panelDivider()
                        themeRow(.dark, model.text("深色", "Dark")).panelDivider()
                        themeRow(.light, model.text("浅色", "Light"))
                    }
                    Panel(title: model.text("语言", "Language")) {
                        checkRow("简体中文", selected: !model.english, id: "language-zh") { model.settings.language = "zh-Hans"; model.saveSettings() }.panelDivider()
                        checkRow("English", selected: model.english, id: "language-en") { model.settings.language = "en"; model.saveSettings() }
                    }
                    Panel(title: model.text("终端", "Terminal")) {
                        Picker(model.text("字体", "Font"), selection: $model.settings.font) {
                            Text(model.text("系统等宽", "System monospace")).tag(TerminalFontSelection.system).accessibilityIdentifier("settings-font-system")
                            ForEach(TerminalFontSelection.bundled, id: \.self) { name in Text(name.replacingOccurrences(of: "-Regular", with: "")).tag(name) }
                            if let custom = fonts.custom { Text(custom.displayName).tag(TerminalFontSelection.custom).accessibilityIdentifier("settings-font-custom") }
                        }.padding(16).panelDivider().accessibilityIdentifier("settings-font").accessibilityValue(fonts.valueLabel(model.settings.font, english: model.english))
                        Button { fontError = nil; importKind = .font; showImporter = true } label: { InfoRow(title: model.text("导入字体", "Import font"), value: "TTF / OTF · ≤16 MiB", icon: "textformat") }.panelDivider().accessibilityIdentifier("settings-font-import")
                        if fonts.custom != nil {
                            Button(model.text("清除自定义字体", "Clear custom font"), role: .destructive) {
                                do { model.settings.font = try fonts.clear(selection: model.settings.font); fontError = nil; model.saveSettings() }
                                catch { fontError = error.localizedDescription }
                            }.padding(16).panelDivider().accessibilityIdentifier("settings-font-clear-custom")
                        }
                        if let fontError { Text(fontError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-font-error") }
                        VStack(spacing: 10) {
                            let preview = fonts.font(selection: model.settings.font, size: model.settings.fontSize)
                            HStack { Text(model.text("字号", "Font size")); Spacer(); Text("\(Int(model.settings.fontSize)) pt").foregroundStyle(Palette.secondary).accessibilityIdentifier("settings-font-size-value") }
                            Slider(value: $model.settings.fontSize, in: 8...28, step: 1).accessibilityLabel(model.text("字号", "Font size")).accessibilityIdentifier("settings-font-size")
                            Text("❯ ssh developer@roamtty\n你好，世界  echo 'Hello, world'\nλ → 0123456789 {} []").font(Font(preview)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("settings-font-preview").accessibilityValue(preview.fontName)
                        }.padding(16).panelDivider()
                        Toggle(model.text("固定工具箱", "Keep toolbox open"), isOn: $model.settings.toolboxPinned).padding(16).accessibilityIdentifier("settings-toolbox-pinned")
                    }

                    Panel(title: model.text("实验功能", "Experimental")) {
                        Toggle(model.text("远程桌面", "Remote desktop"), isOn: $model.settings.desktopEnabled)
                            .padding(16).panelDivider()
                            .accessibilityIdentifier("settings-desktop-enabled")
                        Text(model.text("在会话卡片和主机页显示桌面入口；默认关闭。", "Show desktop entry points on session cards and the host page; off by default."))
                            .font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                        if model.settings.desktopEnabled {
                            Picker(model.text("离开后保持", "Keep link after leaving"), selection: $model.settings.desktopKeepAliveMinutes) {
                                Text(model.text("5 分钟", "5 minutes")).tag(5)
                                Text(model.text("10 分钟", "10 minutes")).tag(10)
                                Text(model.text("30 分钟", "30 minutes")).tag(30)
                            }.padding(16).panelDivider().accessibilityIdentifier("settings-desktop-keepalive")
                            Toggle(model.text("显示网络状态", "Show network stats"), isOn: $model.settings.desktopShowStats)
                                .padding(16).accessibilityIdentifier("settings-desktop-stats")
                        }
                    }
                    Panel(title: model.text("文件", "Files")) {
                        Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).padding(16).panelDivider().accessibilityIdentifier("settings-hidden-files")
                        Button { downloadFolderError = nil; importKind = .downloadFolder; showImporter = true } label: { InfoRow(title: model.text("下载目录", "Download folder"), value: model.settings.downloadBookmark == nil ? "Roamtty/Downloads" : model.text("自定义目录", "Custom folder"), icon: "folder") }.panelDivider().accessibilityIdentifier("settings-download-folder")
                        if let downloadFolderError { Text(downloadFolderError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-download-folder-error") }
                        if model.settings.downloadBookmark != nil { Button(model.text("恢复默认下载目录", "Use default download folder")) { model.settings.downloadBookmark = nil; downloadFolderError = nil; model.saveSettings() }.padding(16) }
                    }
                }.padding(16).frame(maxWidth: 720)
            }.accessibilityIdentifier("settings-scroll").frame(maxWidth: .infinity).pageBackground().navigationTitle(model.text("设置", "Settings"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("settings-done") } }
        }
        .onChange(of: model.settings) { _ in model.saveSettings() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind == .downloadFolder ? [.folder] : [UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]) { result in
            // Keep the purpose separate from isPresented: SwiftUI clears that
            // binding before delivering the selected document's completion.
            do {
                let url = try result.get()
                switch importKind {
                case .font:
                    model.settings.font = try fonts.install(url); fontError = nil
                case .downloadFolder:
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    model.settings.downloadBookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    downloadFolderError = nil
                }
                model.saveSettings()
            } catch let error as CocoaError where error.code == .userCancelled {
                // Dismissing the native picker leaves the existing selection intact.
            } catch {
                if importKind == .font { fontError = error.localizedDescription }
                else { downloadFolderError = error.localizedDescription }
            }
        }
    }
    private func themeRow(_ theme: AppTheme, _ title: String) -> some View {
        checkRow(title, selected: model.settings.theme == theme, id: "theme-\(theme.rawValue)") { model.settings.theme = theme; model.saveSettings() }
    }
    /// Android `CheckRow`: a single-choice row with a trailing check on the selection.
    private func checkRow(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Palette.foreground)
                Spacer()
                AppIcon("ic_check", size: 20).foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
            }.font(.body).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
