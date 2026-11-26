import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The host's desktop from the terminal: the dock's desktop key, and the small window over the terminal with
/// its own focus and keyboard.
extension TerminalScreen {
    /// Android: only when desktopSupported && probe == YES.
    var showDesktopDock: Bool {
        guard let host = model.host(runtime.record.hostID), model.desktopSupported(host) else { return false }
        return DesktopProbe.decode(host.desktop) == .yes
    }
    /// A tap shows the desktop small over the terminal (or closes it), tinted while it shows; a long press opens the
    /// desktop page.
    var desktopDockButton: some View {
        let shown = pipDesktop != nil
        let tap = {
            toolbox.touchDock(at: now)
            runtime.controlArmed = false; runtime.shiftArmed = false
            if let host = model.host(runtime.record.hostID) { model.toggleDesktopPip(host) }
            collapseIfFloating()
        }
        let full = {
            toolbox.touchDock(at: now)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            openDesktopPage()
            collapseIfFloating()
        }
        return AppIcon("ic_desktop").frame(width: 48, height: 48).contentShape(Rectangle())
            .foregroundStyle(shown ? Palette.accent : Palette.foreground)
            .onTapGesture(perform: tap)
            .onLongPressGesture(minimumDuration: 0.5, perform: full)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(shown ? model.text("关闭桌面小窗", "Close the desktop window") : model.text("小窗查看桌面", "Show the desktop in a window"))
            .accessibilityValue(shown ? model.text("已打开", "Open") : "")
            .accessibilityAction { tap() }
            .accessibilityAction(named: model.text("打开全屏桌面", "Open the desktop full screen")) { full() }
            .accessibilityIdentifier("terminal-desktop")
    }
    /// The desktop page takes the screen; going back comes to this terminal, its desktop small again if it was.
    func openDesktopPage() {
        unfocusPip()
        runtime.controlArmed = false; runtime.shiftArmed = false
        hideKeyboard()
        _ = runtime.terminalView.resignFirstResponder()
        if let host = model.host(runtime.record.hostID) { model.openDesktop(host) }
    }

    // MARK: Desktop window

    /// The host's desktop in the small window, while this terminal is the page on top (the desktop page takes the
    /// picture otherwise).
    var pipDesktop: DesktopController? {
        guard showDesktopDock, model.path.last == .terminal(runtime.record.id) else { return nil }
        return model.pipDesktop(for: runtime.record.hostID)
    }
    func focusPip() {
        runtime.controlArmed = false; runtime.shiftArmed = false
        toolbox.closeRing()
        hideKeyboard()
        _ = runtime.terminalView.resignFirstResponder()
        resetPipKeyboard()
        pipFocused = true
    }
    func unfocusPip() {
        guard pipFocused || pipKeyboard else { return }
        resetPipKeyboard()
        pipFocused = false
    }
    func setPipKeyboard(_ open: Bool, _ desktop: DesktopController) {
        if !open { resetPipKeyboard(desktop); return }
        pipKeyboard = true; pipShortcutBar = true; pipKeyboardPage = .ime; desktop.page.keyboardPage = .ime; pipIMEFocused = true
    }
    func resetPipKeyboard(_ desktop: DesktopController? = nil) {
        pipKeyboard = false; pipIMEFocused = false; pipComposing = ""; pipKeyboardPage = .ime
        if let page = (desktop ?? pipDesktop)?.page {
            page.keyboardPage = .ime
            for hid in [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT, HidUsage.LEFT_GUI, HidUsage.LEFT_SHIFT] where page.latch.state(hid) != .off { page.tapModifier(hid) }
        }
        pipLatchRevision += 1
    }
    @ViewBuilder
    func desktopWindow(_ desktop: DesktopController, page: GeometryProxy, landscape: Bool, reserved: Bool, twoColumns: Bool) -> some View {
        // The page runs under the status bar and the camera housing, so its own proxy reports no insets.
        let insets = safeAreaInsets(for: page)
        let margin: CGFloat = 8
        // Anywhere it is dragged, clear of the status bar, the camera housing, a pinned dock and the home indicator.
        let dockWidth: CGFloat = reserved ? (twoColumns ? 96 : 48) : 0
        let room = CGRect(x: insets.leading + margin, y: insets.top + margin,
                          width: max(0, page.size.width - insets.leading - max(insets.trailing, dockWidth) - 2 * margin),
                          height: max(0, page.size.height - insets.top - (keyboardVisible ? 0 : insets.bottom) - 2 * margin))
        let key = runtime.record.hostID + ".terminal" + (landscape ? ".land" : "")
        PipDesktopWindow(controller: desktop, stateKey: key, defaultFraction: landscape ? 0.4 : 0.7, room: room,
                         reference: page.size.width,
                         focused: pipFocused, keyboardOpen: pipKeyboard,
                         onTap: { if !pipFocused { focusPip() } },
                         onClose: { unfocusPip(); model.pipDesktopHostID = nil },
                         onKeyboard: { setPipKeyboard(!pipKeyboard, desktop) },
                         onFull: openDesktopPage)
            .id(key)
        // Typing on the desktop, as its page's 键盘: the input method and the shortcut bar, over the terminal.
        if pipFocused && pipKeyboard {
            DesktopKeyboardPanel(controller: desktop, composingText: $pipComposing, shortcutBar: $pipShortcutBar,
                                 latchRevision: $pipLatchRevision, keyboardPage: $pipKeyboardPage, imeFocused: $pipIMEFocused,
                                 alwaysBar: true) { setPipKeyboard(false, desktop) }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
                .padding(.bottom, keyboardVisible ? 0 : insets.bottom)
                .frame(width: page.size.width, height: page.size.height, alignment: .bottom)
        }
    }
}
