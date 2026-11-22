// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI

#if KIRI_UI_PREVIEW
let uiPreviewJSON = """
{
  "online": true,
  "containers": [
    {"Id":"a000000000000000","Names":["/nginx"],"Image":"nginx:1.27",
     "State":"running","Status":"Up 20 minutes","Created":1768900440,
     "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]},
    {"Id":"b000000000000000","Names":["/redis"],"Image":"redis:7-alpine",
     "State":"running","Status":"Up 18 minutes","Created":1768900560,
     "Ports":[{"IP":"0.0.0.0","PrivatePort":6379,"PublicPort":6379,"Type":"tcp"}]},
    {"Id":"c000000000000000","Names":["/mysql"],"Image":"mysql:8.4",
     "State":"running","Status":"Up 16 minutes","Created":1768900680,
     "Ports":[{"IP":"0.0.0.0","PrivatePort":3306,"PublicPort":3306,"Type":"tcp"}]},
    {"Id":"d000000000000000","Names":["/web"],"Image":"nginx:alpine",
     "State":"exited","Status":"Exited (0)","Created":1768899300,"Ports":[]}
  ],
  "images": [], "volumes": [], "networks": [],
  "info":{"NCPU":2,"MemTotal":8589934592,"Architecture":"aarch64","Driver":"overlay2"},
  "version":{"Version":"29.0.0"},
  "memory":{"vm_memory_ceiling_mib":8192,"balloon_target_mib":4096,
            "guest_total_kib":8388608,"guest_available_kib":4194304},
  "vm_config":{"cpus":2,"memory_mib":8192,"max_cpus":10,"max_memory_mib":16384},
  "shares":[],
  "machines":[{"name":"dev","state":"running"},{"name":"ci","state":"stopped"}],
  "kubernetes":"disabled"
}
"""
#endif

@MainActor
final class MobyModel: ObservableObject {
    let telemetry = MobyTelemetry()
    private let dockerEvents = MobyDockerEventMonitor()
    private var eventRefreshTask: Task<Void, Never>?
    @Published var page: Page = .containers
    @Published var search = ""
    @Published var snapshot: Snapshot?
    private var fetchingStats = false
    // Keep unrelated Docker operations responsive; only deduplicate identical requests.
    @Published private(set) var activeOperations = Set<String>()
    private var vmTransitionInProgress = false
    @Published var error: String?
    @Published var result: TextResult?
    @Published var operationMessage: String?
    @Published var toastMessage: String?
    @Published var toastIsError = false
    @Published var composeFile = ""
    @Published var buildFolder = ""
    @Published var buildTag = ""
    @Published var buildPlatform = "linux/arm64"
    @Published var resourceCPUs = 4
    @Published var resourceMemoryMiB = 4096
    @Published var isLight = true
    @Published var sidebarCollapsed = false
    @Published var containerFilter: ContainerFilter = .all
    @Published var collapsedProjects = Set<String>()
    private var refreshing = false
    private var bootRequested = false

    var online: Bool { snapshot?.online == true }
    var containers: [ContainerItem] { snapshot?.containers ?? [] }
    var images: [ImageItem] { snapshot?.images ?? [] }
    var volumes: [VolumeItem] { snapshot?.volumes ?? [] }
    var networks: [NetworkItem] { snapshot?.networks ?? [] }
    var machines: [MachineItem] { snapshot?.machines ?? [] }
    var kubernetesState: String { snapshot?.kubernetes ?? "unavailable" }
    var shares: [String] { snapshot?.shares ?? [] }
    var resourceEditsPending: Bool {
        guard let saved = snapshot?.vm_config else { return false }
        return resourceCPUs != saved.cpus || resourceMemoryMiB != saved.memory_mib
    }
    var resourceRestartRequired: Bool {
        guard online, let saved = snapshot?.vm_config else { return false }
        // Compare boot-time VM settings, NOT the balloon's live target.
        guard let actualCPUs = snapshot?.info?.NCPU,
              let actualMemory = snapshot?.memory?.vm_memory_ceiling_mib else { return false }
        return actualCPUs != saved.cpus || actualMemory != saved.memory_mib
    }
    func saveResources(apply: Bool) {
        guard let limit = snapshot?.vm_config else {
            notify("无法读取虚拟机资源限制", error: true)
            return
        }
        guard (1...max(1, limit.max_cpus)).contains(resourceCPUs),
              (1024...max(1024, limit.max_memory_mib)).contains(resourceMemoryMiB),
              resourceMemoryMiB % 256 == 0 else {
            notify("CPU 或内存超出允许范围；内存必须按 256 MiB 调整", error: true)
            return
        }
        perform(["configure", String(resourceCPUs), String(resourceMemoryMiB),
                 apply ? "apply" : "save"],
                title: apply ? "Apply VM resources" : "Save VM resources",
                showResult: false)
    }

    func begin() {
        guard !bootRequested else { return }
        bootRequested = true
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            snapshot = try? JSONDecoder().decode(
                Snapshot.self, from: Data(uiPreviewJSON.utf8))
            // Screenshot-only sample telemetry. Never bundled in production.
            telemetry.containerStats = [
                "a000000000000000": ContainerResourceUsage(
                    cpu_percent: 2.4, memory_bytes: 58 * 1024 * 1024,
                    memory_limit_bytes: 512 * 1024 * 1024, memory_percent: 11.3,
                    net_rx_bytes: 15 * 1024 * 1024, net_tx_bytes: 360 * 1024,
                    block_read_bytes: 8 * 1024 * 1024,
                    block_write_bytes: 640 * 1024, pids: 4),
                "b000000000000000": ContainerResourceUsage(
                    cpu_percent: 0.7, memory_bytes: 24 * 1024 * 1024,
                    memory_limit_bytes: 256 * 1024 * 1024, memory_percent: 9.4,
                    net_rx_bytes: 2 * 1024 * 1024, net_tx_bytes: 960 * 1024,
                    block_read_bytes: 3 * 1024 * 1024,
                    block_write_bytes: 512 * 1024, pids: 6),
                "c000000000000000": ContainerResourceUsage(
                    cpu_percent: 8.9, memory_bytes: 428 * 1024 * 1024,
                    memory_limit_bytes: 1024 * 1024 * 1024, memory_percent: 41.8,
                    net_rx_bytes: 18 * 1024 * 1024, net_tx_bytes: 7 * 1024 * 1024,
                    block_read_bytes: 120 * 1024 * 1024,
                    block_write_bytes: 31 * 1024 * 1024, pids: 28)
            ]
            telemetry.statsUpdatedAt = .now
            let previewNow = Date()
            var previewHistory = [ContainerHistoryPoint]()
            previewHistory.reserveCapacity(60)
            for index in 0..<60 {
                let age: TimeInterval = Double(index - 59) * 5.0
                let cpu: Double = 1.1 + Double((index * 7) % 15) / 3.0
                let memory: Double = 9.0 + Double((index * 3) % 10) / 4.0
                previewHistory.append(ContainerHistoryPoint(
                    timestamp: previewNow.addingTimeInterval(age),
                    cpuPercent: cpu, memoryPercent: memory))
            }
            telemetry.statsHistory["a000000000000000"] = previewHistory
            isLight = true
            return
        }
        #endif
        refresh()
        // Persistent Docker event stream, with existing periodic reconciliation fallback.
        dockerEvents.start { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleDockerEventRefresh() }
        }
        // Idempotent: a running private Docker VM is reused, never started twice.
        perform(["start"], title: "Start VM", showResult: false)
    }

    func refresh() {
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            return
        }
        #endif
        guard !refreshing else { return }
        refreshing = true
        Task {
            let answer = await Task.detached(priority: .utility) {
                Result { try request(["snapshot"], as: Snapshot.self) }
            }.value
            refreshing = false
            switch answer {
            case .success(let value):
                // Preserve unsaved edits while polling other Docker state.
                if let config = value.vm_config {
                    let previous = snapshot?.vm_config
                    let hasUnsavedEdits = previous.map {
                        resourceCPUs != $0.cpus || resourceMemoryMiB != $0.memory_mib
                    } ?? false
                    if !hasUnsavedEdits {
                        resourceCPUs = config.cpus
                        resourceMemoryMiB = config.memory_mib
                    }
                }
                snapshot = value
                if value.online != true {
                    telemetry.containerStats = [:]
                    telemetry.statsUpdatedAt = nil
                    telemetry.statsError = nil
                    telemetry.statsTruncated = false
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    /// Merge Docker bursts while leaving live CPU/RAM samples on their 5s cadence.
    private func scheduleDockerEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard !Task.isCancelled else { return }
            refresh()
            if page == .containers || page == .compose { refreshContainerStats() }
        }
    }

    /// Refresh CPU/RAM/IO independently from snapshot so Docker container
    /// management and status badges remain responsive during stats sampling.
    func refreshContainerStats() {
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            return
        }
        #endif
        guard !fetchingStats, online,
              page == .containers || page == .compose else { return }
        fetchingStats = true
        Task {
            let answer = await Task.detached(priority: .utility) {
                Result { try request(["stats"], as: ContainerStatsReply.self) }
            }.value
            fetchingStats = false
            guard online else {
                telemetry.containerStats = [:]
                telemetry.statsHistory = [:]
                telemetry.statsUpdatedAt = nil
                return
            }
            switch answer {
            case .success(let reply):
                if reply.ok {
                    // Replace the entire set each round, including evicting stopped
                    // and deleted containers. Never display a stale live CPU rate.
                    telemetry.containerStats = reply.stats ?? [:]
                    let now = Date()
                    telemetry.statsHistory = telemetry.statsHistory.filter { telemetry.containerStats[$0.key] != nil }
                    for (id, stats) in telemetry.containerStats {
                        guard stats.cpu_percent != nil || stats.memory_percent != nil else { continue }
                        var points = telemetry.statsHistory[id] ?? []
                        points.append(ContainerHistoryPoint(
                            timestamp: now, cpuPercent: stats.cpu_percent,
                            memoryPercent: stats.memory_percent))
                        if points.count > 60 { points.removeFirst(points.count - 60) }
                        telemetry.statsHistory[id] = points
                    }
                    telemetry.statsUpdatedAt = .now
                    telemetry.statsTruncated = reply.truncated ?? false
                    telemetry.statsError = nil
                } else {
                    telemetry.statsError = reply.error ?? "容器资源读取失败"
                    telemetry.containerStats = [:]
                    telemetry.statsUpdatedAt = nil
                }
            case .failure(let failure):
                telemetry.statsError = failure.localizedDescription
                telemetry.containerStats = [:]
                telemetry.statsUpdatedAt = nil
            }
        }
    }

    // Legacy Moby UI showed long text in an in-window modal, and normal
    // Docker operation notifications as non-blocking temporary toasts.
    func notify(_ message: String, error: Bool = false) {
        toastMessage = message
        toastIsError = error
        Task {
            try? await Task.sleep(for: .seconds(6.5))
            if toastMessage == message { toastMessage = nil }
        }
    }

    func perform(_ args: [String], title: String, showResult: Bool = true) {
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            notify("CI 布局预览，不会执行实际 Docker 操作")
            return
        }
        #endif
        let operationKey = args.joined(separator: "\u{1F}")
        let vmTransition = args.first == "start" || args.first == "stop"
            || args.first == "restart" || (args.first == "configure" && args.last == "apply")
        guard !activeOperations.contains(operationKey) else {
            notify("\(title): 操作正在执行，请稍候")
            return
        }
        guard !vmTransition || !vmTransitionInProgress else {
            notify("VM 正在切换状态，请等待完成")
            return
        }
        activeOperations.insert(operationKey)
        operationMessage = title
        if vmTransition { vmTransitionInProgress = true }
        Task {
            let answer = await Task.detached(priority: .userInitiated) {
                Result { try request(args, as: Reply.self) }
            }.value
            activeOperations.remove(operationKey)
            if activeOperations.isEmpty { operationMessage = nil }
            if vmTransition { vmTransitionInProgress = false }
            switch answer {
            case .success(let reply):
                if reply.ok {
                    let detailLabels: Set<String> = [
                        "inspect", "logs", "exec", "compose_logs", "compose_ps",
                        "compose_up", "compose_down", "build"
                    ]
                    if showResult && detailLabels.contains(title) {
                        result = TextResult(title: title, body: reply.message ?? "完成")
                    } else {
                        notify("\(title): \(reply.message ?? "完成")")
                    }
                } else {
                    notify("\(title): \(reply.error ?? "失败")", error: true)
                }
            case .failure(let failure):
                notify("\(title): \(failure.localizedDescription)", error: true)
            }
            refresh()
        }
    }

    func action(_ action: String, fields: [String: String] = [:], title: String) {
        var input: [String: String] = ["action":action]
        for (key, value) in fields { input[key] = value }
        guard let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let encoded = String(data: json, encoding: .utf8) else {
            error = "Could not encode the Docker command"
            return
        }
        perform(["action", encoded], title: title)
    }

    func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func ask(_ title: String, placeholder: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.placeholderString = placeholder
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func chooseBuildFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { buildFolder = url.path }
    }

    func chooseShare() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            action("authorize_share", fields: ["path":url.path], title: "Authorize folder")
        }
    }
}

func sizeLabel(_ value: Int64?) -> String {
    guard let v = value, v >= 0 else { return "—" }
    let sizes = ["B", "KB", "MB", "GB", "TB"]
    var scaled = Double(v)
    var index = 0
    while scaled >= 1024 && index < sizes.count - 1 {
        scaled /= 1024
        index += 1
    }
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", scaled, sizes[index])
}

/// Render registry / namespace in secondary gray, identity in primary ink,
/// and the image tag in secondary gray without splitting the row into columns.
func styledImageName(_ raw: String) -> Text {
    let slash = raw.lastIndex(of: "/")
    let colon = raw.lastIndex(of: ":")
    let tagIndex: String.Index? = {
        guard let colon, slash == nil || colon > slash! else { return nil }
        return colon
    }()
    let repository = tagIndex.map { String(raw[..<$0]) } ?? raw
    let tag = tagIndex.map { String(raw[$0...]) } ?? ""
    if let separator = repository.lastIndex(of: "/") {
        let prefix = String(repository[...separator])
        let name = String(repository[repository.index(after: separator)...])
        return Text(prefix).foregroundColor(.secondary)
            + Text(name).foregroundColor(.primary)
            + Text(tag).foregroundColor(.secondary)
    }
    return Text(repository).foregroundColor(.primary)
        + Text(tag).foregroundColor(.secondary)
}

// A separate native log window, matching the reference's floating black console.
// This uses bounded polling over Kiri's private backend; it does not claim a
// Docker streaming connection when the transport is actually snapshot-based.
