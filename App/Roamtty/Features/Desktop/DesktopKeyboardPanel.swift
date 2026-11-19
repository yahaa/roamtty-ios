import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

/// The desktop's 键盘 (Android `KeyboardPanel`): the input method, the shortcut bar above it and the ⋯ page of PC
/// keys. The desktop page and the small window over the terminal both use it; the state lives with whoever shows it.
/// `alwaysBar` (the small window): the shortcut bar shows at once and its ▾ closes the keyboard (`onDismiss`).
struct DesktopKeyboardPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    @Binding var composingText: String
    @Binding var shortcutBar: Bool
    @Binding var latchRevision: Int
    @Binding var keyboardPage: DesktopKeyboardPage
    @Binding var imeFocused: Bool
    var alwaysBar = false
    var onDismiss: () -> Void

    private var panelColor: Color { DesktopTheme.panel }
    private var ink: Color { DesktopTheme.ink }
    private var accent: Color { DesktopTheme.accent }
    private var page: DesktopPageModel { controller.page }

    var body: some View {
        VStack(spacing: 0) {
            if !composingText.isEmpty && keyboardPage == .ime {
                HStack {
                    Text(composingText).font(.system(size: 14)).foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(panelColor, in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
                    Spacer()
                }.padding(.leading, 12).padding(.bottom, 6)
            }
            if !alwaysBar && !shortcutBar && keyboardPage == .ime {
                HStack {
                    Spacer()
                    Button { shortcutBar = true } label: {
                        HStack(spacing: 6) {
                            AppIcon("ic_keyboard", size: 16)
                            Text(model.text("快捷键 ▴", "Shortcuts ▴")).font(.system(size: 12))
                        }.foregroundStyle(ink).padding(.horizontal, 12).padding(.vertical, 6).background(panelColor, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("desktop-kb-toggle")
                    Button { onDismiss() } label: {
                        AppIcon("ic_close", size: 16).foregroundStyle(ink).frame(width: 36, height: 32)
                            .background(panelColor, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(model.text("关闭键盘", "Close keyboard"))
                }.padding(.trailing, 8).padding(.bottom, 6)
            } else {
                shortcutKeys
            }
            if keyboardPage == .more { pcKeysPage }
            DesktopIMEInput(focused: imeFocused, onText: { text in
                if case .frames(let frames) = page.commitIME(text, composing: false) { frames.forEach(controller.input) }
                latchRevision += 1
            }, onControl: { hid in sendKey(hid) }, onComposing: { composingText = $0 })
                .frame(height: 1).opacity(0.01).accessibilityIdentifier("desktop-ime-field")
        }
    }

    private var shortcutKeys: some View {
        _ = latchRevision
        return HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    barKey("Esc") { sendKey(HidUsage.ESCAPE) }.accessibilityIdentifier("desktop-sk-esc")
                    barKey("Tab") { sendKey(HidUsage.TAB) }
                    ForEach(DesktopPageModel.modifierKeys(os: controller.hello?.os ?? controller.host.system), id: \.hid) { key in
                        barKey(key.label, state: page.latch.state(key.hid), hold: { page.holdModifier(key.hid); latchRevision += 1 }) {
                            page.tapModifier(key.hid); latchRevision += 1
                        }
                    }
                    ForEach(Array(zip(["←", "↑", "↓", "→"], [HidUsage.LEFT, HidUsage.UP, HidUsage.DOWN, HidUsage.RIGHT])), id: \.1) { label, hid in
                        barKey(label, narrow: true) { sendKey(hid) }
                    }
                }
            }
            barKey(keyboardPage == .more ? "ABC" : "⋯", state: keyboardPage == .more ? .locked : .off) {
                keyboardPage = keyboardPage == .more ? .ime : .more
                page.keyboardPage = keyboardPage; imeFocused = keyboardPage == .ime
            }.accessibilityIdentifier("desktop-kb-more")
            if keyboardPage == .ime {
                // The small window: ▾ closes the keyboard, the same as its bar's keyboard button.
                barKey("▾", narrow: true) { if alwaysBar { onDismiss() } else { shortcutBar = false } }
                    .accessibilityIdentifier("desktop-kb-hide-bar")
                    .accessibilityLabel(alwaysBar ? model.text("关闭键盘", "Close keyboard") : "▾")
            }
            // iOS has no Android system Back key; the page keeps a dedicated dismissal affordance (the small window's
            // bar has its keyboard button for that).
            if !alwaysBar {
                barKey("×", narrow: true) { onDismiss() }.accessibilityLabel(model.text("关闭键盘", "Close keyboard"))
            }
        }.frame(height: 36).padding(6).background(panelColor)
    }

    private func barKey(_ title: String, state: ModifierLatch.State = .off, narrow: Bool = false,
                        hold: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Text(title).font(.system(size: 13, weight: state == .locked ? .semibold : .regular))
            .foregroundStyle(state == .locked ? panelColor : state == .once ? accent : ink)
            .padding(.horizontal, 10).frame(minWidth: narrow ? 32 : 42).frame(height: 36)
            .background(state == .locked ? accent : state == .once ? accent.opacity(0.25) : Color.white.opacity(26/255), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(state == .once ? accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture()).onEnded { value in
                switch value {
                case .first: hold?()
                case .second: action()
                }
            })
            .accessibilityAddTraits(.isButton).accessibilityAction { action() }
            .accessibilityValue(state == .locked ? model.text("已锁定", "Locked") : state == .once ? model.text("单次生效", "Once") : "")
    }

    private var pcKeysPage: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(DesktopPageModel.moreKeys(), id: \.hid) { key in
                    Button {
                        if key.hid == HidUsage.LEFT_SHIFT { page.tapModifier(key.hid); latchRevision += 1 } else { sendKey(key.hid) }
                    } label: {
                        Text(key.label).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(ink)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(key.hid == HidUsage.LEFT_SHIFT && page.latch.state(key.hid) != .off ? accent.opacity(0.4) : Color.white.opacity(31/255), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(DesktopPageModel.comboKeys(os: controller.hello?.os ?? controller.host.system), id: \.label) { key in
                    Button {
                        page.combo(key.keys).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }; latchRevision += 1
                    } label: {
                        Text(key.label).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(ink)
                            .frame(maxWidth: .infinity).frame(height: 42).background(Color.white.opacity(41/255), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 8).padding(.bottom, 10).background(panelColor)
    }

    private func sendKey(_ hid: Int) {
        page.pressKey(hid).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }
        latchRevision += 1
    }
}
