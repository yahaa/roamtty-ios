// Behavioral port of Roamtty Android's HostPlugins helpers.
import Foundation

public enum HostPlugin: String, Codable, CaseIterable, Sendable { case tmux, mosh }

public enum HostPluginProbe {
    public static let tmuxMarker = "__ITERMUX_TMUX__="
    public static let moshMarker = "__ITERMUX_MOSH__="
    public static var script: String {
        RemoteCommands.pathSetup + "\nm=$(command -v mosh-server 2>/dev/null)\nprintf '\(tmuxMarker)%s\\n' \"$(command -v tmux 2>/dev/null)\"\nprintf '\(moshMarker)%s\\n' \"$m\"\nexit 0"
    }
    public static func parse(_ output: String?) -> Set<HostPlugin>? {
        guard let lines = output?.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }),
              let tmux = lines.first(where: { $0.hasPrefix(tmuxMarker) }), let mosh = lines.first(where: { $0.hasPrefix(moshMarker) }) else { return nil }
        var result = Set<HostPlugin>()
        if !tmux.dropFirst(tmuxMarker.count).trimmingCharacters(in: .whitespaces).isEmpty { result.insert(.tmux) }
        if !mosh.dropFirst(moshMarker.count).trimmingCharacters(in: .whitespaces).isEmpty { result.insert(.mosh) }
        return result
    }
}

public enum HostPluginInstaller {
    public static let sudoFailed = "__ITERMUX_SUDO_FAILED__", noPrivilege = "__ITERMUX_NO_PRIVILEGE__", noPackageManager = "__ITERMUX_NO_PACKAGE_MANAGER__", done = "__ITERMUX_INSTALL_DONE__"
    public enum Result: Equatable, Sendable { case installed, sudoPassword, noPrivilege, noPackageManager, failed }
    /// Send this script on the stdin of /bin/sh -s; passwords must not enter the remote process list.
    public static func script(plugin: HostPlugin, sudoPassword: String?) -> String {
        let password = sudoPassword.flatMap { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") ? nil : $0 } ?? ""
        let pkg = plugin.rawValue
        let epel = plugin == .mosh ? " || { run \"$1\" install -y epel-release && run \"$1\" install -y \(pkg); }" : ""
        return #"""
        exec 2>&1
        \#(RemoteCommands.pathSetup)
        PW=\#(RemoteCommands.shellQuote(password))
        need_root() {
          if [ "$(id -u)" = 0 ]; then run() { "$@"; }
          elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then run() { sudo -n "$@"; }
          elif command -v sudo >/dev/null 2>&1 && [ -n "$PW" ]; then
            printf '%s\n' "$PW" | sudo -S -k -p '' true >/dev/null 2>&1 || { echo \#(sudoFailed); exit 3; }
            run() { printf '%s\n' "$PW" | sudo -S -k -p '' "$@"; }
          elif command -v sudo >/dev/null 2>&1; then echo \#(sudoFailed); exit 3
          else echo \#(noPrivilege); exit 5
          fi
        }
        has() { command -v "$1" >/dev/null 2>&1; }
        none() { echo \#(noPackageManager); exit 4; }
        dnf_like() { need_root; run "$1" install -y \#(pkg)\#(epel); }
        case "$(uname -s 2>/dev/null)" in
          Darwin)
            if has brew; then brew install \#(pkg)
            elif has port; then need_root; run port -N install \#(pkg)
            else none; fi ;;
          MSYS*|MINGW*)
            if has pacman; then pacman -Sy --noconfirm --needed \#(pkg); else none; fi ;;
          CYGWIN*)
            if has apt-cyg; then apt-cyg install \#(pkg); else none; fi ;;
          *)
            if [ -n "$TERMUX_VERSION" ] && has pkg; then pkg install -y \#(pkg)
            elif [ "$(id -u)" != 0 ] && ! has sudo && has brew; then brew install \#(pkg)
            elif has apt-get; then
              need_root
              run env DEBIAN_FRONTEND=noninteractive apt-get update -q && run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \#(pkg)
            elif has dnf; then dnf_like dnf
            elif has yum; then dnf_like yum
            elif has pacman; then need_root; run pacman -Sy --noconfirm --needed \#(pkg)
            elif has zypper; then need_root; run zypper --non-interactive install \#(pkg)
            elif has apk; then need_root; run apk add \#(pkg)
            elif has pkg; then need_root; run pkg install -y \#(pkg)
            elif has brew; then brew install \#(pkg)
            else none; fi ;;
        esac
        status=$?
        [ $status = 0 ] && echo \#(done)
        exit $status
        """#
    }
    public static func classify(exitStatus: Int?, output: String) -> Result {
        if exitStatus == 0 && output.contains(done) { return .installed }
        if output.contains(sudoFailed) { return .sudoPassword }
        if output.contains(noPrivilege) { return .noPrivilege }
        if output.contains(noPackageManager) { return .noPackageManager }
        return .failed
    }
    public static func displayLine(_ line: String) -> String? { line.hasPrefix("__ITERMUX_") ? nil : line }
}
