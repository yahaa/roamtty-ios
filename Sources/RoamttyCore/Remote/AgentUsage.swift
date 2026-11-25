// Behavioral port of Roamtty Android's AgentUsage.kt: local context-window, quota and multi-agent token telemetry.
import Foundation

/// Remaining percentage and optional reset epoch (UTC seconds) of a rate-limit window (e.g. 5h or 7d).
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Double
    public var resetsAtEpochSeconds: Int64?

    public init(remainingPercent: Double, resetsAtEpochSeconds: Int64? = nil) {
        self.remainingPercent = remainingPercent
        self.resetsAtEpochSeconds = resetsAtEpochSeconds
    }

    public var remainingRounded: Int { Int(min(100, max(0, remainingPercent)).rounded()) }
    public var usedRounded: Int { max(0, min(100, 100 - remainingRounded)) }
}

/// Normalized reasoning / thinking effort tier reported by coding agents.
public enum ReasoningEffort: String, Codable, Equatable, Sendable {
    case minimal, low, medium, high, xhigh, max

    public var bars: Int {
        switch self {
        case .minimal, .low: return 1
        case .medium: return 2
        case .high: return 3
        case .xhigh, .max: return 4
        }
    }

    public var zhLabel: String {
        switch self {
        case .minimal: return "极低"
        case .low: return "低"
        case .medium: return "中等"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "最大"
        }
    }

    public var enShort: String {
        switch self {
        case .minimal: return "Min"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }

    public static func fromRaw(_ raw: String?) -> ReasoningEffort? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimal", "min": return .minimal
        case "low": return .low
        case "medium", "med": return .medium
        case "high": return .high
        case "xhigh", "extra_high", "extra-high", "very_high": return .xhigh
        case "max": return .max
        default: return nil
        }
    }
}

/// Live context-window, quota, reasoning-effort and cumulative token telemetry for one AI agent session.
public struct AgentSessionUsage: Codable, Equatable, Sendable {
    public var agent: CodingAgent?
    public var model: String
    public var effort: String
    public var contextUsed: Int64?
    public var contextLimit: Int64?
    public var contextCacheRead: Int64
    public var contextCacheCreate: Int64
    public var contextTurn: Int64
    public var sessionInput: Int64
    public var sessionOutput: Int64
    public var sessionCacheRead: Int64
    public var sessionCacheCreate: Int64
    public var quota5h: QuotaWindow?
    public var quota7d: QuotaWindow?

    public init(
        agent: CodingAgent? = nil, model: String = "", effort: String = "",
        contextUsed: Int64? = nil, contextLimit: Int64? = nil,
        contextCacheRead: Int64 = 0, contextCacheCreate: Int64 = 0, contextTurn: Int64 = 0,
        sessionInput: Int64 = 0, sessionOutput: Int64 = 0,
        sessionCacheRead: Int64 = 0, sessionCacheCreate: Int64 = 0,
        quota5h: QuotaWindow? = nil, quota7d: QuotaWindow? = nil
    ) {
        self.agent = agent; self.model = model; self.effort = effort
        self.contextUsed = contextUsed; self.contextLimit = contextLimit
        self.contextCacheRead = contextCacheRead; self.contextCacheCreate = contextCacheCreate; self.contextTurn = contextTurn
        self.sessionInput = sessionInput; self.sessionOutput = sessionOutput
        self.sessionCacheRead = sessionCacheRead; self.sessionCacheCreate = sessionCacheCreate
        self.quota5h = quota5h; self.quota7d = quota7d
    }

    public var contextPercent: Int? {
        guard let used = contextUsed, let limit = contextLimit, limit > 0 else { return nil }
        return max(0, min(100, Int((Double(used) * 100.0 / Double(limit)).rounded())))
    }

    public var contextRemaining: Int64? {
        guard let used = contextUsed, let limit = contextLimit, limit > 0 else { return nil }
        return max(0, limit - used)
    }

    public var sessionTotalTokens: Int64 { sessionInput + sessionOutput + sessionCacheRead + sessionCacheCreate }

    public var cacheHitPercent: Int? {
        let prompt = sessionInput + sessionCacheRead + sessionCacheCreate
        guard prompt > 0, sessionCacheRead > 0 else { return nil }
        return max(0, min(100, Int((Double(sessionCacheRead) * 100.0 / Double(prompt)).rounded())))
    }

    public var hasAnyData: Bool { contextPercent != nil || sessionTotalTokens > 0 || quota5h != nil || quota7d != nil }
    public var formattedModel: String { AgentUsage.formatModelName(model) }
    public var reasoningEffort: ReasoningEffort? { ReasoningEffort.fromRaw(effort) }
}

/// Time window for machine-wide AI token statistics on the host detail screen.
public enum HostUsageRange: String, CaseIterable, Hashable, Sendable {
    case today = "today"
    case week = "7d"
    case month = "30d"

    public func label(english: Bool) -> String {
        switch self {
        case .today: return english ? "Today" : "今日"
        case .week: return english ? "7d" : "7天"
        case .month: return english ? "30d" : "30天"
        }
    }
}

/// Aggregated token consumption and active subscription quota for one agent on a host.
public struct HostAgentUsage: Equatable, Identifiable, Sendable {
    public var id: String { agent.rawValue }
    public var agent: CodingAgent
    public var sessions: Int
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreateTokens: Int64
    public var quota5h: QuotaWindow?
    public var quota7d: QuotaWindow?

    public init(
        agent: CodingAgent, sessions: Int,
        inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, cacheCreateTokens: Int64,
        quota5h: QuotaWindow? = nil, quota7d: QuotaWindow? = nil
    ) {
        self.agent = agent; self.sessions = sessions
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreateTokens = cacheCreateTokens
        self.quota5h = quota5h; self.quota7d = quota7d
    }

    public var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }
}

/// Machine-wide multi-agent AI token snapshot for one `HostUsageRange`.
public struct HostAiUsage: Equatable, Sendable {
    public var range: HostUsageRange
    public var agents: [HostAgentUsage]

    public init(range: HostUsageRange, agents: [HostAgentUsage]) {
        self.range = range; self.agents = agents
    }

    public var totalTokens: Int64 { agents.reduce(0) { $0 + $1.totalTokens } }
    public var totalInput: Int64 { agents.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutput: Int64 { agents.reduce(0) { $0 + $1.outputTokens } }
    public var totalCacheRead: Int64 { agents.reduce(0) { $0 + $1.cacheReadTokens } }
    public var totalCacheCreate: Int64 { agents.reduce(0) { $0 + $1.cacheCreateTokens } }
    public var cacheHitPercent: Int? {
        let prompt = totalInput + totalCacheRead + totalCacheCreate
        guard prompt > 0, totalCacheRead > 0 else { return nil }
        return max(0, min(100, Int((Double(totalCacheRead) * 100.0 / Double(prompt)).rounded())))
    }
}

public extension CodingAgent {
    /// Slash command sent behind the native "压缩上下文" button; nil when the agent has no built-in compaction command.
    var compactCommand: String? {
        switch self {
        case .claude, .codex, .agy: return "/compact"
        case .grok: return nil
        }
    }
}

public enum AgentUsage {
    public static let script: String = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "agent-usage", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { fatalError("agent-usage.py missing") }
        return text
    }()

    public static let scriptData: Data = Data(script.utf8)

    public static func sessionCommand(agent: CodingAgent?, tmuxSession: String?, directory: String) -> String {
        let a = RemoteCommands.shellQuote(agent?.command ?? "")
        let t = RemoteCommands.shellQuote(tmuxSession ?? "")
        let d = RemoteCommands.shellQuote(directory)
        return RemoteCommands.shell("\(RemoteCommands.pathSetup); command -v python3 >/dev/null 2>&1 || exit 0; exec python3 - session \(a) \(t) \(d)")
    }

    public static func hostCommand(range: HostUsageRange) -> String {
        RemoteCommands.shell("\(RemoteCommands.pathSetup); command -v python3 >/dev/null 2>&1 || exit 0; exec python3 - host \(range.rawValue)")
    }

    public static func parseSession(_ output: String?) -> AgentSessionUsage? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var kv: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { kv[key] = val }
        }
        let q5h = kv["q5h_rem"].flatMap(Double.init).map { QuotaWindow(remainingPercent: $0, resetsAtEpochSeconds: kv["q5h_reset"].flatMap(Int64.init)) }
        let q7d = kv["q7d_rem"].flatMap(Double.init).map { QuotaWindow(remainingPercent: $0, resetsAtEpochSeconds: kv["q7d_reset"].flatMap(Int64.init)) }
        let parsed = AgentSessionUsage(
            agent: CodingAgent.fromCommand(kv["agent"]),
            model: kv["model"] ?? "",
            effort: kv["effort"] ?? "",
            contextUsed: kv["ctx_used"].flatMap(Int64.init),
            contextLimit: kv["ctx_limit"].flatMap(Int64.init),
            contextCacheRead: kv["ctx_cache_read"].flatMap(Int64.init) ?? 0,
            contextCacheCreate: kv["ctx_cache_create"].flatMap(Int64.init) ?? 0,
            contextTurn: kv["ctx_turn"].flatMap(Int64.init) ?? 0,
            sessionInput: kv["sess_input"].flatMap(Int64.init) ?? 0,
            sessionOutput: kv["sess_output"].flatMap(Int64.init) ?? 0,
            sessionCacheRead: kv["sess_cache_read"].flatMap(Int64.init) ?? 0,
            sessionCacheCreate: kv["sess_cache_create"].flatMap(Int64.init) ?? 0,
            quota5h: q5h,
            quota7d: q7d
        )
        return (parsed.hasAnyData || !parsed.model.isEmpty || !parsed.effort.isEmpty) ? parsed : nil
    }

    public static func parseHost(_ output: String, requestedRange: HostUsageRange) -> HostAiUsage {
        var range = requestedRange
        var agents: [HostAgentUsage] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("range="), let parsed = HostUsageRange(rawValue: String(line.dropFirst(6))) {
                range = parsed
            } else if line.hasPrefix("agent=") {
                let parts = line.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 6, let agent = CodingAgent.fromCommand(parts[0]) else { continue }
                let q5h = parts.count > 6 ? Double(parts[6]).map { QuotaWindow(remainingPercent: $0, resetsAtEpochSeconds: parts.count > 7 ? Int64(parts[7]) : nil) } : nil
                let q7d = parts.count > 8 ? Double(parts[8]).map { QuotaWindow(remainingPercent: $0, resetsAtEpochSeconds: parts.count > 9 ? Int64(parts[9]) : nil) } : nil
                agents.append(HostAgentUsage(
                    agent: agent,
                    sessions: Int(parts[1]) ?? 0,
                    inputTokens: Int64(parts[2]) ?? 0,
                    outputTokens: Int64(parts[3]) ?? 0,
                    cacheReadTokens: Int64(parts[4]) ?? 0,
                    cacheCreateTokens: Int64(parts[5]) ?? 0,
                    quota5h: q5h,
                    quota7d: q7d
                ))
            }
        }
        return HostAiUsage(range: range, agents: agents.sorted { $0.totalTokens > $1.totalTokens })
    }

    public static func formatTokens(_ count: Int64) -> String {
        let n = max(0, count)
        switch n {
        case ..<1_000: return String(n)
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1_000.0)
        case ..<1_000_000: return "\(Int((Double(n) / 1_000.0).rounded()))k"
        case ..<100_000_000: return String(format: "%.2fM", Double(n) / 1_000_000.0)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000.0)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000.0)
        }
    }

    public static func formatModelName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["-minimal", "-low", "-medium", "-high", "-xhigh", "-max"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        guard !s.isEmpty else { return "" }
        let lower = s.lowercased()
        if lower.hasPrefix("claude-") {
            let parts = lower.dropFirst(7).split(separator: "-").map(String.init)
                .filter { !$0.isEmpty && !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
            if let first = parts.first {
                let family = first.prefix(1).uppercased() + first.dropFirst()
                let ver = parts.dropFirst().prefix { part in part.allSatisfy { $0.isNumber || $0 == "." } }.joined(separator: ".")
                return ver.isEmpty ? family : "\(family) \(ver)"
            }
        }
        if lower.hasPrefix("gemini-") {
            return lower.split(separator: "-").map { part in
                let token = String(part)
                return token.prefix(1).uppercased() + token.dropFirst()
            }.joined(separator: " ")
        }
        return s
    }

    public static func formatQuotaReset(
        _ epochSeconds: Int64?,
        now: Date = Date(),
        english: Bool = false,
        compact: Bool = false,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let target = epochSeconds else { return nil }
        let diff = max(0, target - Int64(now.timeIntervalSince1970))
        if diff < 86_400 {
            let h = diff / 3600
            let m = max(1, (diff % 3600) / 60)
            let dur = h > 0 ? "\(h)h\(compact ? "" : " ")\((diff % 3600) / 60)m" : "\(m)m"
            if compact { return dur }
            return english ? "Resets in \(dur)" : "\(dur) 后重置"
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(target))
        let wd = cal.component(.weekday, from: date)
        let daysZh = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let daysEn = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let day = (wd >= 1 && wd <= 7) ? (english ? daysEn[wd] : daysZh[wd]) : ""
        let hhmm = String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
        if compact { return english ? "\(day) \(hhmm)" : "\(day)\(hhmm)" }
        return english ? "Resets \(day) \(hhmm)" : "\(day) \(hhmm) 重置"
    }
}
