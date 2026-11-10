import Foundation

public enum AppTheme: String, Codable, CaseIterable { case system, dark, light }
public struct AppSettings: Codable, Equatable {
    public var theme: AppTheme = .dark
    public var language = AppSettings.defaultLanguage()
    public var font = "JetBrainsMono-Regular"
    public var fontSize = 13.0
    public var showHiddenFiles = false
    public var toolboxPinned = false
    public var downloadBookmark: Data?
    public var fileSort: RemoteFileSort = .name
    public var fileSortDescending = false
    public var codeWrap = false
    public var codeFontSize = 13.0
    /// How long a left desktop stays connected: 5, 10 or 30 minutes.
    public var desktopKeepAliveMinutes = 10
    /// Show the network stats overlay (also toggled in 操作).
    public var desktopShowStats = false
    /// Where the network figures sit, as fractions of the room the picture leaves them: 0, 0 is the top left.
    public var desktopStatsX = 0.0
    public var desktopStatsY = 0.0
    /// Per-host desktop prefs, keyed by host id (mode/quality/fps/lock).
    public var desktopHosts: [String: DesktopHostSettings] = [:]
    /// Debug: replace the pinned plugin base URL.
    public var desktopPluginBaseUrl = ""
    /// Which agent notifications come (设置 → 通知).
    public var agentNotifications = AgentNotifications.all
    public init() {}

    /// A first launch follows the phone's language: Chinese for Chinese, English otherwise. A saved choice wins.
    public static func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    private enum CodingKeys: String, CodingKey {
        case theme, language, font, fontSize, showHiddenFiles, toolboxPinned, downloadBookmark
        case fileSort, fileSortDescending, codeWrap, codeFontSize
        case desktopKeepAliveMinutes, desktopShowStats, desktopStatsX, desktopStatsY, desktopHosts, desktopPluginBaseUrl, agentNotifications
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = AppTheme(rawValue: try values.decodeIfPresent(String.self, forKey: .theme) ?? "") ?? .dark
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? AppSettings.defaultLanguage()
        font = try values.decodeIfPresent(String.self, forKey: .font) ?? "JetBrainsMono-Regular"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        toolboxPinned = try values.decodeIfPresent(Bool.self, forKey: .toolboxPinned) ?? false
        downloadBookmark = try values.decodeIfPresent(Data.self, forKey: .downloadBookmark)
        fileSort = RemoteFileSort(rawValue: try values.decodeIfPresent(String.self, forKey: .fileSort) ?? "") ?? .name
        fileSortDescending = try values.decodeIfPresent(Bool.self, forKey: .fileSortDescending) ?? false
        codeWrap = try values.decodeIfPresent(Bool.self, forKey: .codeWrap) ?? false
        codeFontSize = min(22, max(9, try values.decodeIfPresent(Double.self, forKey: .codeFontSize) ?? 13))
        // Desktop keys are best-effort: a bad value must not fail the whole settings blob (launch path).
        let keep = (try? values.decodeIfPresent(Int.self, forKey: .desktopKeepAliveMinutes)) ?? 10
        desktopKeepAliveMinutes = [5, 10, 30].contains(keep) ? keep : 10
        desktopShowStats = (try? values.decodeIfPresent(Bool.self, forKey: .desktopShowStats)) ?? false
        desktopStatsX = min(1, max(0, (try? values.decodeIfPresent(Double.self, forKey: .desktopStatsX)) ?? 0))
        desktopStatsY = min(1, max(0, (try? values.decodeIfPresent(Double.self, forKey: .desktopStatsY)) ?? 0))
        desktopHosts = (try? values.decodeIfPresent([String: DesktopHostSettings].self, forKey: .desktopHosts)) ?? [:]
        desktopPluginBaseUrl = (try? values.decodeIfPresent(String.self, forKey: .desktopPluginBaseUrl)) ?? ""
        agentNotifications = AgentNotifications(rawValue: (try? values.decodeIfPresent(String.self, forKey: .agentNotifications)) ?? "") ?? .all
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(theme, forKey: .theme)
        try values.encode(language, forKey: .language)
        try values.encode(font, forKey: .font)
        try values.encode(fontSize, forKey: .fontSize)
        try values.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try values.encode(toolboxPinned, forKey: .toolboxPinned)
        try values.encodeIfPresent(downloadBookmark, forKey: .downloadBookmark)
        try values.encode(fileSort, forKey: .fileSort)
        try values.encode(fileSortDescending, forKey: .fileSortDescending)
        try values.encode(codeWrap, forKey: .codeWrap)
        try values.encode(codeFontSize, forKey: .codeFontSize)
        try values.encode(desktopKeepAliveMinutes, forKey: .desktopKeepAliveMinutes)
        try values.encode(desktopShowStats, forKey: .desktopShowStats)
        try values.encode(desktopStatsX, forKey: .desktopStatsX)
        try values.encode(desktopStatsY, forKey: .desktopStatsY)
        try values.encode(desktopHosts, forKey: .desktopHosts)
        try values.encode(desktopPluginBaseUrl, forKey: .desktopPluginBaseUrl)
        try values.encode(agentNotifications, forKey: .agentNotifications)
    }
}

/// Per-host desktop preferences stored in `AppSettings.desktopHosts`.
public struct DesktopHostSettings: Codable, Equatable, Sendable {
    public var pointerMode = "touch" // touch | mouse
    public var quality = "auto"
    public var fps = 60
    public var lockOnClose = false
    /// 声音: the host's sound on the phone, on unless switched off for this host.
    public var audio = true
    public init() {}

    private enum CodingKeys: String, CodingKey { case pointerMode, quality, fps, lockOnClose, audio }

    /// Fields added later are missing from settings saved before them: they keep their defaults, or the
    /// whole map (every host's preferences) would fail to decode.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pointerMode = try values.decodeIfPresent(String.self, forKey: .pointerMode) ?? "touch"
        quality = try values.decodeIfPresent(String.self, forKey: .quality) ?? "auto"
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        lockOnClose = try values.decodeIfPresent(Bool.self, forKey: .lockOnClose) ?? false
        audio = try values.decodeIfPresent(Bool.self, forKey: .audio) ?? true
    }
}
