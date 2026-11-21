// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI
import Charts

struct CompactContainerMetrics: View {
    let stats: ContainerResourceUsage
    let isLight: Bool
    @State private var showingDetails = false

    private var cpuText: String {
        stats.cpu_percent.map { String(format: "%.1f%%", $0) } ?? "—"
    }
    private var memoryText: String {
        sizeLabel(stats.memory_bytes) + " / " + sizeLabel(stats.memory_limit_bytes)
    }
    private var fraction: CGFloat {
        CGFloat(min(1, max(0, (stats.memory_percent ?? 0) / 100)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("CPU")
                    .foregroundStyle(KiriPalette.muted(isLight))
                Text(cpuText)
                    .fontWeight(.medium)
                    .monospacedDigit()
                Spacer(minLength: 4)
                Text("内存")
                    .foregroundStyle(KiriPalette.muted(isLight))
                Text(sizeLabel(stats.memory_bytes))
                    .fontWeight(.medium)
                    .monospacedDigit()
                Button { showingDetails.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 18)
                }
                .buttonStyle(.plain)
                .help("查看网络、磁盘 I/O、进程数及内存限制")
                .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("容器资源详情").font(.headline)
                        Divider()
                        LabeledContent("CPU 使用率", value: cpuText)
                        LabeledContent("内存工作集", value: memoryText)
                        LabeledContent("内存占比", value:
                            stats.memory_percent.map { String(format: "%.1f%%", $0) } ?? "—")
                        Divider()
                        LabeledContent("网络接收（累计）", value: sizeLabel(stats.net_rx_bytes))
                        LabeledContent("网络发送（累计）", value: sizeLabel(stats.net_tx_bytes))
                        LabeledContent("磁盘读取（累计）", value: sizeLabel(stats.block_read_bytes))
                        LabeledContent("磁盘写入（累计）", value: sizeLabel(stats.block_write_bytes))
                        LabeledContent("进程数", value: stats.pids.map(String.init) ?? "—")
                    }
                    .padding(16)
                    .frame(width: 300)
                }
            }
            .font(.system(size: 11, design: .rounded))
            .lineLimit(1)
            GeometryReader { proxy in
                Capsule()
                    .fill(KiriPalette.raised(isLight))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fraction > 0.85 ? Color.orange : KiriPalette.blue)
                            .frame(width: proxy.size.width * fraction)
                    }
            }
            .frame(height: 3)
        }
        .foregroundStyle(KiriPalette.title(isLight))
        .padding(.vertical, 2)
        .help("CPU \(cpuText)，内存 \(memoryText)；点击 ⓘ 查看 I/O")
    }
}

struct ConsoleSession: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case exec, logs }
    let kind: Kind
    let containerID: String
    let name: String
    var id: String { kind.rawValue + ":" + containerID }
    var label: String {
        (kind == .exec ? "Exec" : "日志") + ": " + name
    }
}

/// Native macOS tabbing applies only to real secondary windows, not an
/// artificial set of traffic lights inside the workspace.
final class NativeTabbedWindowAnchor: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .preferred
        window?.tabbingIdentifier = "dev.kiri.moby.container-console"
    }
}
struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeTabbedWindowAnchor {
        NativeTabbedWindowAnchor(frame: .zero)
    }
    func updateNSView(_ view: NativeTabbedWindowAnchor, context: Context) {
        view.window?.tabbingMode = .preferred
    }
}

struct DetachedConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ConsoleSession
    @State private var logFollowing = true

    private func command(_ kind: ConsoleCommand) {
        NotificationCenter.default.post(name: consoleCommandNotification,
            object: session.id, userInfo: ["action": kind.rawValue])
    }

    var body: some View {
        Group {
            if session.kind == .exec {
                ExecTerminalView(containerID: session.containerID, containerName: session.name)
            } else {
                ContainerLogWindow(containerID: session.containerID, containerName: session.name)
            }
        }
        .frame(minWidth: 450, minHeight: 220)
        .background(ConsoleAppearance.canvas(colorScheme))
        .background(WindowTabbingConfigurator())
        .navigationTitle(session.label)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if session.kind == .logs {
                    Button {
                        logFollowing.toggle()
                        command(.toggleFollow)
                    } label: {
                        Label(logFollowing ? "暂停跟随" : "实时跟随",
                              systemImage: logFollowing ? "pause.fill" : "play.fill")
                    }
                    Menu {
                        Button("最近 200 行") { command(.last200) }
                        Button("最近 1,000 行") { command(.last1000) }
                        Button("最近 5,000 行") { command(.last5000) }
                    } label: {
                        Label("日志范围", systemImage: "line.3.horizontal.decrease")
                    }
                }
                Button { command(.copy) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button { command(.clear) } label: {
                    Label("清屏", systemImage: "paintbrush")
                }
                if session.kind == .exec {
                    Button { command(.interrupt) } label: {
                        Label("中断", systemImage: "stop.fill")
                    }
                }
            }
        }
    }
}

/// Simple SwiftUI history trace; the backend samples every five seconds,
/// so there is no fake history until actual Docker stats arrive.
// Shared grouped surface. A macOS control background is intentionally
// subtle; no Web-style thick borders or dead-white standalone cards.
struct ModernInspectorCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(colorScheme == .light ? Color.white
                                               : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
    }
}

// Swift Charts: a quiet, gridless line with native gradient area.
// Points are the real 5-second Docker stats history (max 60 values).
struct InspectorAreaChart: View {
    let points: [ContainerHistoryPoint]
    let cpu: Bool
    let accent: Color

    private var ceiling: Double {
        let values = points.compactMap { cpu ? $0.cpuPercent : $0.memoryPercent }
        let peak = values.max() ?? 0
        return min(100.0, max(peak * 1.45, cpu ? 10.0 : 15.0))
    }

    #if KIRI_UI_PREVIEW
    // GitHub's hosted Intel CI macOS runner has no compatible Metal device.
    // In screenshots only, draw the identical gradient trace using CoreGraphics
    // paths. The production .app uses real Swift Charts below.
    private func trace(in size: CGSize) -> Path {
        // Quadratic midpoint interpolation keeps the non-Metal screenshot
        // renderer smooth without altering the underlying Docker samples.
        let samples: [CGPoint] = points.enumerated().compactMap { index, point in
            guard let value = cpu ? point.cpuPercent : point.memoryPercent else {
                return nil
            }
            let x = CGFloat(index) / CGFloat(max(1, points.count - 1)) * size.width
            let y = size.height * CGFloat(1 - min(ceiling, max(0, value)) / ceiling)
            return CGPoint(x: x, y: y)
        }
        var path = Path()
        guard let first = samples.first else { return path }
        path.move(to: first)
        if samples.count > 1 {
            for index in 1..<samples.count {
                let previous = samples[index - 1]
                let current = samples[index]
                let midpoint = CGPoint(x: (previous.x + current.x) / 2,
                                       y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: midpoint, control: previous)
            }
            if let last = samples.last {
                path.addQuadCurve(to: last, control: last)
            }
        }
        return path
    }

    private func area(in size: CGSize) -> Path {
        var path = trace(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                area(in: geometry.size)
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.18), accent.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                trace(in: geometry.size)
                    .stroke(accent, style: StrokeStyle(
                        lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 34)
        .accessibilityLabel(cpu ? "CPU 使用历史曲线" : "内存占比历史曲线")
    }
    #else
    var body: some View {
        Chart(points) { point in
            if let percent = cpu ? point.cpuPercent : point.memoryPercent {
                AreaMark(
                    x: .value("时间", point.timestamp),
                    yStart: .value("基线", 0),
                    yEnd: .value("使用率", percent))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [accent.opacity(0.18), accent.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("时间", point.timestamp),
                    y: .value("使用率", percent))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round))
                    .foregroundStyle(accent)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...ceiling)
        .frame(height: 34)
        .accessibilityLabel(cpu ? "CPU 使用历史曲线" : "内存占比历史曲线")
    }
    #endif
}

struct InspectorMetricTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let points: [ContainerHistoryPoint]
    let cpu: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            InspectorAreaChart(points: points, cpu: cpu, accent: accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(colorScheme == .light
                    ? Color(red: 248 / 255, green: 249 / 255, blue: 251 / 255)
                    : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// Click the tag to copy its fully qualified path / port. The glyph appears
// on hover, so read-only metadata does not look like a row of admin buttons.
struct CopyableInspectorTag: View {
    let text: String
    let copyValue: String
    @State private var hovered = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyValue, forType: .string)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 1)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .opacity(hovered ? 0.7 : 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(hovered ? 0.085 : 0.045),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("点击复制：" + copyValue)
        .onHover { hovered = $0 }
    }
}

struct InspectorEnvironmentRow: View {
    let entry: String
    @State private var revealed = false

    private var key: String {
        guard let separator = entry.firstIndex(of: "=") else { return entry }
        return String(entry[..<separator])
    }
    private var value: String {
        guard let separator = entry.firstIndex(of: "=") else { return "" }
        return String(entry[entry.index(after: separator)...])
    }
    private var sensitive: Bool {
        let name = key.uppercased()
        return ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY",
                "AUTH", "CREDENTIAL", "PRIVATE"].contains { name.contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .lineLimit(2)
            Text(sensitive && !revealed ? "••••••••" : value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if sensitive {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(revealed ? "隐藏此变量" : "仅显示此变量")
                .accessibilityLabel(revealed ? "隐藏 \(key)" : "显示 \(key)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModernInspectorView: View {
    @EnvironmentObject private var model: MobyModel
    @ObservedObject var telemetry: MobyTelemetry
    let item: ContainerItem?
    let onAction: (String, ContainerItem) -> Void
    @State private var inspection: ContainerInspectDetails?
    @State private var inspectionError: String?
    @State private var loading = false

    private func load(_ id: String) async {
        inspection = nil
        inspectionError = nil
        loading = true
        defer { loading = false }
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            let preview = """
            {"Config":{"Env":["NGINX_VERSION=1.27.2","APP_ENV=production",
            "API_TOKEN=redacted-preview"],"WorkingDir":"/etc/nginx","User":""},
            "Mounts":[{"Type":"bind","Source":"/Users/demo/site",
            "Destination":"/srv/project","RW":false}]}
            """
            inspection = try? JSONDecoder().decode(
                ContainerInspectDetails.self, from: Data(preview.utf8))
            return
        }
        #endif
        guard let encodedData = try? JSONSerialization.data(withJSONObject: [
            "action": "inspect", "kind": "containers", "id": id
        ]), let encoded = String(data: encodedData, encoding: .utf8) else {
            inspectionError = "无法构建容器查询请求"
            return
        }
        let result = await Task.detached(priority: .utility) {
            Result { try request(["action", encoded], as: Reply.self) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .failure(let error):
            inspectionError = error.localizedDescription
        case .success(let reply):
            guard reply.ok, let data = reply.message?.data(using: .utf8) else {
                inspectionError = reply.error ?? "Docker Inspect 返回了空结果"
                return
            }
            do {
                inspection = try JSONDecoder().decode(
                    ContainerInspectDetails.self, from: data)
            } catch {
                inspectionError = "容器详情解析失败：\(error.localizedDescription)"
            }
        }
    }

    private func cardHeader(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 10.5))
    }

    // The selected container is the focal point, not another inset gray panel.
    private func heroSummary(_ item: ContainerItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(item.title)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.State == "running" ? "● 运行中" : "● 已停止")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.State == "running" ? Color.green : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((item.State == "running" ? Color.green : Color.secondary)
                            .opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Text(item.Image ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let published = item.Ports?.first(where: {
                $0.Type == "tcp" && $0.PublicPort != nil
            })?.PublicPort {
                Button("localhost:\(String(published)) ↗") {
                    model.action("open_local", fields: [
                        "url": "http://127.0.0.1:\(published)/"
                    ], title: "open_local")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0 / 255, green: 125 / 255, blue: 165 / 255))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(red: 0 / 255, green: 160 / 255, blue: 190 / 255)
                    .opacity(0.10), in: Capsule())
                .buttonStyle(.plain)
                .help("在浏览器中打开 localhost:\(String(published))")
            } else {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.Id, forType: .string)
                } label: {
                    Label(String(item.Id.prefix(12)), systemImage: "doc.on.doc")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.045), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("复制完整容器 ID")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 5)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func resourceCard(_ item: ContainerItem) -> some View {
        ModernInspectorCard {
            cardHeader("实时资源", symbol: "waveform.path.ecg")
            if let stats = telemetry.containerStats[item.Id] {
                let points = telemetry.statsHistory[item.Id] ?? []
                HStack(spacing: 8) {
                    InspectorMetricTile(
                        title: "CPU",
                        value: stats.cpu_percent.map {
                            String(format: "%.1f%%", $0)
                        } ?? "—",
                        points: points, cpu: true, accent: .blue)
                    InspectorMetricTile(
                        title: "内存",
                        value: sizeLabel(stats.memory_bytes),
                        points: points, cpu: false, accent: .green)
                }
                metadata("内存上限", sizeLabel(stats.memory_limit_bytes))
                Divider().opacity(0.4)
                metadata("网络收发（累计）",
                         "\(sizeLabel(stats.net_rx_bytes)) / \(sizeLabel(stats.net_tx_bytes))")
                metadata("磁盘读写（累计）",
                         "\(sizeLabel(stats.block_read_bytes)) / \(sizeLabel(stats.block_write_bytes))")
                metadata("进程数", stats.pids.map(String.init) ?? "—")
            } else {
                Label(item.State == "running" ? "正在采集资源数据…" : "容器未运行",
                      systemImage: "chart.xyaxis.line")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func networkStorageCard(_ item: ContainerItem) -> some View {
        ModernInspectorCard {
            cardHeader("网络与存储", symbol: "network")
            Text("端口映射")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            let ports = (item.Ports ?? []).filter { $0.PublicPort != nil }
            if ports.isEmpty {
                Text("没有已发布端口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                    let host = "localhost:" + String(port.PublicPort ?? 0)
                    let target = String(port.PrivatePort ?? 0) + "/" + (port.Type ?? "tcp")
                    CopyableInspectorTag(text: host + " → " + target,
                                         copyValue: host)
                }
            }
            Divider().opacity(0.4)
            Text("挂载卷")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            let mounts = inspection?.Mounts ?? []
            if loading {
                ProgressView().controlSize(.small)
            } else if mounts.isEmpty {
                Text("没有挂载卷")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(mounts) { mount in
                VStack(alignment: .leading, spacing: 7) {
                    CopyableInspectorTag(text: mount.Destination ?? "—",
                                         copyValue: mount.Destination ?? "")
                    HStack(alignment: .center, spacing: 7) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(mount.Source ?? "—")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(mount.RW == true ? "读写" : "只读")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.055),
                                        in: Capsule())
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func environmentCard() -> some View {
        ModernInspectorCard {
            cardHeader("环境变量", symbol: "curlybraces")
            let env = inspection?.Config?.Env ?? []
            if loading {
                ProgressView().controlSize(.small)
            } else if env.isEmpty {
                Text("没有环境变量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(env.enumerated()), id: \.offset) { _, entry in
                    InspectorEnvironmentRow(entry: entry)
                    if entry != env.last {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroSummary(item)
                        Divider().opacity(0.5)
                        resourceCard(item)
                        networkStorageCard(item)
                        environmentCard()
                        if let inspectionError {
                            Label(inspectionError, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                        }
                        Text(item.Id)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(
                    "选择一个容器",
                    systemImage: "sidebar.right",
                    description: Text("选中容器，即可查看资源、挂载、端口和环境变量。"))
            }
        }
        .task(id: item?.Id) {
            if let id = item?.Id {
                await load(id)
            } else {
                inspection = nil
                inspectionError = nil
            }
        }
    }

}


/// Only these resource cells subscribe to high-frequency telemetry changes.
struct ContainerLiveMetricsView: View {
    @ObservedObject var telemetry: MobyTelemetry
    let item: ContainerItem
    let isLight: Bool

    @ViewBuilder var body: some View {
        if item.State != "running" {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(KiriPalette.faint(isLight))
        } else if let stats = telemetry.containerStats[item.Id] {
            CompactContainerMetrics(stats: stats, isLight: isLight)
        } else {
            Text(telemetry.statsUpdatedAt != nil ? "暂无统计" :
                (telemetry.statsError != nil ? "读取失败" : "采集中…"))
                .font(.system(size: 11))
                .foregroundStyle(KiriPalette.muted(isLight))
                .help(telemetry.statsError ?? "等待 Docker Engine 提供容器统计数据")
        }
    }
}
