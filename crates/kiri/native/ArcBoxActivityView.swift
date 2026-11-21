// Faithful port of ArcBox Desktop's Activity page (Views/Activity): the glass
// metric strip with scrubbing sparklines and the per-container table beneath.
// Data source adapted to Kiri's Docker-only engine (MobyTelemetry).
// Copyright (c) 2026 ArcBox Labs; MIT license.
import AppKit
import Foundation
import SwiftUI

// MARK: - SparklineGeometry (pure geometry, unit-testable)

nonisolated struct SparklineGeometry: Equatable {
    let points: [CGPoint]
    let size: CGSize

    init(values: [Double], domain: ClosedRange<Double>, size: CGSize) {
        self.size = size
        let span = max(domain.upperBound - domain.lowerBound, .ulpOfOne)
        points = values.enumerated().map { offset, value in
            let clamped = min(max(value, domain.lowerBound), domain.upperBound)
            let unit = (clamped - domain.lowerBound) / span
            return CGPoint(
                x: Self.x(forSample: offset, count: values.count, width: size.width),
                y: size.height - CGFloat(unit) * size.height
            )
        }
    }

    static func autoDomain(for values: [Double]) -> ClosedRange<Double> {
        let peak = values.max() ?? 1
        return 0...max(peak * 1.2, 1)
    }

    static func x(forSample offset: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return width * CGFloat(offset) / CGFloat(count - 1)
    }

    static func sampleOffset(atX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0, width > 0, x.isFinite else { return nil }
        guard count > 1 else { return 0 }
        let unit = min(max(x / width, 0), 1)
        return Int((unit * CGFloat(count - 1)).rounded())
    }

    var line: Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        appendCurve(to: &path)
        return path
    }

    var area: Path {
        var path = Path()
        guard let first = points.first, let last = points.last, points.count > 1 else { return path }
        path.move(to: CGPoint(x: first.x, y: size.height))
        path.addLine(to: first)
        appendCurve(to: &path)
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.closeSubpath()
        return path
    }

    private func appendCurve(to path: inout Path) {
        let slopes = tangents
        for index in 0..<(points.count - 1) {
            let from = points[index]
            let to = points[index + 1]
            let dx = (to.x - from.x) / 3
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + dx, y: from.y + dx * slopes[index]),
                control2: CGPoint(x: to.x - dx, y: to.y - dx * slopes[index + 1])
            )
        }
    }

    private var tangents: [CGFloat] {
        let count = points.count
        guard count > 1 else { return Array(repeating: 0, count: count) }
        var slopes = [CGFloat](repeating: 0, count: count)
        for index in 1..<(count - 1) {
            slopes[index] = Self.interiorSlope(points[index - 1], points[index], points[index + 1])
        }
        slopes[0] = Self.endSlope(points[0], points[1], neighbour: slopes[1])
        slopes[count - 1] = Self.endSlope(points[count - 2], points[count - 1], neighbour: slopes[count - 2])
        return slopes
    }

    private static func interiorSlope(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let h0 = p1.x - p0.x
        let h1 = p2.x - p1.x
        let s0 = (p1.y - p0.y) / (h0 == 0 ? h1 : h0)
        let s1 = (p2.y - p0.y) / (h1 == 0 ? h0 : h1)
        let weighted = (s0 * h1 + s1 * h0) / (h0 + h1)
        let sign = (s0 < 0 ? -1 : s0 > 0 ? 1 : 0) + (s1 < 0 ? -1 : s1 > 0 ? 1 : 0)
        return CGFloat(sign) * min(abs(s0), abs(s1), abs(weighted) / 2)
    }

    private static func endSlope(_ p0: CGPoint, _ p1: CGPoint, neighbour: CGFloat) -> CGFloat {
        let h = p1.x - p0.x
        guard h != 0 else { return neighbour }
        return (3 * (p1.y - p0.y) / h - neighbour) / 2
    }
}

// MARK: - Metric point + history buffer

struct MetricPoint: Equatable {
    let index: Int
    let value: Double
    let monotonicMs: Int64
}

/// VM-level rolling samples for the strip. Kiri's engine exposes Docker's
/// `/containers/{id}/stats?stream=false`; the VM figures aggregate the running
/// containers' frames, one sample per poll tick.
@MainActor
final class KiriActivityModel: ObservableObject {
    struct MachineStats {
        var cpuPercent: Double = 0
        var onlineCPUs = 0
        var memoryUsedBytes: UInt64 = 0
        var memoryTotalBytes: UInt64 = 0
        var networkReceiveBytesPerSecond: Double = 0
        var networkTransmitBytesPerSecond: Double = 0
        var loadaverage1: Double = 0
    }

    struct ContainerRow: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        let cpuPercent: Double
        let memoryUsed: UInt64
        let memoryLimit: UInt64
        let netRx: UInt64
        let netTx: UInt64
    }

    @Published var stats: MachineStats?
    @Published var cpuHistory: [MetricPoint] = []
    @Published var memoryHistory: [MetricPoint] = []
    @Published var networkHistory: [MetricPoint] = []
    @Published var containers: [ContainerRow] = []
    @Published var phase: Phase = .connecting

    enum Phase: Equatable {
        case connecting, live
    }

    private var nextIndex = 0
    private var pollTask: Task<Void, Never>?
    private var provider: (() -> (MachineStats?, [ContainerRow]))?
    private let capacity = 60

    func start(provider: @escaping () -> (MachineStats?, [ContainerRow])) {
        self.provider = provider
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        guard let provider else { return }
        let (machine, rows) = provider()
        containers = rows
        guard let machine else {
            phase = .connecting
            return
        }
        phase = .live
        stats = machine
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        func append(_ series: inout [MetricPoint], _ value: Double) {
            series.append(MetricPoint(index: nextIndex, value: value, monotonicMs: nowMs))
            if series.count > capacity { series.removeFirst(series.count - capacity) }
        }
        append(&cpuHistory, machine.cpuPercent)
        append(&memoryHistory, machine.memoryTotalBytes > 0
            ? Double(machine.memoryUsedBytes) / Double(machine.memoryTotalBytes) * 100 : 0)
        append(&networkHistory, machine.networkReceiveBytesPerSecond + machine.networkTransmitBytesPerSecond)
        nextIndex += 1
    }
}

// MARK: - Strip

/// The machine-wide metric bar that floats over the container table (glass
/// surface holding every tile).
struct ActivityMetricStrip: View {
    let stats: KiriActivityModel.MachineStats?
    let cpuHistory: [MetricPoint]
    let memoryHistory: [MetricPoint]
    let networkHistory: [MetricPoint]

    var body: some View {
        ActivityMetricTiles(
            stats: stats,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            networkHistory: networkHistory
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassSurface()
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

struct ActivityMetricTiles: View {
    let stats: KiriActivityModel.MachineStats?
    let cpuHistory: [MetricPoint]
    let memoryHistory: [MetricPoint]
    let networkHistory: [MetricPoint]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 20)],
            alignment: .leading,
            spacing: 14
        ) {
            SparklineTile(
                title: "CPU",
                points: cpuHistory,
                tint: MetricTint.cpu,
                domain: 0...100,
                liveValue: stats.map { StatsFormat.percent($0.cpuPercent) } ?? "00%",
                liveCaption: stats.map { "\($0.onlineCPUs) cores · load \(StatsFormat.load($0.loadaverage1))" }
                    ?? "0 cores · load 0.00",
                format: StatsFormat.percent
            )
            SparklineTile(
                title: "Memory",
                points: memoryHistory,
                tint: MetricTint.memory,
                domain: 0...100,
                liveValue: stats.map { StatsFormat.percent($0.memoryTotalBytes > 0 ? Double($0.memoryUsedBytes) / Double($0.memoryTotalBytes) * 100 : 0) } ?? "00%",
                liveCaption: stats.map {
                    "\(StatsFormat.bytes($0.memoryUsedBytes)) of \(StatsFormat.bytes($0.memoryTotalBytes))"
                } ?? "0 GB of 0 GB",
                format: StatsFormat.percent
            )
            SparklineTile(
                title: "Network",
                points: networkHistory,
                tint: MetricTint.network,
                domain: nil,
                liveValue: stats.map {
                    StatsFormat.rate($0.networkReceiveBytesPerSecond + $0.networkTransmitBytesPerSecond)
                } ?? "0 MB/s",
                liveCaption: stats.map {
                    "↓ \(StatsFormat.rate($0.networkReceiveBytesPerSecond)) · ↑ \(StatsFormat.rate($0.networkTransmitBytesPerSecond))"
                } ?? "↓ 0 MB/s · ↑ 0 MB/s",
                format: StatsFormat.rate
            )
        }
    }
}

enum MetricTint {
    static let cpu = Color.blue
    static let memory = Color.purple
    static let network = Color.green
}

private struct MetricTile<Figure: View>: View {
    let title: LocalizedStringKey
    let value: String
    let caption: String
    var valueColor: Color = AppColors.text
    @ViewBuilder var figure: Figure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .unredacted()
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .unredacted()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64, alignment: .top)
        figure
            .frame(height: 30)
    }
}

private struct SparklineTile: View {
    let title: LocalizedStringKey
    let points: [MetricPoint]
    let tint: Color
    let domain: ClosedRange<Double>?
    let liveValue: String
    let liveCaption: String
    let format: (Double) -> String

    @State private var scrubbedIndex: Int?

    var body: some View {
        MetricTile(
            title: title,
            value: scrubbed.map { format($0.value) } ?? liveValue,
            caption: scrubbed.map(elapsedCaption) ?? liveCaption,
            valueColor: scrubbed == nil ? AppColors.text : tint
        ) {
            Sparkline(points: points, tint: tint, domain: domain, scrubbedIndex: $scrubbedIndex)
        }
    }

    private var scrubbed: MetricPoint? {
        scrubbedIndex.flatMap { index in points.first { $0.index == index } }
    }

    private func elapsedCaption(_ point: MetricPoint) -> String {
        guard let latest = points.last, latest.monotonicMs > point.monotonicMs else {
            return "latest sample"
        }
        let seconds = Int((latest.monotonicMs - point.monotonicMs) / 1000)
        return seconds < 1 ? "latest sample" : "\(seconds)s ago"
    }
}

private struct Sparkline: View {
    let points: [MetricPoint]
    let tint: Color
    let domain: ClosedRange<Double>?
    @Binding var scrubbedIndex: Int?

    @State private var figure: CGSize = .zero

    private static let markerDiameter: CGFloat = 4.5
    private static let scrubbingMarkerDiameter: CGFloat = 7
    private static let overflow = scrubbingMarkerDiameter / 2

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: Self.overflow, y: Self.overflow)
            let size = CGSize(width: size.width - 2 * Self.overflow, height: size.height - 2 * Self.overflow)
            let values = points.map(\.value)
            let geometry = SparklineGeometry(
                values: values,
                domain: domain ?? SparklineGeometry.autoDomain(for: values),
                size: size
            )
            context.fill(
                geometry.area,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                geometry.line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            guard let offset = markedOffset, offset < geometry.points.count else { return }
            let marked = geometry.points[offset]
            if scrubbedIndex != nil {
                var rule = Path()
                rule.move(to: CGPoint(x: marked.x, y: 0))
                rule.addLine(to: CGPoint(x: marked.x, y: size.height))
                context.stroke(rule, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 1))
            }
            let diameter = scrubbedIndex == nil ? Self.markerDiameter : Self.scrubbingMarkerDiameter
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: marked.x - diameter / 2, y: marked.y - diameter / 2,
                        width: diameter, height: diameter)),
                with: .color(tint)
            )
        }
        .padding(-Self.overflow)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { figure = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location): scrub(atX: location.x)
            case .ended: scrubbedIndex = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { scrub(atX: $0.location.x) }
                .onEnded { value in
                    if CGRect(origin: .zero, size: figure).contains(value.location) {
                        scrub(atX: value.location.x)
                    } else {
                        scrubbedIndex = nil
                    }
                }
        )
        .accessibilityHidden(true)
    }

    private var markedOffset: Int? {
        guard let scrubbedIndex,
              let offset = points.firstIndex(where: { $0.index == scrubbedIndex })
        else { return points.indices.last }
        return offset
    }

    private func scrub(atX x: CGFloat) {
        guard let offset = SparklineGeometry.sampleOffset(atX: x, count: points.count, width: figure.width) else {
            return
        }
        scrubbedIndex = points[offset].index
    }
}

// MARK: - Page

/// Live resource monitor: the strip floats above the per-container table.
struct KiriActivityView: View {
    @StateObject private var vm = KiriActivityModel()
    @EnvironmentObject private var model: MobyModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            ActivityMetricStrip(
                stats: vm.stats,
                cpuHistory: vm.cpuHistory,
                memoryHistory: vm.memoryHistory,
                networkHistory: vm.networkHistory
            )
            activityTable
        }
        .background(AppColors.background)
        .searchable(text: $searchText, isPresented: $isSearching, prompt: "Filter Containers")
        .onChange(of: isSearching) { _, searching in
            if !searching { searchText = "" }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .status) {
                StreamStatusPill(phase: vm.phase)
            }
        }
        .onAppear { startIfNeeded() }
    }

    private var subtitle: String {
        vm.phase == .live ? "Live" : "Connecting…"
    }

    private func startIfNeeded() {
        vm.start(provider: { [weak model] in
            guard let model else { return (nil, []) }
            return Self.sample(model: model)
        })
    }

    /// Reads one frame from the runtime snapshot: machine figures aggregate the
    /// running containers' stats the way ArcBox's daemon stream does.
    static func sample(model: MobyModel) -> (KiriActivityModel.MachineStats?, [KiriActivityModel.ContainerRow]) {
        guard model.online else { return (nil, []) }
        var rows: [KiriActivityModel.ContainerRow] = []
        var cpu = 0.0
        var usedBytes: UInt64 = 0
        var totalBytes: UInt64 = 0
        var rx: Double = 0
        var tx: Double = 0
        let usage = model.telemetry.containerStats
        for container in model.containers where container.State == "running" {
            if let u = usage[container.Id] {
                cpu += u.cpu_percent ?? 0
                usedBytes += UInt64(max(0, u.memory_bytes ?? 0))
                totalBytes = max(totalBytes, UInt64(max(0, u.memory_limit_bytes ?? 0)))
                rx += Double(u.net_rx_bytes ?? 0)
                tx += Double(u.net_tx_bytes ?? 0)
                rows.append(KiriActivityModel.ContainerRow(
                    id: container.Id, name: container.title, image: container.Image ?? "—",
                    cpuPercent: u.cpu_percent ?? 0,
                    memoryUsed: UInt64(max(0, u.memory_bytes ?? 0)),
                    memoryLimit: UInt64(max(0, u.memory_limit_bytes ?? 0)),
                    netRx: UInt64(max(0, u.net_rx_bytes ?? 0)),
                    netTx: UInt64(max(0, u.net_tx_bytes ?? 0))))
            }
        }
        let stats = KiriActivityModel.MachineStats(
            cpuPercent: min(cpu, 100 * 64), onlineCPUs: ProcessInfo.processInfo.activeProcessorCount,
            memoryUsedBytes: usedBytes, memoryTotalBytes: totalBytes,
            networkReceiveBytesPerSecond: rx, networkTransmitBytesPerSecond: tx,
            loadaverage1: 0)
        return (stats, rows)
    }

    @ViewBuilder private var activityTable: some View {
        let rows = vm.containers
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.image.localizedCaseInsensitiveContains(search) }
        if rows.isEmpty {
            ContentUnavailableView {
                Label(vm.phase == .live ? "No Running Containers" : "Waiting for samples",
                      systemImage: "waveform.path.ecg")
            } description: {
                Text(vm.phase == .live
                     ? "Activity appears once a container is running."
                     : "Streaming resource usage from the Linux VM.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("Container") { row in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(AppColors.running)
                        Text(row.name).font(.system(size: 13, weight: .medium))
                    }
                }
                TableColumn("Image") { Text($0.image).foregroundStyle(.secondary) }
                TableColumn("CPU") { row in
                    Text(StatsFormat.percent(row.cpuPercent)).monospacedDigit()
                }.width(70)
                TableColumn("Memory") { row in
                    Text("\(StatsFormat.bytes(row.memoryUsed)) / \(StatsFormat.bytes(row.memoryLimit))").monospacedDigit()
                }.width(150)
                TableColumn("Network I/O") { row in
                    Text("↓ \(StatsFormat.bytes(row.netRx)) · ↑ \(StatsFormat.bytes(row.netTx))").monospacedDigit()
                }.width(180)
            }
        }
    }

    private var search: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }
}

/// The streaming state pill in the toolbar (ArcBox ActivityView).
struct StreamStatusPill: View {
    let phase: KiriActivityModel.Phase

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch phase {
        case .live: AppColors.running
        case .connecting: AppColors.warning
        }
    }

    private var label: String {
        switch phase {
        case .live: "Live"
        case .connecting: "Connecting"
        }
    }
}
