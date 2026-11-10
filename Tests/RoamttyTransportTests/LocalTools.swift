import Foundation

/// The programs on this machine that the live transport tests start: named by the environment, else looked for
/// where Linux and Homebrew install them, so a Mac with `brew install mosh tmux` runs these tests instead of skipping.
enum LocalTools {
    static var moshServer: String { path("mosh-server", variable: "ROAMTTY_MOSH_SERVER") }
    static var tmux: String { path("tmux", variable: "ROAMTTY_TMUX") }

    /// The first place `name` is executable; the first candidate when it is nowhere, so the caller's skip names it.
    private static func path(_ name: String, variable: String) -> String {
        if let chosen = ProcessInfo.processInfo.environment[variable] { return chosen }
        let candidates = ["/usr/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}
