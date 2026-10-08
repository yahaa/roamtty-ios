import SwiftUI
import RoamttyCore

struct HostDetailScreen: View {
    @EnvironmentObject var model: AppModel
    let hostID: String
    @State private var deleteConfirm = false
    var host: Host? { model.host(hostID) }
    var body: some View {
        Group {
            if let host {
                ScrollView {
                    VStack(spacing: 24) {
                        HStack(spacing: 16) {
                            HostSystemMark(system: host.system).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(host.username)@\(host.address):\(String(host.port))").font(.subheadline).textSelection(.enabled)
                                Text(model.metrics[hostID]?.os ?? host.system).font(.subheadline).foregroundStyle(Palette.secondary)
                                ReachabilityLabel(state: model.reachability[hostID] ?? .checking)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Button { model.sheet = .launch(host, true) } label: { Label(model.text("AI 助手", "AI agent"), systemImage: "sparkles") }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("host-detail-agent")
                            Button { model.sheet = .launch(host, false) } label: { Label(model.text("终端", "Terminal"), systemImage: "terminal") }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("host-detail-terminal")
                            Button { model.path.append(.files(hostID)) } label: { Label(model.text("文件", "Files"), systemImage: "folder") }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("host-detail-files")
                        }
                        Panel(title: model.text("会话  \(model.records.filter { $0.hostID == hostID }.count)", "Sessions  \(model.records.filter { $0.hostID == hostID }.count)")) {
                            let sessions = model.records.filter { $0.hostID == hostID }
                            if sessions.isEmpty { InfoRow(title: model.text("暂无会话", "No sessions"), value: model.text("从上方开始", "Start above")) }
                            ForEach(sessions) { record in SessionRow(record: record).panelDivider() }
                        }
                        monitorStatus(host)
                        if let metrics = model.metrics[hostID] { MetricsPanel(metrics: metrics, series: model.metricSeries[hostID] ?? HostMetricSeries()) }
                        Panel(title: model.text("主机信息", "Host information")) {
                            InfoRow(title: model.text("地址", "Address"), value: host.address).panelDivider()
                            InfoRow(title: model.text("端口", "Port"), value: String(host.port)).panelDivider()
                            InfoRow(title: model.text("用户", "User"), value: host.username).panelDivider()
                            InfoRow(title: model.text("认证方式", "Authentication"), value: authenticationLabel(host.auth)).panelDivider()
                            InfoRow(title: model.text("默认会话", "Default session"), value: host.mode.rawValue).panelDivider()
                            InfoRow(title: model.text("插件", "Plugins"), value: host.plugins.map { $0.isEmpty ? model.text("未安装", "None installed") : $0.joined(separator: " · ") } ?? model.text("未检测", "Not detected"))
                            if let metrics = model.metrics[hostID] {
                                if let hostname = metrics.hostname { InfoRow(title: model.text("主机名", "Hostname"), value: hostname).panelDivider() }
                                InfoRow(title: model.text("内核", "Kernel"), value: metrics.kernel).panelDivider()
                                InfoRow(title: model.text("架构", "Architecture"), value: metrics.arch).panelDivider()
                                if let processor = metrics.cpuModel { InfoRow(title: model.text("处理器", "Processor"), value: processor) }
                            }
                        }
                    }.padding(16).frame(maxWidth: 720)
                }.frame(maxWidth: .infinity).pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) { Button { model.sheet = .plugins(host) } label: { Image(systemName: "puzzlepiece.extension") }.accessibilityLabel(model.text("管理插件", "Manage plugins")).accessibilityIdentifier("host-detail-plugins") }
                        ToolbarItem(placement: .navigationBarTrailing) { Button { model.sheet = .editor(host) } label: { Image(systemName: "pencil") }.accessibilityLabel(model.text("编辑主机", "Edit host")).accessibilityIdentifier("host-detail-edit") }
                        ToolbarItem(placement: .navigationBarTrailing) { Menu { Button(model.text("删除主机", "Delete host"), role: .destructive) { deleteConfirm = true }.accessibilityIdentifier("host-delete") } label: { Image(systemName: "ellipsis") }.accessibilityIdentifier("host-detail-menu") }
                    }
                    .onAppear { model.startMonitor(host) }
                    .task(id: host.address + ":" + String(host.port)) { while !Task.isCancelled { await model.probeHosts([host]); do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break } } }
                    .onDisappear { model.stopMonitor(hostID) }
                    .confirmationDialog(model.text("删除 \(host.name)？", "Delete \(host.name)?"), isPresented: $deleteConfirm, titleVisibility: .visible) {
                        Button(model.text("删除主机", "Delete host"), role: .destructive) { model.deleteHost(host) }.accessibilityIdentifier("host-delete-confirm")
                    } message: { Text(model.text("此设备上保存的凭据和会话卡片也会移除。", "Saved credentials and session cards on this device will also be removed.")) }
            }
        }
    }
    private func authenticationLabel(_ method: AuthMethod) -> String {
        switch method {
        case .password: return model.text("密码", "Password")
        case .key: return model.text("SSH 私钥", "SSH key")
        case .interactive: return model.text("键盘交互", "Keyboard-interactive")
        }
    }
    private func monitorStatus(_ host: Host) -> some View {
        Panel(title: model.text("实时监控", "Live monitor")) {
            if let state = model.monitorStates[hostID] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if state.phase.active && !(state.phase == .connected && state.sampled) { ProgressView().scaleEffect(0.8) }
                        else { Circle().fill(state.phase == .connected ? Palette.success : Palette.danger).frame(width: 6, height: 6) }
                        Text(state.reconnecting ? model.text("连接中断，正在自动重连…", "Connection interrupted. Reconnecting…") : state.phase == .connected ? (state.sampled ? model.text("每 3 秒刷新", "Refreshes every 3 seconds") : model.text("正在读取…", "Reading…")) : model.phaseText(state.phase)).font(.subheadline).accessibilityIdentifier("host-monitor-status")
                        Spacer()
                    }
                    if let detail = state.detail { Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.secondary).textSelection(.enabled).accessibilityIdentifier("host-monitor-detail") }
                    if !state.phase.active {
                        if model.metrics[hostID] != nil { Text(model.text("下方保留上次读取结果。", "The last readings are shown below.")).font(.caption).foregroundStyle(Palette.secondary) }
                        Button(model.text("重新连接", "Reconnect")) { model.startMonitor(host, interactive: true) }.accessibilityIdentifier("host-monitor-retry")
                    }
                }.padding(16)
            } else {
                Button { model.startMonitor(host, interactive: true) } label: {
                    InfoRow(title: model.text("连接以查看 CPU、内存和磁盘", "Connect to view CPU, memory and disks"), icon: "waveform.path.ecg")
                }.accessibilityIdentifier("host-monitor-login")
            }
        }
    }
}
struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    @State private var edit = false
    @State private var title = ""
    @State private var confirm = false
    private var phase: ConnectionPhase { model.runtimes[record.id]?.phase ?? .disconnected }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.openSession(record) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.displayTitle).font(.subheadline).foregroundStyle(Palette.foreground)
                    HStack { PhaseLabel(phase: phase); Badge(text: record.mode == .tmux ? "tmux" : "SSH"); if model.runtimes[record.id]?.transportName == "mosh" { Badge(text: "mosh") } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("session-\(record.id)")
            Button { title = record.title; edit = true } label: { Image(systemName: "pencil").frame(width: 36, height: 40) }.accessibilityLabel(model.text("修改会话标题", "Rename session")).accessibilityIdentifier("rename-session-\(record.id)")
            Button(phase.active || record.mode == .shell ? model.text("关闭", "Close") : model.text("移除", "Remove")) { confirm = true }.font(.subheadline).accessibilityIdentifier("close-session-\(record.id)")
        }.padding(16)
            .alert(model.text("修改会话标题", "Rename session"), isPresented: $edit) {
                TextField(model.text("标题", "Title"), text: $title).accessibilityIdentifier("session-title")
                Button(model.text("保存", "Save")) { model.renameSession(record.id, title: title) }.accessibilityIdentifier("session-title-save")
                Button(model.text("取消", "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(record.displayTitle, isPresented: $confirm, titleVisibility: .visible) {
                if phase.active || record.mode == .shell { Button(model.text("关闭连接", "Close connection"), role: .destructive) { model.closeSession(record) } }
                else {
                    Button(model.text("仅移除此卡片", "Remove this card"), role: .destructive) { model.forgetSession(record, terminateRemote: false) }
                    Button(model.text("终止远程 tmux 并移除", "Terminate remote tmux and remove"), role: .destructive) { model.forgetSession(record, terminateRemote: true) }
                }
            } message: { Text(record.mode == .tmux ? model.text("关闭连接会保留远程 tmux 会话。", "Closing a connection preserves the remote tmux session.") : model.text("关闭后普通 SSH 会话将结束。", "Closing ends the plain SSH session.")) }
    }
}
struct MetricsPanel: View {
    @EnvironmentObject var model: AppModel
    let metrics: HostMetrics
    let series: HostMetricSeries
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                gauge("CPU", value: metrics.cpuPercent, detail: metrics.cpus.map { model.text("\($0) 核", "\($0) cores") }, history: series.cpuHistory, id: "host-gauge-cpu")
                gauge(model.text("内存", "Memory"), value: metrics.memPercent, detail: usage(metrics.memUsedBytes, metrics.memTotalBytes), history: series.memHistory, id: "host-gauge-memory")
                gauge(model.text("磁盘", "Disk"), value: metrics.disks.first?.percent, detail: usage(metrics.disks.first?.usedBytes, metrics.disks.first?.totalBytes), history: nil, id: "host-gauge-disk")
            }
            Panel {
                InfoRow(title: model.text("负载 · 1 / 5 / 15 分钟", "Load · 1 / 5 / 15 min"), value: metrics.load.isEmpty ? "—" : metrics.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")).panelDivider()
                InfoRow(title: model.text("网络", "Network"), value: series.netRate.map { "↓ \(bytes($0.rxBytesPerSecond))/s   ↑ \(bytes($0.txBytesPerSecond))/s" } ?? "—").panelDivider().accessibilityIdentifier("host-network-rate")
                InfoRow(title: model.text("运行时间", "Uptime"), value: metrics.uptimeSeconds.map(uptime) ?? "—").panelDivider()
                if let total = metrics.swapTotalBytes, total > 0 { InfoRow(title: model.text("交换分区", "Swap"), value: usage(metrics.swapUsedBytes, total)).panelDivider() }
                if let tasks = metrics.tasks { InfoRow(title: model.text("任务 · 运行中 / 总数", "Tasks · running / total"), value: tasks).panelDivider() }
                if let users = metrics.users { InfoRow(title: model.text("登录会话", "Login sessions"), value: String(users)).panelDivider() }
                ForEach(Array(metrics.disks.dropFirst().enumerated()), id: \.offset) { _, disk in
                    InfoRow(title: disk.mount, value: "\(usage(disk.usedBytes, disk.totalBytes) ?? "—") · \(percent(disk.percent))").panelDivider()
                }
            }
            if !metrics.gpus.isEmpty {
                Panel(title: "GPU") {
                    ForEach(Array(metrics.gpus.enumerated()), id: \.offset) { _, gpu in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(gpu.index) · \(gpu.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                            if !extras(gpu).isEmpty { Text(extras(gpu)).font(.caption).foregroundStyle(Palette.secondary).monospacedDigit() }
                            usageBar(model.text("利用率", "Utilization"), value: gpu.utilPercent, detail: percent(gpu.utilPercent))
                            if gpu.memTotalBytes != nil { usageBar(model.text("显存", "VRAM"), value: gpu.memPercent, detail: usage(gpu.memUsedBytes, gpu.memTotalBytes)) }
                            if let history = series.gpuHistory[gpu.index], history.count >= 2 { sparkline(history, tone: levelColor(gpu.utilPercent)) }
                        }.padding(16).panelDivider().accessibilityIdentifier("host-gpu-\(gpu.index)")
                    }
                }
            }
            if !metrics.gpuProcesses.isEmpty {
                Panel(title: model.text("GPU 进程（按显存排序）", "GPU processes (by VRAM)")) {
                    ForEach(Array(metrics.gpuProcesses.prefix(5).enumerated()), id: \.offset) { _, process in
                        processRow(process.name, first: "PID \(process.pid)", second: "\(model.text("显存", "VRAM")) \(process.memBytes.map { bytes(Double($0)) } ?? "—")").panelDivider()
                    }
                }
            }
            if !metrics.processes.isEmpty {
                Panel(title: model.text("进程（按 CPU 排序）", "Processes (by CPU)")) {
                    ForEach(Array(metrics.processes.enumerated()), id: \.offset) { _, process in
                        processRow(process.name, first: "CPU \(percent(process.cpuPercent))", second: "\(model.text("内存", "RAM")) \(percent(process.memPercent))").panelDivider()
                    }
                }
            }
        }
    }
    private func gauge(_ title: String, value: Double?, detail: String?, history: [Double]?, id: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Palette.foreground.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, value ?? 0))) / 100).stroke(levelColor(value), style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(percent(value)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            }.padding(4).frame(width: 72, height: 72)
            Text(title).font(.caption.weight(.medium))
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if let history { sparkline(history, tone: levelColor(value)).padding(.top, 6) }
            else { Color.clear.frame(height: 28) }
        }.padding(12).frame(maxWidth: .infinity).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(percent(value)), \(detail ?? "")").accessibilityIdentifier(id)
    }
    private func usageBar(_ title: String, value: Double?, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(minWidth: 52, alignment: .leading)
            ProgressView(value: min(100, max(0, value ?? 0)), total: 100).tint(levelColor(value))
            Text(detail ?? "—").monospacedDigit().lineLimit(1).frame(minWidth: 72, alignment: .trailing)
        }.font(.caption).foregroundStyle(Palette.secondary)
    }
    private func sparkline(_ values: [Double], tone: Color) -> some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let step = size.width / CGFloat(HostMetricSeries.historyLimit - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index), y: size.height * CGFloat(1 - min(100, max(0, value)) / 100))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line; fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: start, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .color(tone.opacity(0.14)))
            context.stroke(line, with: .color(tone), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }.frame(height: 22).accessibilityHidden(true)
    }
    private func processRow(_ name: String, first: String, second: String) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(.subheadline, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(first).frame(minWidth: 72, alignment: .trailing)
            Text(second).frame(minWidth: 72, alignment: .trailing)
        }.font(.caption).foregroundStyle(Palette.secondary).monospacedDigit().padding(16)
    }
    private func extras(_ gpu: HostMetrics.Gpu) -> String {
        var parts: [String] = []
        if let frequency = gpu.freqMHz { parts.append(String(format: "%.0f", frequency) + (gpu.freqMaxMHz.map { String(format: "/%.0f", $0) } ?? "") + " MHz") }
        if let used = gpu.memUsedBytes, gpu.memTotalBytes == nil { parts.append(model.text("内存 ", "Memory ") + bytes(Double(used))) }
        if let temperature = gpu.temperatureC { parts.append(String(format: "%.0f°C", temperature)) }
        if let power = gpu.powerWatts { parts.append(String(format: "%.0f", power) + (gpu.powerLimitWatts.map { String(format: "/%.0f", $0) } ?? "") + " W") }
        return parts.joined(separator: " · ")
    }
    private func levelColor(_ value: Double?) -> Color {
        guard let value else { return Palette.outline }
        return value >= 90 ? Palette.danger : value >= 70 ? Palette.warning : Palette.accent
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: $0 < 10 ? "%.1f%%" : "%.0f%%", $0) } ?? "—" }
    private func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = max(0, value), unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: unit == 0 || size >= 100 ? "%.0f %@" : "%.1f %@", size, units[unit])
    }
    private func usage(_ used: Int64?, _ total: Int64?) -> String? {
        guard let used, let total else { return nil }
        var scale = 1.0, scaledTotal = Double(max(0, total)), unit = 0
        while scaledTotal >= 1024 && unit < 5 { scaledTotal /= 1024; scale *= 1024; unit += 1 }
        let scaledUsed = Double(max(0, used)) / scale
        return String(format: unit == 0 || scaledUsed >= 100 ? "%.0f/" : "%.1f/", scaledUsed) + bytes(Double(total))
    }
    private func uptime(_ seconds: Int64) -> String {
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return model.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        if hours > 0 { return model.text("\(hours) 小时 \(minutes) 分钟", "\(hours)h \(minutes)m") }
        return model.text("\(minutes) 分钟", "\(minutes)m")
    }
}
