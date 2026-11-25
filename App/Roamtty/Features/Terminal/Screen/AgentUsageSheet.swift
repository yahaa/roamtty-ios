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

    static func effortColor(_ effort: ReasoningEffort) -> Color {
        switch effort {
        case .minimal, .low: return Palette.secondary
        case .medium: return CodingAgent.codex.brand
        case .high: return Palette.accent
        case .xhigh, .max: return Palette.warning
        }
    }
}

/// Quiet 11pt hollow micro-ring + tabular percentage on line 2 of an AI Agent session card.
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
                .monospacedDigit().foregroundStyle(tone).lineLimit(1)
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
                        .rotationEffect(.degrees(-90)).padding(3.5)
                }
                Text(percent.map { "\($0)%" } ?? "--")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit().foregroundStyle(tone).lineLimit(1)
            }.frame(width: 38, height: 38).frame(width: 48, height: 48).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("terminal-context-ring")
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

/// Dedicated 2-column card separating active model name and 4-step reasoning effort for instant legibility.
private struct ModelEffortCard: View {
    @EnvironmentObject var model: AppModel
    let modelName: String
    let effort: ReasoningEffort?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text("当前模型", "Model")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Text(modelName.isEmpty ? "—" : modelName)
                    .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)

            if let effort {
                let tone = UsagePalette.effortColor(effort)
                Rectangle().fill(Palette.foreground.opacity(0.08)).frame(width: 1).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.text("思考等级", "Reasoning")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                    HStack(spacing: 6) {
                        effortBars(filled: effort.bars, color: tone)
                        Text(model.english ? effort.enShort : effort.zhLabel)
                            .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(tone).lineLimit(1)
                        if !model.english {
                            Text(effort.enShort).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 11)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("agent-usage-model-effort")
    }

    private func effortBars(filled: Int, color: Color) -> some View {
        let heights: [CGFloat] = [4.5, 7, 9.5, 12]
        return HStack(alignment: .bottom, spacing: 2.2) {
            ForEach(0..<4, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(idx < filled ? color : Palette.foreground.opacity(0.10))
                    .frame(width: 2.8, height: heights[idx])
            }
        }
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
            VStack(spacing: 11) {
                header
                if let usage = runtime.agentUsage, hasDisplayableUsage(usage) {
                    if !usage.formattedModel.isEmpty || usage.reasoningEffort != nil {
                        ModelEffortCard(modelName: usage.formattedModel, effort: usage.reasoningEffort)
                    }
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
        !usage.formattedModel.isEmpty || usage.reasoningEffort != nil
            || (usage.contextPercent != nil && usage.contextUsed != nil && usage.contextLimit != nil)
            || usage.quota5h != nil || usage.quota7d != nil || usage.sessionTotalTokens > 0
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let kind { AgentIcon(agent: kind, size: 36) }
            VStack(alignment: .leading, spacing: 2) {
                Text(kind?.label ?? "Agent").font(.system(size: 16, weight: .semibold)).lineLimit(1)
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
                Text(model.text("正在读取会话用量…", "Reading session usage…")).font(.subheadline).foregroundStyle(Palette.secondary)
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
        let pctColor = UsagePalette.contextColor(pct)
        let critical = pct >= 90
        let writeColor = CodingAgent.codex.brand
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.text("上下文窗口", "Context window")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                if kind?.compactCommand != nil { compactPill(critical: critical) }
            }.frame(minHeight: 26)
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(AgentUsage.formatTokens(used)).font(.system(size: 19, weight: .bold, design: .monospaced)).monospacedDigit()
                    Text("/ \(AgentUsage.formatTokens(limit))").font(.system(size: 12.5, design: .monospaced)).monospacedDigit().foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text(model.text("已用 \(pct)%", "\(pct)% used"))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(pctColor)
            }.padding(.top, 6).padding(.bottom, 9)
            SegmentedRatioBar(segments: contextSegments(usage, limit: limit, writeColor: writeColor, critical: critical, fallback: pctColor), height: 7)
            contextLegend(usage, rem: rem, writeColor: writeColor, critical: critical).padding(.top, 8)
        }.padding(.horizontal, 14).padding(.vertical, 12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("agent-usage-context")
    }

    private func compactPill(critical: Bool) -> some View {
        let fg = critical ? Palette.danger : Palette.foreground.opacity(0.88)
        let iconColor = critical ? Palette.danger : Palette.secondary
        let bg = critical ? Palette.danger.opacity(0.14) : Palette.foreground.opacity(0.06)
        let border = critical ? Palette.danger.opacity(0.30) : Palette.foreground.opacity(0.11)
        return Button {
            guard !compacting else { return }
            compacting = true
            Task {
                let ok = await runtime.compactContext()
                compacting = false
                if ok { dismiss() }
            }
        } label: {
            HStack(spacing: 4.5) {
                if compacting { ProgressView().scaleEffect(0.65) } else { AppIcon("ic_compress", size: 13).foregroundStyle(iconColor) }
                Text(model.text("压缩", "Compact")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(fg)
            }
            .padding(.horizontal, 9.5).frame(height: 26)
            .background(bg, in: Capsule())
            .overlay { Capsule().stroke(border, lineWidth: 0.75) }
        }
        .buttonStyle(.plain).disabled(compacting)
        .accessibilityLabel(model.text("压缩上下文", "Compact context"))
        .accessibilityIdentifier("agent-usage-compact")
    }

    private func contextSegments(_ usage: AgentSessionUsage, limit: Int64, writeColor: Color, critical: Bool, fallback: Color) -> [SegmentedRatioBar.Segment] {
        var list: [SegmentedRatioBar.Segment] = []
        if usage.contextCacheCreate > 0 { list.append(.init(fraction: Double(usage.contextCacheCreate) / Double(limit), color: writeColor)) }
        if usage.contextCacheRead > 0 { list.append(.init(fraction: Double(usage.contextCacheRead) / Double(limit), color: Palette.accent)) }
        if usage.contextTurn > 0 { list.append(.init(fraction: Double(usage.contextTurn) / Double(limit), color: critical ? Palette.danger : Palette.warning)) }
        if list.isEmpty { list.append(.init(fraction: Double(usage.contextUsed ?? 0) / Double(limit), color: fallback)) }
        return list
    }

    private func contextLegend(_ usage: AgentSessionUsage, rem: Int64, writeColor: Color, critical: Bool) -> some View {
        HStack {
            HStack(spacing: 10) {
                if usage.contextCacheCreate > 0 {
                    legendDot(writeColor, model.text("新建 \(AgentUsage.formatTokens(usage.contextCacheCreate))", "Write \(AgentUsage.formatTokens(usage.contextCacheCreate))"))
                }
                if usage.contextCacheRead > 0 {
                    legendDot(Palette.accent, model.text("缓存 \(AgentUsage.formatTokens(usage.contextCacheRead))", "Cache \(AgentUsage.formatTokens(usage.contextCacheRead))"))
                }
                if usage.contextTurn > 0 {
                    legendDot(critical ? Palette.danger : Palette.warning, model.text("本轮 \(AgentUsage.formatTokens(usage.contextTurn))", "Turn \(AgentUsage.formatTokens(usage.contextTurn))"))
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
                    .padding(.horizontal, 6).padding(.vertical, 2).background(tone.opacity(0.15), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rem)%").font(.system(size: 21, weight: .bold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(rem <= 25 ? tone : Palette.foreground)
                Text(model.text("已用 \(quota.usedRounded)%", "\(quota.usedRounded)% used"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            SegmentedRatioBar(segments: [.init(fraction: Double(rem) / 100.0, color: tone)], height: 5)
            if let reset = AgentUsage.formatQuotaReset(quota.resetsAtEpochSeconds, english: model.english) {
                Text(reset).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sessionTokenCard(_ usage: AgentSessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text("本次会话 Token", "Session tokens")).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                Text(AgentUsage.formatTokens(usage.sessionTotalTokens)).font(.system(size: 16, weight: .bold, design: .monospaced)).monospacedDigit()
                if let hit = usage.cacheHitPercent {
                    Text(model.text("缓存 \(hit)%", "Cache \(hit)%"))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.success)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Palette.success.opacity(0.15), in: Capsule())
                }
            }
            Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                tokenCol(model.text("输入", "Input"), AgentUsage.formatTokens(usage.sessionInput))
                tokenCol(model.text("输出", "Output"), AgentUsage.formatTokens(usage.sessionOutput))
                tokenCol(model.text("缓存读取", "Cache read"), AgentUsage.formatTokens(usage.sessionCacheRead))
            }
        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("agent-usage-session-tokens")
    }

    private func tokenCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
