import SwiftUI
import RoamttyCore

enum UsagePalette {
    static func contextColor(_ percent: Int?) -> Color {
        guard let percent else { return Palette.secondary }
        if percent >= 90 { return Palette.danger }
        if percent >= 75 { return Palette.warning }
        return Palette.secondary
    }

    static func terminalContextColor(_ percent: Int?) -> Color {
        guard let percent else { return Color(uiColor: UIColor(hex: 0xC7C4BD)) }
        if percent >= 90 { return Color(uiColor: UIColor(hex: 0xFFB4A8)) }
        if percent >= 75 { return Color(uiColor: UIColor(hex: 0xE9C46A)) }
        return Color(uiColor: UIColor(hex: 0xD6D3CC))
    }

    static func quotaRemainingColor(_ remaining: Int) -> Color {
        if remaining <= 10 { return Palette.danger }
        if remaining <= 25 { return Palette.warning }
        return Palette.success
    }
}

/// Quiet 12pt hollow micro-ring + tabular percentage on line 2 of an AI Agent session card.
struct SessionContextMicroRing: View {
    let percent: Int

    var body: some View {
        let tone = UsagePalette.contextColor(percent)
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Palette.foreground.opacity(0.10), lineWidth: 1.9)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                    .stroke(tone, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }.frame(width: 11, height: 11)
            Text("\(percent)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
        }.fixedSize().accessibilityIdentifier("session-context-ring")
    }
}

/// Always-on 38pt frosted circular context progress ring anchored at the terminal's top-right corner
/// (co-axial with the 48pt right-edge dock below). Single tap entry to `AgentUsageSheet`.
struct TerminalContextRing: View {
    @EnvironmentObject var model: AppModel
    let percent: Int?
    let onTap: () -> Void

    var body: some View {
        let tone = UsagePalette.terminalContextColor(percent)
        let label = percent.map {
            model.text("上下文已用 \($0)%，点按查看用量与剩余额度", "Context \($0)% used, tap to view usage and quota")
        } ?? model.text("查看 Agent 用量与剩余额度", "View agent usage and remaining quota")
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: UIColor(hex: 0x262827)).opacity(0.84))
                    .overlay { Circle().stroke(Color(uiColor: UIColor(hex: 0xF3F0EA)).opacity(0.10), lineWidth: 0.75) }
                    .shadow(color: .black.opacity(0.38), radius: 6, y: 3)
                Circle().stroke(Color(uiColor: UIColor(hex: 0xF3F0EA)).opacity(0.14), lineWidth: 2.5).padding(3.5)
                if let percent {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                        .stroke(tone, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3.5)
                    Text("\(percent)%")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tone)
                        .lineLimit(1)
                } else {
                    miniBars(tone)
                }
            }.frame(width: 38, height: 38).frame(width: 48, height: 48).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("terminal-context-ring")
    }

    private func miniBars(_ tone: Color) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 0.8).fill(tone).frame(width: 2.4, height: 5)
            RoundedRectangle(cornerRadius: 0.8).fill(tone).frame(width: 2.4, height: 8)
            RoundedRectangle(cornerRadius: 0.8).fill(tone).frame(width: 2.4, height: 10.5)
        }
    }
}

/// Smooth horizontal bar with optional multi-colored segments; fractions are relative to total capacity 1.0.
struct SegmentedRatioBar: View {
    struct Segment {
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.foreground.opacity(0.08))
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        if seg.fraction > 0.005 {
                            Rectangle().fill(seg.color)
                                .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, seg.fraction)))))
                        }
                    }
                    Spacer(minLength: 0)
                }.clipShape(Capsule())
            }
        }.frame(height: height)
    }
}

/// Native bottom sheet opened by tapping `TerminalContextRing`: strictly scoped to the current session.
struct AgentUsageSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var compacting = false

    private var kind: CodingAgent? { runtime.activeAgentKind ?? runtime.agentUsage?.agent ?? runtime.launchedAgent }

    private var subtitle: String {
        let user = runtime.host.username
        let raw = (runtime.agentStatus?.directory.isEmpty == false ? runtime.agentStatus?.directory : nil) ?? runtime.paneDirectory
        let path = sessionListPath(raw, username: user)
        return "\(runtime.host.name) · \(path.isEmpty ? "~" : path)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if let usage = runtime.agentUsage, hasDisplayableUsage(usage) {
                    if usage.contextPercent != nil, usage.contextUsed != nil, usage.contextLimit != nil {
                        contextCard(usage)
                    }
                    if usage.quota5h != nil || usage.quota7d != nil {
                        quotaRow(q5h: usage.quota5h, q7d: usage.quota7d)
                    }
                    if usage.sessionTotalTokens > 0 {
                        sessionTokenCard(usage)
                    }
                } else {
                    emptyStateCard
                }
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 24)
        }
        .background(Palette.sheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { runtime.refreshAgentUsage(force: true) }
        .accessibilityIdentifier("agent-usage-sheet")
    }

    private func hasDisplayableUsage(_ usage: AgentSessionUsage) -> Bool {
        (usage.contextPercent != nil && usage.contextUsed != nil && usage.contextLimit != nil)
            || usage.quota5h != nil || usage.quota7d != nil || usage.sessionTotalTokens > 0
    }

    private var header: some View {
        let modelName = runtime.agentUsage?.formattedModel ?? ""
        let titleParts = [kind?.label ?? "Agent", modelName].filter { !$0.isEmpty }
        return HStack(spacing: 10) {
            if let kind { AgentIcon(agent: kind, size: 34) }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleParts.joined(separator: " · "))
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { runtime.refreshAgentUsage(force: true) } label: {
                Group {
                    if runtime.agentUsageLoading { ProgressView().scaleEffect(0.8) } else { AppIcon("ic_refresh", size: 20).foregroundStyle(Palette.secondary) }
                }.frame(width: 40, height: 40).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(runtime.agentUsageLoading)
                .accessibilityLabel(model.text("刷新", "Refresh")).accessibilityIdentifier("agent-usage-refresh")
        }
    }

    private var emptyStateCard: some View {
        HStack(spacing: 10) {
            if runtime.agentUsageLoading {
                ProgressView().scaleEffect(0.85)
                Text(model.text("正在读取会话用量…", "Reading session usage…"))
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            } else {
                Text(model.text("暂未检测到本会话的用量记录，等待 Agent 回复后会自动更新。",
                                "No usage recorded yet for this session. Updates automatically after the agent replies."))
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func contextCard(_ usage: AgentSessionUsage) -> some View {
        let pct = usage.contextPercent ?? 0
        let used = usage.contextUsed ?? 0
        let limit = max(1, usage.contextLimit ?? 1)
        let rem = usage.contextRemaining ?? 0
        let pctColor = pct >= 75 ? UsagePalette.contextColor(pct) : Palette.foreground
        let writeColor = Color(uiColor: UIColor(hex: 0x7AA2F7))
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.text("上下文窗口", "Context window")).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("\(AgentUsage.formatTokens(used)) / \(AgentUsage.formatTokens(limit)) · \(model.text("已用 \(pct)%", "\(pct)% used"))")
                    .font(.system(size: 14, weight: .bold, design: .monospaced)).monospacedDigit().foregroundStyle(pctColor)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            SegmentedRatioBar(segments: contextSegments(usage, limit: limit, writeColor: writeColor, fallback: pctColor), height: 8)
            contextLegend(usage, rem: rem, writeColor: writeColor)
            if kind?.compactCommand != nil { compactButton }
        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("agent-usage-context")
    }

    private func contextSegments(_ usage: AgentSessionUsage, limit: Int64, writeColor: Color, fallback: Color) -> [SegmentedRatioBar.Segment] {
        var list: [SegmentedRatioBar.Segment] = []
        if usage.contextCacheCreate > 0 { list.append(.init(fraction: Double(usage.contextCacheCreate) / Double(limit), color: writeColor)) }
        if usage.contextCacheRead > 0 { list.append(.init(fraction: Double(usage.contextCacheRead) / Double(limit), color: Palette.accent)) }
        if usage.contextTurn > 0 { list.append(.init(fraction: Double(usage.contextTurn) / Double(limit), color: Palette.warning)) }
        if list.isEmpty { list.append(.init(fraction: Double(usage.contextUsed ?? 0) / Double(limit), color: fallback)) }
        return list
    }

    private func contextLegend(_ usage: AgentSessionUsage, rem: Int64, writeColor: Color) -> some View {
        HStack {
            HStack(spacing: 10) {
                if usage.contextCacheCreate > 0 {
                    legendDot(writeColor, model.text("新建 \(AgentUsage.formatTokens(usage.contextCacheCreate))", "Write \(AgentUsage.formatTokens(usage.contextCacheCreate))"))
                }
                if usage.contextCacheRead > 0 {
                    legendDot(Palette.accent, model.text("缓存 \(AgentUsage.formatTokens(usage.contextCacheRead))", "Cache \(AgentUsage.formatTokens(usage.contextCacheRead))"))
                }
                if usage.contextTurn > 0 {
                    legendDot(Palette.warning, model.text("本轮 \(AgentUsage.formatTokens(usage.contextTurn))", "Turn \(AgentUsage.formatTokens(usage.contextTurn))"))
                }
            }
            Spacer(minLength: 4)
            Text(model.text("余 \(AgentUsage.formatTokens(rem))", "\(AgentUsage.formatTokens(rem)) left"))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(Palette.secondary)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(Palette.secondary).lineLimit(1)
        }
    }

    private var compactButton: some View {
        Button {
            guard !compacting else { return }
            compacting = true
            Task {
                let ok = await runtime.compactContext()
                compacting = false
                if ok { dismiss() }
            }
        } label: {
            HStack(spacing: 6) {
                if compacting { ProgressView().scaleEffect(0.75) } else { AppIcon("ic_compress", size: 16) }
                Text(model.text("压缩上下文", "Compact context")).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(compacting).padding(.top, 2).accessibilityIdentifier("agent-usage-compact")
    }

    private func quotaRow(q5h: QuotaWindow?, q7d: QuotaWindow?) -> some View {
        HStack(spacing: 10) {
            if let q5h { quotaCard(title: model.text("5 小时额度", "5-hour quota"), quota: q5h) }
            if let q7d { quotaCard(title: model.text("周额度 (7 天)", "Weekly quota (7d)"), quota: q7d) }
        }.accessibilityIdentifier("agent-usage-quotas")
    }

    private func quotaCard(title: String, quota: QuotaWindow) -> some View {
        let rem = quota.remainingRounded
        let tone = UsagePalette.quotaRemainingColor(rem)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(model.text("剩余", "Left"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(tone)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tone.opacity(0.15), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rem)%").font(.system(size: 22, weight: .bold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(rem <= 25 ? tone : Palette.foreground)
                Text(model.text("已用 \(quota.usedRounded)%", "\(quota.usedRounded)% used"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            SegmentedRatioBar(segments: [.init(fraction: Double(rem) / 100.0, color: tone)], height: 5)
            if let reset = AgentUsage.formatQuotaReset(quota.resetsAtEpochSeconds, english: model.english) {
                Text(reset).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sessionTokenCard(_ usage: AgentSessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text("本次会话 Token", "Session tokens")).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                Text(AgentUsage.formatTokens(usage.sessionTotalTokens))
                    .font(.system(size: 16, weight: .bold, design: .monospaced)).monospacedDigit()
                if let hit = usage.cacheHitPercent {
                    Text(model.text("缓存 \(hit)%", "Cache \(hit)%"))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.success)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Palette.success.opacity(0.15), in: Capsule())
                }
            }
            Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                tokenCol(model.text("输入", "Input"), AgentUsage.formatTokens(usage.sessionInput))
                tokenCol(model.text("输出", "Output"), AgentUsage.formatTokens(usage.sessionOutput))
                tokenCol(model.text("缓存读取", "Cache read"), AgentUsage.formatTokens(usage.sessionCacheRead))
            }
        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("agent-usage-session-tokens")
    }

    private func tokenCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
