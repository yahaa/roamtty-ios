import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The desktop page's 操作 panel: leaving, files, the clipboard, how the pointer works, sound, the figures,
/// frame rate, quality, the display and disconnecting. The page places it and owns what it changes.
struct DesktopOperationsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    @ObservedObject var statsBox: DesktopStatsBox
    @Binding var pointerMode: PointerMode
    @Binding var virtualMouse: Bool
    @Binding var showDisconnect: Bool
    let showStats: Bool
    let setShowStats: (Bool) -> Void
    let dismiss: () -> Void

    private var page: DesktopPageModel { controller.page }
    private var ink: Color { DesktopTheme.ink }
    private var inkDim: Color { DesktopTheme.inkDim }
    private var accent: Color { DesktopTheme.accent }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    navigation
                    clipboard
                    pointer
                    toggles
                    statsToggle
                    frameRate
                    quality
                    displays
                    toggleRow(model.text("断开后锁定电脑", "Lock after disconnect"), model.text("断开连接时锁屏，返回不算", "Lock on disconnect, not when going back"),
                              value: Binding(get: { controller.lockOnClose }, set: { controller.setLockOnClose($0) }))
                    disconnect
                }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }.accessibilityIdentifier("desktop-operations-scroll")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text("操作", "Operations")).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                Text(controller.host.name).font(.system(size: 12)).foregroundStyle(inkDim).lineLimit(1)
            }
            Spacer()
            Button(action: dismiss) {
                AppIcon("ic_close", size: 22).foregroundStyle(ink).frame(width: 48, height: 48)
            }.buttonStyle(.plain).accessibilityLabel(model.text("关闭", "Close"))
                .accessibilityIdentifier("desktop-op-close")
        }.padding(.leading, 16).padding(.trailing, 4).padding(.top, 4)
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            panelButton("ic_exit", model.text("返回", "Back"), caption: model.text("连接保持", "Keep connected")) {
                dismiss(); leaveKeepingLink()
            }.accessibilityIdentifier("desktop-op-exit")
            panelButton("ic_folder", model.text("文件", "Files"), caption: model.text("上传和下载", "Upload and download")) {
                dismiss(); model.path.append(.files(controller.host.id))
            }
        }
    }

    private var clipboard: some View {
        section(model.text("剪贴板", "Clipboard")) {
            HStack(spacing: 8) {
                panelButton("ic_upload", model.text("发送手机剪贴板", "Send phone clipboard")) { sendClipboard() }
                panelButton("ic_download", model.text("获取远程剪贴板", "Get remote clipboard")) {
                    controller.send(DesktopProtocol.req(DesktopProtocol.REQ_CLIP_GET))
                }
            }
            if let note = controller.clipNote ?? page.clipNote { Text(note).font(.system(size: 12)).foregroundStyle(inkDim) }
        }
    }

    private var pointer: some View {
        section(model.text("操作方式", "Pointer mode")) {
            HStack(spacing: 8) {
                choice(model.text("屏幕触控", "Touch"), selected: pointerMode == .touch) { setPointerMode(.touch) }
                choice(model.text("鼠标指针", "Trackpad"), selected: pointerMode == .mouse) { setPointerMode(.mouse) }
            }
        }
    }

    @ViewBuilder
    private var toggles: some View {
        toggleRow(model.text("声音", "Sound"), controller.audioAvailable == false
                  ? model.text("这台电脑暂时无法传回声音", "This computer cannot send its sound right now")
                  : model.text("在手机上播放电脑的声音", "Play the computer's sound on the phone"),
                  value: Binding(get: { controller.audioOn }, set: { controller.setAudio($0) }))
            .accessibilityIdentifier("desktop-audio")
        toggleRow(model.text("仅观看", "View only"), model.text("不向电脑发送任何操作", "Do not send input to the computer"),
                  value: Binding(get: { controller.viewOnly }, set: { controller.setViewOnly($0) }))
        toggleRow(model.text("虚拟鼠标", "Virtual mouse"), model.text("悬浮的左键、右键和滚轮", "Floating left, right buttons and scroll wheel"),
                  value: Binding(get: { virtualMouse }, set: {
                      virtualMouse = $0
                      page.virtualMouse = $0
                  }))
    }

    private var statsToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            toggleRow(model.text("显示网络状态", "Show network stats"),
                      model.text("画面上显示延迟、帧率和码率，长按可拖动", "Latency, frame rate and bitrate; long press to move"),
                      value: Binding(get: { showStats }, set: { setShowStats($0) }))
            if statsBox.moved {
                Button(model.text("恢复默认位置（左上角）", "Back to the top left")) {
                    statsBox.reset()
                    model.settings.desktopStatsX = 0; model.settings.desktopStatsY = 0
                    setShowStats(true)
                }
                .font(.system(size: 13)).foregroundStyle(accent).padding(.vertical, 6)
                .accessibilityIdentifier("desktop-stats-reset")
            }
        }
    }

    private var frameRate: some View {
        section(model.text("帧率", "Frame rate")) {
            HStack(spacing: 8) {
                ForEach(DesktopPreferences.fpsOptions.filter { $0 <= max(60, UIScreen.main.maximumFramesPerSecond) }, id: \.self) { fps in
                    choice("\(fps)", selected: controller.fps == fps) { controller.setFps(fps) }
                }
            }
        }
    }

    private var quality: some View {
        section(model.text("画质", "Quality")) {
            HStack(spacing: 8) {
                ForEach(DesktopPreferences.qualities, id: \.self) { quality in
                    choice(page.qualityLabel(quality), selected: controller.quality == quality) { controller.setQuality(quality) }
                }
            }
        }
    }

    @ViewBuilder
    private var displays: some View {
        if let displays = controller.hello?.displays, displays.count > 1 {
            section(model.text("显示器", "Display")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displays, id: \.id) { d in
                            choice(d.name.isEmpty ? model.text("显示器 \(d.id)", "Display \(d.id)") : d.name, selected: controller.displayIndex == d.id) { controller.setDisplay(d.id) }
                        }
                    }
                }
            }
        }
    }

    private var disconnect: some View {
        Button(role: .destructive) { showDisconnect = true } label: {
            HStack(spacing: 8) {
                AppIcon("ic_power", size: 20)
                Text(model.text("断开连接", "Disconnect")).font(.system(size: 15, weight: .medium))
            }.foregroundStyle(Palette.danger).frame(maxWidth: .infinity).padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.danger.opacity(0.6), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: Controls

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(inkDim)
            content()
        }
    }

    /// Sized to match the toggle rows below: 15pt titles, 26pt icons, at least 72pt tall (84 with a caption).
    private func panelButton(_ icon: String, _ title: String, caption: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AppIcon(icon, size: 26)
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(2).minimumScaleFactor(0.85)
                if let caption { Text(caption).font(.system(size: 12)).foregroundStyle(inkDim).lineLimit(1) }
            }.foregroundStyle(ink).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: caption == nil ? 72 : 84).padding(.horizontal, 8).padding(.vertical, 12)
                .background(DesktopTheme.control, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(selected ? accent : ink).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? accent.opacity(0.22) : DesktopTheme.control, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleRow(_ title: String, _ subtitle: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(ink)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(inkDim)
            }
        }.tint(accent)
    }

    // MARK: Actions

    private func setPointerMode(_ mode: PointerMode) {
        if mode != pointerMode { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        pointerMode = mode
        controller.setPointerMode(mode)
    }

    private func sendClipboard() {
        let text = UIPasteboard.general.string ?? ""
        controller.clipNote = page.clipSentNote(empty: text.isEmpty)
        if !text.isEmpty { controller.send(DesktopProtocol.clipSet(text)) }
    }

    /// 返回: the page goes, the desktop stays connected for the keep-alive time.
    private func leaveKeepingLink() {
        if model.path.last == .desktop(controller.host.id) { _ = model.path.popLast() } else { model.path.removeAll { $0 == .desktop(controller.host.id) } }
    }
}
