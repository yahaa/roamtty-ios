import SwiftUI
import RoamttyCore

/// Machine-wide AI Agent token consumption & active subscription quotas on the host detail screen.
struct HostAiUsageSection: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    @State private var range: HostUsageRange = .today

    private var snapshot: HostAiUsage? { model.monitor.aiUsage[host.id]?[range] }
    private var loading: Bool { model.monitor.aiUsageLoading.contains(host.id) }
    private var connected: Bool { model.monitor.states[host.id]?.phase == .connected }

    var body: some View {
        if host.system.lowercased() != "windows", connected || snapshot != nil {
            VStack(alignment: .leading, spacing: 8) {
                headerRow
                Panel {
                    if snapshot == nil && loading {
                        loadingRow
                    } else if let snapshot, !snapshot.agents.isEmpty {
                        summaryHeader(snapshot)
                        ForEach(snapshot.agents) { row in
                            Rectangle().fill(Palette.foreground.opacity(0.07)).frame(height: 1).padding(.leading, 16)
                            agentRow(row)
                        }
                    } else {
                        Text(model.text("该时间范围内暂无 AI Agent 用量记录", "No AI agent usage recorded in this period"))
                            .font(.subheadline).foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
            .onChange(of: range) { next in model.monitor.loadAiUsage(host, range: next, force: false) }
            .accessibilityIdentifier("host-ai-usage")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(model.text("AI 用量", "AI Usage"))
                .font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
            if loading { ProgressView().scaleEffect(0.7) }
            Spacer()
            HStack(spacing: 2) {
                ForEach(HostUsageRange.allCases, id: \.self) { option in
                    let active = option == range
                    Button { range = option } label: {
                        Text(option.label(english: model.english))
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Palette.foreground : Palette.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(active ? Palette.containerHighest : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("host-ai-range-\(option.rawValue)")
                }
            }.padding(2).background(Palette.panel, in: Capsule())
        }.padding(.horizontal, 16)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Text(model.text("正在读取本机 AI 用量…", "Reading host AI usage…"))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
        }.padding(16)
    }

    private func summaryHeader(_ snap: HostAiUsage) -> some View {
        let total = max(1, snap.totalTokens)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(AgentUsage.formatTokens(snap.totalTokens))
                        .font(.system(size: 20, weight: .bold, design: .monospaced)).monospacedDigit()
                    Text("tokens").font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if let hit = snap.cacheHitPercent {
                    Text(model.text("缓存命中 \(hit)%", "Cache hit \(hit)%"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.success)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Palette.success.opacity(0.15), in: Capsule())
                }
            }
            SegmentedRatioBar(
                segments: snap.agents.map { .init(fraction: Double($0.totalTokens) / Double(total), color: $0.agent.brand) },
                height: 6
            )
            Text(model.text(
                "输入 \(AgentUsage.formatTokens(snap.totalInput)) · 输出 \(AgentUsage.formatTokens(snap.totalOutput)) · 缓存 \(AgentUsage.formatTokens(snap.totalCacheRead))",
                "In \(AgentUsage.formatTokens(snap.totalInput)) · Out \(AgentUsage.formatTokens(snap.totalOutput)) · Cache \(AgentUsage.formatTokens(snap.totalCacheRead))"
            ))
            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
            .foregroundStyle(Palette.secondary).lineLimit(1)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func agentRow(_ row: HostAgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(row.agent.brand).frame(width: 8, height: 8)
                Text(row.agent.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    Text(AgentUsage.formatTokens(row.totalTokens))
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced)).monospacedDigit()
                    if row.sessions > 0 {
                        Text(model.text(" · \(row.sessions)会话", " · \(row.sessions) sess"))
                            .font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
            if row.quota5h != nil || row.quota7d != nil {
                HStack(spacing: 12) {
                    if let q5h = row.quota5h {
                        let reset = AgentUsage.formatQuotaReset(q5h.resetsAtEpochSeconds, english: model.english, compact: true)
                        let label = reset.map { model.text("5h 剩 · \($0)", "5h · \($0)") } ?? model.text("5h 剩余", "5h left")
                        quotaMiniBar(label: label, remaining: q5h.remainingRounded, brand: row.agent.brand)
                    }
                    if let q7d = row.quota7d {
                        let reset = AgentUsage.formatQuotaReset(q7d.resetsAtEpochSeconds, english: model.english, compact: true)
                        let label = reset.map { model.text("周剩 · \($0)", "7d · \($0)") } ?? model.text("周剩余", "7d left")
                        quotaMiniBar(label: label, remaining: q7d.remainingRounded, brand: row.agent.brand)
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func quotaMiniBar(label: String, remaining: Int, brand: Color) -> some View {
        let color = remaining <= 25 ? UsagePalette.quotaRemainingColor(remaining) : brand
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(remaining)%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(remaining <= 25 ? color : Palette.foreground)
            }
            SegmentedRatioBar(segments: [.init(fraction: Double(remaining) / 100.0, color: color)], height: 4)
        }.frame(maxWidth: .infinity)
    }
}
