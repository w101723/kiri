// Kiri Moby — native SwiftUI/AppKit frontend, macOS 14+.
// No WKWebView, JavaScript runtime, web server or embedded browser.
// Docker/VM operations are delegated to the existing Rust Moby adapter
// through an exact-path, local short-lived JSON command bridge.
import AppKit
import Darwin
import Foundation
import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif
// SwiftTerm also declares a Color type; UI code uses SwiftUI.Color exclusively.
private typealias Color = SwiftUI.Color

private enum Page: String, CaseIterable, Hashable, Identifiable {
    case overview = "总览"
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case compose = "Compose"
    case builds = "Builds"
    case settings = "Settings"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .overview: "虚拟机"
        case .containers: "容器"
        case .images: "镜像"
        case .volumes: "存储卷"
        case .networks: "网络"
        case .compose: "Compose"
        case .builds: "构建"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "cpu"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .compose: "square.3.layers.3d"
        case .builds: "hammer"
        case .settings: "gearshape"
        }
    }
}

private struct PublishedPort: Decodable {
    let IP: String?
    let PrivatePort: Int?
    let PublicPort: Int?
    let `Type`: String?
}

private struct ContainerItem: Decodable, Identifiable {
    let Id: String
    let Names: [String]?
    let Image: String?
    let State: String?
    let Status: String?
    let Ports: [PublishedPort]?
    let Labels: [String: String]?
    let Created: Int64?
    let SizeRw: Int64?
    var id: String { Id }
    var imageSortName: String { Image ?? "" }
    var stateSortName: String { State ?? "" }
    var creationSortDate: Int64 { Created ?? 0 }
    var title: String { Names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String(Id.prefix(12)) }
    var composeProject: String? { Labels?["com.docker.compose.project"] }
    var localPort: Int? { Ports?.first(where: {$0.Type == "tcp" && $0.PublicPort != nil})?.PublicPort }
}

private struct ImageItem: Decodable, Identifiable {
    let Id: String
    let RepoTags: [String]?
    let Size: Int64?
    let Created: Int64?
    var id: String { Id }
    var title: String { RepoTags?.first(where: {$0 != "<none>:<none>"}) ?? String(Id.prefix(18)) }
}

private struct VolumeItem: Decodable, Identifiable {
    let Name: String
    let Driver: String?
    let Mountpoint: String?
    var id: String { Name }
}

private struct NetworkItem: Decodable, Identifiable {
    let Id: String
    let Name: String
    let Driver: String?
    let Scope: String?
    var id: String { Id }
}

private struct DockerInfo: Decodable {
    let NCPU: Int?
    let MemTotal: Int64?
    let Architecture: String?
    let Driver: String?
    let OperatingSystem: String?
}

private struct DockerVersion: Decodable {
    let Version: String?
}

private struct VmResourceSettings: Decodable {
    let cpus: Int
    let memory_mib: Int
    let max_cpus: Int
    let max_memory_mib: Int
}

private struct BalloonInfo: Decodable {
    let vm_memory_ceiling_mib: Int?
    let balloon_target_mib: Int?
    let guest_available_kib: Int?
    let guest_total_kib: Int?
}

/// Aggregated from Docker /containers/{id}/stats, read-only and bounded.
private struct ContainerResourceUsage: Decodable {
    let cpu_percent: Double?
    let memory_bytes: Int64?
    let memory_limit_bytes: Int64?
    let memory_percent: Double?
    let net_rx_bytes: Int64?
    let net_tx_bytes: Int64?
    let block_read_bytes: Int64?
    let block_write_bytes: Int64?
    let pids: Int?
}

private struct ContainerStatsReply: Decodable {
    let ok: Bool
    let stats: [String: ContainerResourceUsage]?
    let truncated: Bool?
    let error: String?
}

/// Typed, read-only Docker inspect payload for the selected container.
private struct ContainerInspectDetails: Decodable {
    struct Configuration: Decodable {
        let Env: [String]?
        let Image: String?
        let WorkingDir: String?
        let User: String?
    }
    struct Mount: Decodable, Identifiable {
        let Type: String?
        let Source: String?
        let Destination: String?
        let RW: Bool?
        var id: String { (Destination ?? "") + "\u{1F}" + (Source ?? "") }
    }
    let Config: Configuration?
    let Mounts: [Mount]?
}
private struct ContainerHistoryPoint: Identifiable {
    let timestamp: Date
    let cpuPercent: Double?
    let memoryPercent: Double?
    var id: Date { timestamp }
}

private struct Snapshot: Decodable {
    let ok: Bool?
    let online: Bool?
    let error: String?
    let containers: [ContainerItem]?
    let images: [ImageItem]?
    let volumes: [VolumeItem]?
    let networks: [NetworkItem]?
    let info: DockerInfo?
    let version: DockerVersion?
    let memory: BalloonInfo?
    let shares: [String]?
    let vm_config: VmResourceSettings?
}

private struct Reply: Decodable {
    let ok: Bool
    let message: String?
    let error: String?
}


/// Matches the four original Kiri container status tabs exactly.
private enum ContainerFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", stopped = "Stopped", failed = "Failed"
    var id: String { rawValue }
    func includes(_ item: ContainerItem) -> Bool {
        let state = item.State ?? ""
        let failed = state == "dead" || state == "removing"
            || ((item.Status ?? "").range(of: #"^exited \(([1-9][0-9]*)\)"#,
                  options: [.regularExpression, .caseInsensitive]) != nil)
        switch self {
        case .all: return true
        case .running: return state == "running"
        case .failed: return failed
        case .stopped: return state != "running" && !failed
        }
    }
}

private enum KiriPalette {
    static let blue = Color(red: 13/255, green: 110/255, blue: 253/255)
    static let mint = Color(red: 63/255, green: 182/255, blue: 139/255)
    static let red = Color(red: 248/255, green: 113/255, blue: 113/255)
    static func bg(_ light: Bool) -> Color {
        light ? Color(red: 249/255, green: 251/255, blue: 253/255)
              : Color(red: 15/255, green: 20/255, blue: 25/255)
    }
    static func side(_ light: Bool) -> Color {
        light ? Color(red: 240/255, green: 244/255, blue: 248/255)
              : Color(red: 18/255, green: 25/255, blue: 32/255)
    }
    static func panel(_ light: Bool) -> Color {
        light ? .white : Color(red: 23/255, green: 29/255, blue: 36/255)
    }
    static func raised(_ light: Bool) -> Color {
        light ? Color(red: 232/255, green: 238/255, blue: 245/255)
              : Color(red: 30/255, green: 37/255, blue: 45/255)
    }
    static func border(_ light: Bool) -> Color {
        light ? Color(red: 207/255, green: 217/255, blue: 227/255)
              : Color(red: 42/255, green: 49/255, blue: 58/255)
    }
    static func muted(_ light: Bool) -> Color {
        light ? Color(red: 83/255, green: 98/255, blue: 115/255)
              : Color(red: 152/255, green: 161/255, blue: 172/255)
    }
    static func faint(_ light: Bool) -> Color {
        light ? Color(red: 102/255, green: 117/255, blue: 136/255)
              : Color(red: 102/255, green: 112/255, blue: 124/255)
    }
    static func title(_ light: Bool) -> Color {
        light ? Color(red: 23/255, green: 33/255, blue: 46/255)
              : Color(red: 242/255, green: 240/255, blue: 235/255)
    }
    static func link(_ light: Bool) -> Color {
        light ? Color(red: 38/255, green: 114/255, blue: 207/255)
              : Color(red: 110/255, green: 168/255, blue: 254/255)
    }
}

private struct TextResult: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

private enum NativeError: Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let s): s
        }
    }
}

/// No shell command, PATH lookup, network listener, environment Docker context
/// or dynamically selected executable: the signer-verified app's own Rust binary.
private func bridge(_ arguments: [String]) throws -> Data {
    let url = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/kiri", isDirectory: false)
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw NativeError.malformed("Kiri CLI is missing inside the installed app.")
    }
    let process = Process()
    process.executableURL = url
    process.arguments = ["moby-native"] + arguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NativeError.malformed("Kiri native backend failed (exit \(process.terminationStatus)).")
    }
    return bytes
}

private func request<T: Decodable>(_ args: [String], as: T.Type) throws -> T {
    let bytes = try bridge(args)
    do {
        return try JSONDecoder().decode(T.self, from: bytes)
    } catch {
        throw NativeError.malformed("Invalid Kiri native response: \(error)")
    }
}

// CI visual reference only. This code is excluded from release builds.
// No live Docker access or synthetic data are ever used in a normal App.
#if KIRI_UI_PREVIEW
private let uiPreviewJSON = """
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
  "shares":[]
}
"""
#endif

@MainActor
private final class MobyModel: ObservableObject {
    @Published var page: Page = .containers
    @Published var search = ""
    @Published var snapshot: Snapshot?
    @Published private(set) var containerStats: [String: ContainerResourceUsage] = [:]
    @Published private(set) var statsHistory: [String: [ContainerHistoryPoint]] = [:]
    @Published private(set) var statsUpdatedAt: Date?
    @Published private(set) var statsError: String?
    @Published private(set) var statsTruncated = false
    private var fetchingStats = false
    // Keep unrelated Docker operations responsive; only deduplicate identical requests.
    @Published private(set) var activeOperations = Set<String>()
    private var vmTransitionInProgress = false
    @Published var error: String?
    @Published var result: TextResult?
    @Published var liveLogContainerID: String?
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
            containerStats = [
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
            statsUpdatedAt = .now
            isLight = true
            return
        }
        #endif
        refresh()
        // Idempotent: if the VM is already online, Rust start_vm() is a no-op.
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
                    containerStats = [:]
                    statsUpdatedAt = nil
                    statsError = nil
                    statsTruncated = false
                }
            case .failure(let failure): error = failure.localizedDescription
            }
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
                containerStats = [:]
                statsHistory = [:]
                statsUpdatedAt = nil
                return
            }
            switch answer {
            case .success(let reply):
                if reply.ok {
                    // Replace the entire set each round, including evicting stopped
                    // and deleted containers. Never display a stale live CPU rate.
                    containerStats = reply.stats ?? [:]
                    let now = Date()
                    statsHistory = statsHistory.filter { containerStats[$0.key] != nil }
                    for (id, stats) in containerStats {
                        guard stats.cpu_percent != nil || stats.memory_percent != nil else { continue }
                        var points = statsHistory[id] ?? []
                        points.append(ContainerHistoryPoint(
                            timestamp: now, cpuPercent: stats.cpu_percent,
                            memoryPercent: stats.memory_percent))
                        if points.count > 60 { points.removeFirst(points.count - 60) }
                        statsHistory[id] = points
                    }
                    statsUpdatedAt = .now
                    statsTruncated = reply.truncated ?? false
                    statsError = nil
                } else {
                    statsError = reply.error ?? "容器资源读取失败"
                    containerStats = [:]
                    statsUpdatedAt = nil
                }
            case .failure(let failure):
                statsError = failure.localizedDescription
                containerStats = [:]
                statsUpdatedAt = nil
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

    func showLiveLogs(_ id: String) {
        liveLogContainerID = id
        result = TextResult(title: "logs", body: "正在加载日志…")
    }

    func refreshLiveLogs(_ id: String) async {
        let input = ["action": "logs", "id": id]
        guard let json = try? JSONSerialization.data(withJSONObject: input),
              let encoded = String(data: json, encoding: .utf8) else { return }
        let answer = await Task.detached(priority: .utility) {
            Result { try request(["action", encoded], as: Reply.self) }
        }.value
        guard liveLogContainerID == id, result?.title == "logs" else { return }
        switch answer {
        case .success(let reply):
            result = TextResult(title: "logs", body: reply.ok ? (reply.message ?? "") : (reply.error ?? "日志读取失败"))
        case .failure(let failure):
            result = TextResult(title: "logs", body: failure.localizedDescription)
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

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "yaml")!, .init(filenameExtension: "yml")!]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { composeFile = url.path }
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

private func sizeLabel(_ value: Int64?) -> String {
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

// A separate native log window, matching the reference's floating black console.
// This uses bounded polling over Kiri's private backend; it does not claim a
// Docker streaming connection when the transport is actually snapshot-based.
@MainActor
private final class ContainerLogSession: ObservableObject {
    @Published var content = ""
    @Published var following = true
    @Published var tailLines = 1000
    @Published var error: String?
    private var previousSnapshot = ""
    private var refreshing = false

    func clear() {
        // Retain the previous snapshot so old lines do not reappear on poll.
        content = ""
    }

    func reload() {
        content = ""
        previousSnapshot = ""
    }

    func refresh(containerID: String) async {
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            if !content.isEmpty { return }
            content = """
            2026-01-20 10:14:32 [notice] nginx/1.27.2
            2026-01-20 10:14:32 [notice] built with OpenSSL 3.3
            2026-01-20 10:14:32 [notice] using the "epoll" event method
            2026-01-20 10:14:32 [notice] start worker processes
            2026-01-20 10:14:32 [notice] start worker process 29
            2026-01-20 10:14:32 [notice] start worker process 30
            2026-01-20 10:14:32 [notice] start worker process 31
            2026-01-20 10:16:08 172.17.0.1 - - "GET / HTTP/1.1" 200
            2026-01-20 10:16:08 172.17.0.1 - - "GET /favicon.ico" 404
            """
            return
        }
        #endif
        guard !refreshing, following else { return }
        refreshing = true
        defer { refreshing = false }
        let input = ["action": "logs", "id": containerID,
                     "tail": String(tailLines)]
        guard let json = try? JSONSerialization.data(withJSONObject: input),
              let encoded = String(data: json, encoding: .utf8) else {
            error = "无法编码日志请求"
            return
        }
        let answer = await Task.detached(priority: .utility) {
            Result { try request(["action", encoded], as: Reply.self) }
        }.value
        switch answer {
        case .success(let reply):
            guard reply.ok else {
                error = reply.error ?? "读取日志失败"
                return
            }
            error = nil
            let next = reply.message ?? ""
            if next == previousSnapshot { return }
            if next.hasPrefix(previousSnapshot) {
                content += String(next.dropFirst(previousSnapshot.count))
            } else {
                content = next
            }
            previousSnapshot = next
            if content.count > 240_000 {
                content.removeFirst(content.count - 240_000)
            }
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

/// NSTextView keeps the native find bar, selection and text system and can
/// apply deltas without rebuilding a SwiftUI Text layout on each log update.
private struct NativeLogTextView: NSViewRepresentable {
    let content: String
    let following: Bool

    final class Coordinator {
        var rendered = ""
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.hasHorizontalScroller = true
        scroller.autohidesScrollers = true
        scroller.drawsBackground = true
        scroller.backgroundColor = ConsoleAppearance.canvasNS
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .white
        view.backgroundColor = scroller.backgroundColor
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scroller.documentView = view
        return scroller
    }
    func updateNSView(_ scroller: NSScrollView, context: Context) {
        guard let view = scroller.documentView as? NSTextView,
              let storage = view.textStorage else { return }
        let previous = context.coordinator.rendered
        guard previous != content else { return }
        if content.hasPrefix(previous) {
            let suffix = String(content.dropFirst(previous.count))
            storage.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white
            ]))
        } else {
            storage.setAttributedString(NSAttributedString(string: content, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white
            ]))
        }
        context.coordinator.rendered = content
        if following {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }
}

/// Consistent charcoal console across tabs, renderer and controls.
private enum ConsoleAppearance {
    static let canvas = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    static let toolbar = Color(red: 31 / 255, green: 31 / 255, blue: 35 / 255)
    static let canvasNS = NSColor(calibratedRed: 20 / 255,
                                  green: 20 / 255, blue: 20 / 255, alpha: 1)
}
private enum ConsoleCommand: String {
    case copy, clear, interrupt, toggleFollow
    case last200, last1000, last5000
}
private let consoleCommandNotification = Notification.Name("dev.kiri.moby.console.action")

private struct ContainerLogWindow: View {
    @StateObject private var session = ContainerLogSession()
    let containerID: String
    let containerName: String

    var body: some View {
        NativeLogTextView(content: session.content, following: session.following)
            .frame(minHeight: 150)
            .background(ConsoleAppearance.canvas)
            .task(id: session.tailLines) {
                while !Task.isCancelled {
                    if session.following {
                        await session.refresh(containerID: containerID)
                    }
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { break }
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: consoleCommandNotification)) { notification in
                guard notification.object as? String == "logs:" + containerID,
                      let action = notification.userInfo?["action"] as? String,
                      let command = ConsoleCommand(rawValue: action) else { return }
                switch command {
                case .copy:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.content, forType: .string)
                case .clear: session.clear()
                case .toggleFollow: session.following.toggle()
                case .last200: session.tailLines = 200
                case .last1000: session.tailLines = 1000
                case .last5000: session.tailLines = 5000
                case .interrupt: break
                }
            }
    }
}

// Dedicated macOS PTY session. The child runs the signed Kiri CLI which
// delegates to docker exec -it over Kiri's private Docker socket.
@MainActor
private final class ExecTerminalSession: ObservableObject {
    @Published var output = ""
    @Published var input = ""
    @Published var running = false
    private var process: Process?
    private var master: FileHandle?
    private var slave: FileHandle?
    private let maxCharacters = 100_000

    func start(containerID: String) {
        guard !running else { return }
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            running = true
            output = """
            / # cat /etc/os-release
            PRETTY_NAME="Alpine Linux v3.19"
            NAME="Alpine Linux"
            VERSION_ID="3.19.1"
            ID=alpine
            HOME_URL="https://alpinelinux.org/"

            / # ls -l /usr/share/nginx/html
            total 8
            -rw-r--r-- 1 root root 615 Jan 20 10:14 50x.html
            -rw-r--r-- 1 root root 615 Jan 20 10:14 index.html

            / # 
            """
            return
        }
        #endif
        guard !containerID.isEmpty, containerID.count <= 64,
              containerID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            output = "无效的容器 ID"
            return
        }
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            output = "无法创建终端 PTY"
            return
        }
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        master = masterHandle
        slave = slaveHandle
        let child = Process()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kiri")
        child.arguments = ["moby-native", "terminal", containerID]
        child.standardInput = slaveHandle
        child.standardOutput = slaveHandle
        child.standardError = slaveHandle
        child.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color"]) { _, new in new }
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running = false
                self.append("\r\n[会话结束：\(ended.terminationStatus)]\r\n")
                self.master?.closeFile()
                self.master = nil
                self.slave?.closeFile()
                self.slave = nil
            }
        }
        do {
            try child.run()
            process = child
            running = true
            // Parent must close its slave descriptor so EOF is observable.
            slaveHandle.closeFile()
            slave = nil
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let data = masterHandle.availableData
                    if data.isEmpty { break }
                    let text = String(decoding: data, as: UTF8.self)
                    Task { @MainActor [weak self] in self?.append(text) }
                }
            }
        } catch {
            append("终端启动失败：\(error.localizedDescription)")
            masterHandle.closeFile()
            slaveHandle.closeFile()
        }
    }

    private func append(_ text: String) {
        // The current view is a line terminal, not a VT100 screen emulator.
        // Remove ANSI SGR/control sequences instead of displaying garbage.
        let printable = text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
            options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        output.append(printable)
        if output.count > maxCharacters {
            output.removeFirst(output.count - maxCharacters)
        }
    }

    func send(_ text: String) {
        guard running, let master else { return }
        master.write(Data(text.utf8))
    }

    func submit() {
        send(input + "\r")
        input = ""
    }

    func interrupt() { send("\u{03}") }
    func close() {
        if running { send("exit\r") }
        if process?.isRunning == true { process?.terminate() }
        master?.closeFile()
        master = nil
        slave?.closeFile()
        slave = nil
        running = false
    }
}

#if canImport(SwiftTerm)
@MainActor
private final class SwiftTermTerminalControls: ObservableObject {
    weak var terminal: LocalProcessTerminalView?
    func interrupt() { terminal?.process.send(data: [0x03][...]) }
    func copy() { terminal?.copy(self) }
    func clear() { terminal?.feed(byteArray: Array("\u{001B}[2J\u{001B}[H".utf8)[...]) }
}

// SwiftTerm's LocalProcessTerminalView owns the PTY, UTF-8/ANSI parser,
// keyboard handling and resize/SIGWINCH. The launched executable is Kiri's
// signed CLI, not a local host shell or a different Docker Engine context.
private struct NativeSwiftTermExecView: NSViewRepresentable {
    let containerID: String
    @ObservedObject var controls: SwiftTermTerminalControls

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = ConsoleAppearance.canvasNS
        view.nativeForegroundColor = NSColor.white
        controls.terminal = view
        let cli = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/MacOS/kiri").path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            view.feed(byteArray: Array("Kiri CLI 不存在：\(cli)\r\n".utf8)[...])
            return view
        }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let environment = env.map { "\($0.key)=\($0.value)" }.sorted()
        view.startProcess(executable: cli,
                          args: ["moby-native", "terminal", containerID],
                          environment: environment)
        return view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: ()) {
        view.terminate()
    }
}
#endif

private struct ExecTerminalView: View {
    @StateObject private var terminal = ExecTerminalSession()
    #if canImport(SwiftTerm)
    @StateObject private var swiftTermControls = SwiftTermTerminalControls()
    #endif
    let containerID: String
    let containerName: String

    var body: some View {
        Group {
            #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
            NativeSwiftTermExecView(containerID: containerID,
                                    controls: swiftTermControls)
                .frame(minHeight: 150)
            #else
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(terminal.output.isEmpty ?
                                 "正在连接容器…" : terminal.output)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            Color.clear.frame(height: 1).id("terminal-bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .onChange(of: terminal.output) { _, _ in
                        proxy.scrollTo("terminal-bottom", anchor: .bottom)
                    }
                }
                HStack(spacing: 6) {
                    TextField("输入命令，Return 执行", text: $terminal.input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .onSubmit { terminal.submit() }
                        .disabled(!terminal.running)
                    Button("发送") { terminal.submit() }
                        .disabled(!terminal.running)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
            }
            .onAppear { terminal.start(containerID: containerID) }
            .onDisappear { terminal.close() }
            #endif
        }
        .frame(minHeight: 155)
        .background(ConsoleAppearance.canvas)
        .onReceive(NotificationCenter.default.publisher(
            for: consoleCommandNotification)) { notification in
            guard notification.object as? String == "exec:" + containerID,
                  let action = notification.userInfo?["action"] as? String,
                  let command = ConsoleCommand(rawValue: action) else { return }
            switch command {
            case .copy:
                #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
                swiftTermControls.copy()
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(terminal.output, forType: .string)
                #endif
            case .clear:
                #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
                swiftTermControls.clear()
                #else
                terminal.output = ""
                #endif
            case .interrupt:
                #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
                swiftTermControls.interrupt()
                #else
                terminal.interrupt()
                #endif
            case .toggleFollow, .last200, .last1000, .last5000:
                break
            }
        }
    }
}

/// The table must stay one-line-dense: network and block I/O live in a
/// dedicated native popover instead of tiny 9pt numbers in every cell.
private struct CompactContainerMetrics: View {
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

private struct ConsoleSession: Codable, Hashable, Identifiable {
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
private final class NativeTabbedWindowAnchor: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .preferred
    }
}
private struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeTabbedWindowAnchor {
        NativeTabbedWindowAnchor(frame: .zero)
    }
    func updateNSView(_ view: NativeTabbedWindowAnchor, context: Context) {
        view.window?.tabbingMode = .preferred
    }
}

private struct DetachedConsoleView: View {
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
        .background(ConsoleAppearance.canvas)
        .environment(\.colorScheme, .dark)
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

private struct RootView: View {
    @EnvironmentObject private var model: MobyModel
    @State private var selectedContainerIDs = Set<String>()
    @State private var selectedInspectorID: String?
    @State private var showInspector = true
    @State private var tableSortOrder = [KeyPathComparator(\ContainerItem.title)]
    @State private var sessions: [ConsoleSession] = []
    @State private var selectedSessionID: String?
    @State private var followedLogIDs = Set<String>()
    @State private var showVMPopover = false
    @Environment(\.openWindow) private var openWindow
    // Original Kiri Moby shell: 44pt title strip, 212pt flat sidebar,
    // bottom-left VM card, toolbar with status chips and footer.
    // These are SwiftUI/AppKit views; no HTML, WKWebView or JavaScript.
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) {
                Section("资源") {
                    ForEach([Page.containers, .images, .volumes, .networks,
                             .compose, .builds], id: \.self) { page in
                        nativeSidebarItem(page)
                    }
                }
                Section("系统") {
                    nativeSidebarItem(.overview)
                    nativeSidebarItem(.settings)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarEngineStatus }
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 250)
            .navigationTitle("Kiri - Moby")
        } detail: {
            VSplitView {
                Group {
                    if !model.online && model.page != .settings {
                        ContentUnavailableView {
                            Label("Moby VM 未连接", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                        } description: {
                            Text(model.snapshot?.error ?? "启动标准 Docker Engine 后即可管理容器。")
                        } actions: {
                            Button("启动虚拟机") {
                                model.perform(["start"], title: "Start VM", showResult: false)
                            }
                        }
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 220)
                if (model.page == .containers || model.page == .compose), !sessions.isEmpty {
                    nativeConsoleDrawer
                        .frame(minHeight: 170, idealHeight: 285)
                        .environment(\.colorScheme, .dark)
                }
            }
            .navigationTitle(model.page.displayName)
            .inspector(isPresented: $showInspector) {
                ContainerInspectorView(
                    item: model.containers.first(where: { $0.Id == selectedInspectorID }))
                    .environmentObject(model)
                    .inspectorColumnWidth(min: 260, ideal: 305, max: 355)
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "搜索容器、镜像…")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showVMPopover.toggle() } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.online ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(model.online ?
                             "VM 运行中 · \(liveMemoryLabel)" : "VM 已停止")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .frame(minWidth: 122, minHeight: 24)
                }
                .buttonStyle(.bordered)
                .help("查看虚拟机 CPU、内存及快捷操作")
                .popover(isPresented: $showVMPopover) { vmResourcePopover }
            }
            ToolbarItem(placement: .automatic) {
                if model.page == .containers {
                    Menu {
                        ForEach(ContainerFilter.allCases) { filter in
                            Button(filter.rawValue) { model.containerFilter = filter }
                        }
                    } label: {
                        Label("容器状态筛选", systemImage: "line.3.horizontal.decrease")
                    }
                    Button { showInspector.toggle() } label: {
                        Label("检查器", systemImage: "sidebar.right")
                    }
                    .help(showInspector ? "隐藏容器检查器" : "显示容器检查器")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.page == .containers {
                    Button {
                        if let image = model.ask("输入要创建的容器镜像", placeholder: "nginx:alpine") {
                            model.perform(["run", image], title: "新建容器", showResult: false)
                        }
                    } label: {
                        Label("新建容器", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { model.refresh() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .frame(minWidth: 850, minHeight: 570)
        .task {
            model.begin()
            #if KIRI_UI_PREVIEW
            if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
                // Screenshot assertions must capture an active, focused Mac
                // window; unfocused macOS sidebars are intentionally dimmed.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            }
            if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" &&
               ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW_NO_FLOATING"] != "1" {
                try? await Task.sleep(for: .seconds(1))
                openConsole(.logs, containerID: "a000000000000000", name: "nginx")
                openConsole(.exec, containerID: "a000000000000000", name: "nginx")
            }
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                model.refresh()
            }
        }
        .task(id: model.page) {
            guard model.page == .containers || model.page == .compose else { return }
            while !Task.isCancelled {
                model.refreshContainerStats()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
        .onChange(of: model.page) { _, _ in model.search = "" }
        .onChange(of: selectedContainerIDs) { old, new in
            if let added = new.subtracting(old).first {
                selectedInspectorID = added
                showInspector = true
            } else if new.isEmpty {
                selectedInspectorID = nil
            } else if let current = selectedInspectorID, !new.contains(current) {
                selectedInspectorID = new.first
            }
        }
        .onChange(of: model.containers.map(\.Id)) { _, ids in
            if let current = selectedInspectorID, !ids.contains(current) {
                selectedContainerIDs.remove(current)
                selectedInspectorID = nil
            }
        }
        .task(id: model.liveLogContainerID) {
            guard let id = model.liveLogContainerID else { return }
            while !Task.isCancelled {
                await model.refreshLiveLogs(id)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
        .alert("Kiri Moby", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("确定", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .overlay {
            if let result = model.result {
                ZStack {
                    Color.black.opacity(0.52).ignoresSafeArea()
                        .onTapGesture { model.result = nil; model.liveLogContainerID = nil }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Text(result.title).font(.system(size: 14, weight: .semibold))
                            if model.liveLogContainerID != nil {
                                Label("实时刷新", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundStyle(KiriPalette.mint)
                            }
                            Spacer()
                            Text("\(result.body.utf8.count) bytes")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(KiriPalette.muted(model.isLight))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.body, forType: .string)
                                model.notify("已复制到剪贴板")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            Button("关闭") { model.result = nil; model.liveLogContainerID = nil }
                                .keyboardShortcut(.escape, modifiers: [])
                        }
                        Divider()
                        ScrollView([.vertical, .horizontal]) {
                            Text(result.body)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                    .frame(minWidth: 420, idealWidth: 650, maxWidth: 650, minHeight: 280, idealHeight: 420, maxHeight: 420)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .background(KiriPalette.panel(model.isLight))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(KiriPalette.border(model.isLight)))
                    .shadow(radius: 18)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let operation = model.operationMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(operation) 正在执行…")
                        .font(.system(size: 11))
                }
                .padding(10)
                .background(KiriPalette.panel(model.isLight))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.trailing, 16)
                .padding(.bottom, 70)
            }
            if let message = model.toastMessage {
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(12)
                    .background(model.toastIsError ?
                        KiriPalette.red.opacity(0.16) : KiriPalette.panel(model.isLight))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(model.toastIsError ? KiriPalette.red :
                            KiriPalette.border(model.isLight)))
                    .shadow(radius: 10)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private func nativeSidebarItem(_ page: Page) -> some View {
        if let count = navCount(page) {
            Label(page.displayName, systemImage: page.symbol)
                .foregroundStyle(.primary)
                .badge(count)
                .tag(page)
        } else {
            Label(page.displayName, systemImage: page.symbol)
                .foregroundStyle(.primary)
                .tag(page)
        }
    }

    private var vmResourcePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.online ? "Linux VM 运行中" : "Linux VM 已停止",
                  systemImage: "desktopcomputer")
                .font(.headline)
            Divider()
            LabeledContent("CPU", value: "\(model.snapshot?.info?.NCPU ?? 0) 核")
            LabeledContent("内存使用", value: liveMemoryLabel)
            LabeledContent("Balloon 目标", value:
                "\(model.snapshot?.memory?.balloon_target_mib ?? 0) MiB")
            LabeledContent("磁盘可用", value: diskFreeLabel)
            HStack {
                Button("资源设置") {
                    showVMPopover = false
                    model.page = .settings
                }
                Spacer()
                Button(model.online ? "重启 VM" : "启动 VM") {
                    if model.online {
                        guard model.confirm("重启 Moby VM？",
                            detail: "运行中的容器会被中断。") else { return }
                    }
                    model.perform([model.online ? "restart" : "start"],
                        title: "VM", showResult: false)
                    showVMPopover = false
                }
            }
        }
        .padding(18)
        .frame(width: 285)
    }

    private func openConsole(_ kind: ConsoleSession.Kind,
                             containerID: String, name: String) {
        let session = ConsoleSession(kind: kind, containerID: containerID, name: name)
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
        }
        selectedSessionID = session.id
        if kind == .logs { followedLogIDs.insert(session.id) }
    }

    private func sendConsoleCommand(_ command: ConsoleCommand,
                                    session: ConsoleSession) {
        NotificationCenter.default.post(name: consoleCommandNotification,
            object: session.id, userInfo: ["action": command.rawValue])
    }

    private func closeConsole(_ session: ConsoleSession) {
        sessions.removeAll { $0.id == session.id }
        followedLogIDs.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
    }

    @ViewBuilder
    private func consoleBody(_ session: ConsoleSession) -> some View {
        if session.kind == .exec {
            ExecTerminalView(containerID: session.containerID, containerName: session.name)
        } else {
            ContainerLogWindow(containerID: session.containerID, containerName: session.name)
        }
    }

    // One 34pt tab/action strip shared across Exec and Logs.
    // SwiftTerm and NSTextView render directly below without inner headers.
    private var nativeConsoleDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(sessions) { session in
                            let active = session.id == selectedSessionID
                            HStack(spacing: 7) {
                                Button {
                                    selectedSessionID = session.id
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: session.kind == .exec ?
                                            "terminal" : "doc.text")
                                        Text(session.label)
                                            .lineLimit(1)
                                            .fontWeight(active ? .medium : .regular)
                                    }
                                    .foregroundStyle(active ? .white : .secondary)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    closeConsole(session)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("关闭 \(session.label)")
                            }
                            .font(.system(size: 11))
                            .padding(.leading, 12)
                            .padding(.trailing, 8)
                            .frame(height: 31)
                            .background(active ? ConsoleAppearance.canvas :
                                Color.white.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .padding(.top, 3)
                        }
                    }
                    .padding(.leading, 7)
                }
                .frame(minWidth: 120, maxWidth: 565)
                Spacer(minLength: 6)
                if let selected = sessions.first(where: { $0.id == selectedSessionID }) {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(model.containers.first(where: {
                                $0.Id == selected.containerID
                            })?.State == "running" ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(model.containers.first(where: {
                            $0.Id == selected.containerID
                        })?.State == "running" ? "容器运行中" : "容器已停止")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Rectangle().fill(Color.white.opacity(0.15))
                            .frame(width: 1, height: 14)
                        if selected.kind == .logs {
                            Button {
                                if followedLogIDs.contains(selected.id) {
                                    followedLogIDs.remove(selected.id)
                                } else {
                                    followedLogIDs.insert(selected.id)
                                }
                                sendConsoleCommand(.toggleFollow, session: selected)
                            } label: {
                                Image(systemName: followedLogIDs.contains(selected.id) ?
                                      "pause.fill" : "play.fill")
                            }
                            .help(followedLogIDs.contains(selected.id) ?
                                  "暂停日志跟随" : "继续日志跟随")
                            Menu {
                                Button("最近 200 行") {
                                    sendConsoleCommand(.last200, session: selected)
                                }
                                Button("最近 1,000 行") {
                                    sendConsoleCommand(.last1000, session: selected)
                                }
                                Button("最近 5,000 行") {
                                    sendConsoleCommand(.last5000, session: selected)
                                }
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 18)
                            .help("日志行数")
                        }
                        Button {
                            sendConsoleCommand(.copy, session: selected)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("复制\(selected.kind == .logs ? "日志" : "所选终端文本")")
                        Button {
                            sendConsoleCommand(.clear, session: selected)
                        } label: {
                            Image(systemName: "paintbrush")
                        }
                        .help("清屏")
                        if selected.kind == .exec {
                            Button {
                                sendConsoleCommand(.interrupt, session: selected)
                            } label: {
                                Image(systemName: "stop.fill")
                            }
                            .help("中断 (Ctrl+C)")
                        }
                        Rectangle().fill(Color.white.opacity(0.15))
                            .frame(width: 1, height: 14)
                        Button {
                            openWindow(id: "container-console", value: selected)
                            closeConsole(selected)
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.up")
                        }
                        .help("在原生独立窗口打开")
                        Button {
                            sessions.removeAll()
                            selectedSessionID = nil
                            followedLogIDs.removeAll()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .help("关闭全部控制台")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                }
            }
            .frame(height: 34)
            .background(ConsoleAppearance.toolbar)
            ZStack {
                ForEach(sessions) { session in
                    consoleBody(session)
                        .opacity(selectedSessionID == session.id ? 1 : 0)
                        .allowsHitTesting(selectedSessionID == session.id)
                        .accessibilityHidden(selectedSessionID != session.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ConsoleAppearance.canvas)
        }
        .background(ConsoleAppearance.canvas)
    }

    // Native titlebar follows the reference image: branding at left, live VM
    // counters and settings at right. Values come from Docker/Guest telemetry,
    // never from a fabricated preview or hard-coded example containers.
    private var diskFreeLabel: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? NSNumber else { return "—" }
        return sizeLabel(free.int64Value)
    }

    private var liveMemoryLabel: String {
        guard model.online,
              let info = model.snapshot?.memory,
              let limit = info.vm_memory_ceiling_mib else { return "—" }
        let total = info.guest_total_kib ?? 0
        let available = info.guest_available_kib ?? 0
        let usedMiB = max(0, total - available) / 1024
        return String(format: "%.1f GB / %.1f GB",
                      Double(usedMiB) / 1024, Double(limit) / 1024)
    }

    private func navCount(_ page: Page) -> Int? {
        switch page {
        case .containers: model.containers.count
        case .images: model.images.count
        case .volumes: model.volumes.count
        case .networks: model.networks.count
        case .compose: Set(model.containers.compactMap(\.composeProject)).count
        default: nil
        }
    }

    private var vmCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(model.online ? KiriPalette.mint : KiriPalette.faint(model.isLight))
                    .frame(width: 8, height: 8)
                if !model.sidebarCollapsed {
                    Text("Linux VM").fontWeight(.semibold)
                    Spacer(minLength: 1)
                    Text(model.online ? "Running" : "Off")
                        .foregroundStyle(KiriPalette.muted(model.isLight))
                }
            }
            if !model.sidebarCollapsed {
                if model.online {
                    Text("Docker \(model.snapshot?.version?.Version ?? "—") · arm64")
                        .font(.system(size: 11))
                        .foregroundStyle(KiriPalette.faint(model.isLight)).lineLimit(1)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Running")
                        Text("CPUs")
                        Text("Balloon")
                    }.foregroundStyle(KiriPalette.muted(model.isLight))
                    Spacer(minLength: 3)
                    VStack(alignment: .trailing, spacing: 7) {
                        Text(model.online ? "\(model.containers.filter {$0.State == "running"}.count)" : "—")
                        Text(model.online ? "\(model.snapshot?.info?.NCPU ?? 4)" : "—")
                        Text(model.online ?
                             "\(model.snapshot?.memory?.balloon_target_mib ?? 0) MiB" : "—")
                    }.font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                GeometryReader { proxy in
                    let target = Double(model.snapshot?.memory?.balloon_target_mib ?? 0)
                    let total = Double(model.snapshot?.info?.MemTotal ?? 0)
                    let percent = total > 0 ? min(1, target * 1_048_576 / total) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(KiriPalette.raised(model.isLight))
                        Capsule().fill(KiriPalette.blue)
                            .frame(width: proxy.size.width * percent)
                    }
                }
                .frame(height: 4)
                Button(model.online ? "Stop" : "Start") {
                    if model.online &&
                        !model.confirm("停止 Moby VM？", detail: "运行中的容器会被停止。") { return }
                    model.perform([model.online ? "stop" : "start"],
                                  title: "VM", showResult: false)
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(KiriPalette.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .buttonStyle(.plain)
            }
        }
        .padding(model.sidebarCollapsed ? 7 : 12)
        .background(KiriPalette.panel(model.isLight))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(KiriPalette.border(model.isLight)))
    }

    // The Engine status lives in the native sidebar rather than beneath the
    // detail pane: dark Exec/Logs can touch the bottom of the main window.
    private var sidebarEngineStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 7) {
                Circle().fill(model.online ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.online ? "Engine 运行中" : "Engine 已停止")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                if let version = model.snapshot?.version?.Version {
                    Text("v" + version)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text("Kiri 私有 Docker · 默认 Context 不变")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.containers.filter { $0.State == "running" }.count) / \(model.containers.count) 个容器运行中")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .overview: overview
        case .containers: containers
        case .images: images
        case .volumes: volumes
        case .networks: networks
        case .compose: compose
        case .builds: builds
        case .settings: settings
        }
    }

    private func match(_ values: [String]) -> Bool {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    metric("容器", model.containers.count.description, "shippingbox")
                    metric("运行中", model.containers.filter {$0.State == "running"}.count.description, "checkmark.circle")
                    metric("镜像", model.images.count.description, "square.stack.3d.up")
                    metric("数据卷", model.volumes.count.description, "externaldrive")
                }
                HStack(alignment: .top) {
                    vmCard.frame(width: 240)
                    Spacer()
                }
                GroupBox("标准 Docker Engine") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("版本", value: model.snapshot?.version?.Version ?? "—")
                        LabeledContent("架构", value: model.snapshot?.info?.Architecture ?? "arm64")
                        LabeledContent("驱动", value: model.snapshot?.info?.Driver ?? "—")
                        LabeledContent("CPU", value: model.snapshot?.info?.NCPU.map(String.init) ?? "—")
                        LabeledContent("虚拟机内存上限", value: sizeLabel(model.snapshot?.info?.MemTotal))
                        LabeledContent("当前 Balloon 目标",
                            value: model.snapshot?.memory?.balloon_target_mib.map { "\($0) MiB" } ?? "—")
                    }.padding(12)
                }
                .frame(maxWidth: .infinity)
            }.padding(22)
        }
    }

    private func metric(_ title: String, _ count: String, _ icon: String) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).foregroundStyle(.secondary).font(.caption)
                    Text(count).font(.largeTitle.bold())
                }
                Spacer()
                Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private enum ContainerVisualRow: Identifiable {
        case project(String, Int, Int), container(ContainerItem, Bool)
        var id: String {
            switch self {
            case .project(let project, _, _): "project:" + project
            case .container(let c, _): "container:" + c.Id
            }
        }
    }

    private var filteredContainers: [ContainerItem] {
        model.containers.filter { item in
            model.containerFilter.includes(item)
                && match([item.title, item.Image ?? "", item.Id, item.composeProject ?? ""])
        }
    }

    // Compose project headers are ordered by the first container in the Docker
    // snapshot, exactly like the previous WebKit table.
    private var visualRows: [ContainerVisualRow] {
        let items = filteredContainers
        var visited = Set<String>()
        var result: [ContainerVisualRow] = []
        for container in items {
            if let project = container.composeProject, !project.isEmpty {
                if !visited.insert(project).inserted { continue }
                let members = items.filter { $0.composeProject == project }
                let running = members.filter { $0.State == "running" }.count
                result.append(.project(project, running, members.count))
                if !model.collapsedProjects.contains(project) {
                    result.append(contentsOf: members.map {
                        ContainerVisualRow.container($0, true)
                    })
                }
            } else {
                result.append(.container(container, false))
            }
        }
        return result
    }

    private func dateLabel(_ seconds: Int64?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func tableTitle(_ title: String, width: CGFloat) -> some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(KiriPalette.faint(model.isLight))
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 39)
    }

    private func tableValue<V: View>(_ value: V, width: CGFloat) -> some View {
        value.frame(width: width, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private var tableDivider: some View {
        Rectangle().fill(KiriPalette.border(model.isLight)).frame(height: 1)
    }

    private func smallAction(_ name: String, destructive: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(name, action: action)
            .font(.system(size: 11))
            .foregroundStyle(destructive ?
                KiriPalette.red : KiriPalette.title(model.isLight))
            .padding(.horizontal, 6).frame(height: 25)
            .background(KiriPalette.raised(model.isLight))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(KiriPalette.border(model.isLight)))
            .buttonStyle(.plain)
    }

    private func iconAction(_ tooltip: String, icon: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red : KiriPalette.title(model.isLight))
                .frame(width: 27, height: 26)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private func containerButtons(_ container: ContainerItem) -> some View {
        HStack(spacing: 5) {
            if container.State == "running" {
                iconAction("停止", icon: "stop.circle") { containerOp("stop", container) }
            } else {
                iconAction("启动", icon: "play.circle") { containerOp("start", container) }
            }
            iconAction("Exec", icon: "terminal") {
                openConsole(.exec, containerID: container.Id, name: container.title)
            }
            .disabled(container.State != "running")
            iconAction("日志", icon: "doc.text") {
                openConsole(.logs, containerID: container.Id, name: container.title)
            }
            Menu {
                Button("查看详情") {
                    model.action("inspect", fields: ["kind":"containers","id":container.Id],
                                 title: "inspect")
                }
                Button("重启") { containerOp("restart", container) }
                    .disabled(container.State != "running")
                if container.State == "running" {
                    Button("暂停") { containerOp("pause", container) }
                } else if container.State == "paused" {
                    Button("恢复") { containerOp("unpause", container) }
                }
                Divider()
                Button("删除容器", role: .destructive) {
                    if model.confirm("删除容器 \(container.title)？",
                                     detail: "不会自动删除命名数据卷。") {
                        containerOp("remove", container)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 25, height: 26)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
        }
    }

    private func containerOp(_ action: String, _ container: ContainerItem) {
        model.perform(["container", action, container.Id], title: action, showResult: false)
    }

    private func portLinks(_ ports: [PublishedPort]?) -> some View {
        HStack(spacing: 3) {
            let exposed = (ports ?? []).filter { $0.PublicPort != nil }
            if exposed.isEmpty {
                Text("—").foregroundStyle(KiriPalette.muted(model.isLight))
            }
            ForEach(Array(exposed.enumerated()), id: \.offset) { offset, port in
                if offset > 0 {
                    Text(",").foregroundStyle(KiriPalette.faint(model.isLight))
                }
                let label = "\(port.IP ?? "0.0.0.0"):\(port.PublicPort ?? 0)→\(port.PrivatePort ?? 0)/\(port.Type ?? "tcp")"
                if port.Type == "tcp", let published = port.PublicPort {
                    Button("localhost:\(String(published)) ↗") {
                        model.action("open_local", fields: [
                            "url": "http://127.0.0.1:\(published)/"
                        ], title: "open_local")
                    }
                    .foregroundStyle(KiriPalette.link(model.isLight))
                    .buttonStyle(.plain)
                    .help(label)
                } else {
                    Text(label)
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func localPortShortcut(_ container: ContainerItem) -> some View {
        Group {
            if let port = container.localPort {
                Button {
                    model.action("open_local", fields: [
                        "url": "http://127.0.0.1:\(port)/"
                    ], title: "open_local")
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KiriPalette.blue)
                }
                .buttonStyle(.plain)
                .help("打开本地端口 \(port)（非公网分享）")
            } else {
                Text("—").foregroundStyle(KiriPalette.faint(model.isLight))
            }
        }
    }

    private func containerStateBadge(_ item: ContainerItem) -> some View {
        let state = item.State ?? "unknown"
        let running = state == "running"
        return Label {
            Text(running ? "运行中" : (state == "paused" ? "已暂停" :
                 (state == "exited" || state == "created" ? "已停止" : state)))
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
        }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(running ? Color(red: 0.08, green: 0.53, blue: 0.21) :
                KiriPalette.muted(model.isLight))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(running ? Color.green.opacity(0.12) :
                Color.secondary.opacity(0.07))
            .clipShape(Capsule())
    }

    // Compact dashboard cell shared by the Containers table and the nested
    // Compose service rows. Network and disk counters are cumulative I/O;
    // CPU % and working-set memory are current sampling windows.
    @ViewBuilder
    private func containerResourceCell(_ item: ContainerItem) -> some View {
        if item.State != "running" {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(KiriPalette.faint(model.isLight))
        } else if let stats = model.containerStats[item.Id] {
            CompactContainerMetrics(stats: stats, isLight: model.isLight)
        } else {
            Text(model.statsUpdatedAt != nil ? "暂无统计" :
                 (model.statsError != nil ? "读取失败" : "采集中…"))
                .font(.system(size: 11))
                .foregroundStyle(KiriPalette.muted(model.isLight))
                .help(model.statsError ?? "等待 Docker Engine 提供容器统计数据")
        }
    }

    private func containerSelection(_ id: String) -> some View {
        Toggle("", isOn: Binding(
            get: { selectedContainerIDs.contains(id) },
            set: { enabled in
                if enabled { selectedContainerIDs.insert(id) }
                else { selectedContainerIDs.remove(id) }
            }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help("选择容器")
    }

    // SwiftUI Table maps to NSTableView on macOS: adjustable column widths,
    // keyboard navigation, native selection, heading sort, and context menus.
    private var containers: some View {
        let sorted = filteredContainers.sorted(using: tableSortOrder)
        return Table(sorted, selection: $selectedContainerIDs, sortOrder: $tableSortOrder) {
            TableColumn("名称", value: \.title) { item in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(item.State == "running" ?
                            KiriPalette.mint : KiriPalette.muted(model.isLight))
                    Text(item.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .help(item.Id)
            }
             .width(min: 120, ideal: 155)
            TableColumn("镜像", value: \.imageSortName) { item in
                Text(item.Image ?? "—").lineLimit(1)
            }
             .width(min: 95, ideal: 135)
            TableColumn("状态", value: \.stateSortName) { item in
                containerStateBadge(item)
            }
             .width(min: 75, ideal: 85)
            TableColumn("CPU / 内存") { item in
                containerResourceCell(item)
            }
             .width(min: 180, ideal: 215)
            TableColumn("端口") { item in
                portLinks(item.Ports)
            }
             .width(min: 100, ideal: 140)
            TableColumn("创建时间", value: \.creationSortDate) { item in
                Text(dateLabel(item.Created))
                    .foregroundStyle(KiriPalette.muted(model.isLight))
            }
            .width(min: 115, ideal: 135)
            TableColumn("操作") { item in
                containerButtons(item)
            }
            .width(min: 130, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if !selection.isEmpty {
                Button("启动选中的 \(selection.count) 个容器") {
                    for id in selection {
                        model.perform(["container", "start", id],
                                      title: "Start container", showResult: false)
                    }
                }
                Button("停止选中的 \(selection.count) 个容器") {
                    for id in selection {
                        model.perform(["container", "stop", id],
                                      title: "Stop container", showResult: false)
                    }
                }
                Divider()
                Button("删除选中的 \(selection.count) 个容器", role: .destructive) {
                    if model.confirm("删除所选的 \(selection.count) 个容器？",
                                     detail: "强制删除将停止并移除容器，不会自动删除命名数据卷。") {
                        for id in selection {
                            model.perform(["container", "remove", id],
                                          title: "Remove container", showResult: false)
                        }
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    // Same columns, row density and inline controls as moby.html.
    private var images: some View {
        VStack(spacing: 0) {
            HStack {
                Text("镜像").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("拉取镜像") {
                    if let name = model.ask("镜像名称", placeholder: "alpine:3.22") {
                        model.perform(["pull", name], title: "Pull image", showResult: false)
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).frame(height: 47)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        tableTitle("镜像", width: 370)
                        tableTitle("大小", width: 130)
                        tableTitle("创建时间", width: 160)
                        tableTitle("操作", width: 265)
                    }
                    tableDivider
                    ForEach(model.images.filter { match([$0.title, $0.Id]) }) { item in
                        HStack(spacing: 0) {
                            tableValue(
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.RepoTags?.joined(separator: ", ") ?? "<none>")
                                        .foregroundStyle(KiriPalette.link(model.isLight))
                                        .fontWeight(.semibold).lineLimit(2)
                                    Text(String(item.Id.dropFirst(min(item.Id.count, 7)).prefix(12)))
                                        .font(.system(size: 11))
                                        .foregroundStyle(KiriPalette.muted(model.isLight))
                                }, width: 370)
                            tableValue(Text(sizeLabel(item.Size)), width: 130)
                            tableValue(Text(dateLabel(item.Created)), width: 160)
                            tableValue(
                                HStack(spacing: 5) {
                                    smallAction("运行") {
                                        model.perform(["run", item.title], title: "Run container",
                                                      showResult: false)
                                    }
                                    smallAction("详情") {
                                        model.action("inspect",
                                            fields:["kind":"images","id":item.Id],title:"inspect")
                                    }
                                    smallAction("删除", destructive: true) {
                                        if model.confirm("确定删除镜像 \(item.title)？",
                                                         detail: "已有容器使用时 Docker 会拒绝删除。") {
                                            model.perform(["rmi", item.title], title: "Remove image",
                                                          showResult: false)
                                        }
                                    }
                                }, width: 265)
                        }.frame(minHeight: 56)
                        tableDivider
                    }
                    if model.images.isEmpty {
                        Text("暂无数据").foregroundStyle(KiriPalette.muted(model.isLight))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                }.frame(minWidth: 973)
            }
        }
    }

    private var volumes: some View {
        VStack(spacing: 0) {
            HStack {
                Text("数据卷").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("创建 Volume") {
                    if let name = model.ask("新 Volume 名称") {
                        model.action("create_volume", fields:["name":name],
                                     title:"Create volume")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).frame(height: 47)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        tableTitle("名称", width: 250)
                        tableTitle("驱动", width: 110)
                        tableTitle("路径", width: 420)
                        tableTitle("操作", width: 170)
                    }
                    tableDivider
                    ForEach(model.volumes.filter {
                        match([$0.Name, $0.Driver ?? ""])
                    }) { item in
                        HStack(spacing: 0) {
                            tableValue(
                                Text(item.Name).foregroundStyle(KiriPalette.link(model.isLight))
                                    .fontWeight(.semibold), width:250)
                            tableValue(Text(item.Driver ?? "local"), width:110)
                            tableValue(
                                Text(item.Mountpoint ?? "—")
                                    .font(.system(size: 11, design:.monospaced))
                                    .lineLimit(2), width:420)
                            tableValue(
                                HStack(spacing: 5) {
                                    smallAction("详情") {
                                        model.action("inspect",
                                            fields:["kind":"volumes","id":item.Name],title:"inspect")
                                    }
                                    smallAction("删除", destructive:true) {
                                        if model.confirm("删除 Volume \(item.Name)？",
                                                         detail:"可能永久丢失数据。") {
                                            model.perform(["rmvol",item.Name],title:"Remove volume",
                                                          showResult:false)
                                        }
                                    }
                                },width:170)
                        }.frame(minHeight: 53)
                        tableDivider
                    }
                    if model.volumes.isEmpty {
                        Text("暂无数据").foregroundStyle(KiriPalette.muted(model.isLight))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                }.frame(minWidth: 998)
            }
        }
    }

    private var networks: some View {
        VStack(spacing: 0) {
            HStack {
                Text("网络").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("创建网络") {
                    if let name = model.ask("网络名称") {
                        model.action("create_network",fields:["name":name],
                                     title:"Create network")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).frame(height: 47)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        tableTitle("网络", width: 335)
                        tableTitle("驱动", width: 170)
                        tableTitle("范围", width: 170)
                        tableTitle("操作", width: 195)
                    }
                    tableDivider
                    ForEach(model.networks.filter { match([$0.Name, $0.Id]) }) { item in
                        HStack(spacing: 0) {
                            tableValue(
                                VStack(alignment: .leading, spacing:4) {
                                    Text(item.Name).foregroundStyle(KiriPalette.link(model.isLight))
                                        .fontWeight(.semibold)
                                    Text(String(item.Id.prefix(12)))
                                        .font(.system(size: 11))
                                        .foregroundStyle(KiriPalette.muted(model.isLight))
                                },width:335)
                            tableValue(Text(item.Driver ?? "—"),width:170)
                            tableValue(Text(item.Scope ?? "—"),width:170)
                            tableValue(
                                HStack(spacing: 5) {
                                    smallAction("详情") {
                                        model.action("inspect",
                                            fields:["kind":"networks","id":item.Id],title:"inspect")
                                    }
                                    if !["bridge","host","none"].contains(item.Name) {
                                        smallAction("删除", destructive:true) {
                                            if model.confirm("确定删除网络 \(item.Name)？",
                                                             detail:"正在使用的网络无法删除。") {
                                                model.perform(["rmnet",item.Id],
                                                              title:"Remove network",showResult:false)
                                            }
                                        }
                                    }
                                },width:195)
                        }.frame(minHeight:53)
                        tableDivider
                    }
                    if model.networks.isEmpty {
                        Text("暂无数据").foregroundStyle(KiriPalette.muted(model.isLight))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                }.frame(minWidth: 918)
            }
        }
    }

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(KiriPalette.panel(model.isLight))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(KiriPalette.border(model.isLight)))
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 12))
            .foregroundStyle(KiriPalette.muted(model.isLight))
    }

    private func styledField(_ hint: String, text: Binding<String>) -> some View {
        TextField(hint, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 33)
            .background(KiriPalette.raised(model.isLight))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(KiriPalette.border(model.isLight)))
    }

    // Compose is an inventory of Docker projects, not a Compose command runner.
    // Docker's canonical compose.project/service labels are the source of truth;
    // no Compose YAML path is needed to discover existing deployments.
    private var composeProjects: [String] {
        Array(Set(model.containers.compactMap { $0.composeProject }
            .filter { !$0.isEmpty })).sorted()
    }

    private var compose: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Compose 项目")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(composeProjects.count) 个项目")
                    .foregroundStyle(KiriPalette.muted(model.isLight))
                    .font(.system(size: 11))
                Spacer()
                Text("按 Docker Compose 项目分组 · 展开查看容器")
                    .foregroundStyle(KiriPalette.muted(model.isLight))
                    .font(.system(size: 11))
                Button("刷新") { model.refresh() }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                    if composeProjects.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 28))
                            Text("暂无 Compose 项目")
                                .font(.system(size: 14, weight: .medium))
                            Text("使用 Docker Compose 创建的容器会自动按项目归类显示。")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(KiriPalette.muted(model.isLight))
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                    ForEach(composeProjects, id: \.self) { project in
                        let members = model.containers.filter { $0.composeProject == project }
                        let running = members.filter { $0.State == "running" }.count
                        let expanded = !model.collapsedProjects.contains(project)
                        VStack(spacing: 0) {
                            Button {
                                if expanded {
                                    model.collapsedProjects.insert(project)
                                } else {
                                    model.collapsedProjects.remove(project)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 14)
                                    Image(systemName: "square.3.layers.3d")
                                        .font(.system(size: 17))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("\(members.count) 个容器 · \(running) 个运行中")
                                            .font(.system(size: 11))
                                            .foregroundStyle(KiriPalette.muted(model.isLight))
                                    }
                                    Spacer()
                                    Text(running == members.count ? "运行中" :
                                         running == 0 ? "已停止" : "部分运行")
                                        .font(.system(size: 11))
                                        .foregroundStyle(running > 0 ? KiriPalette.mint :
                                            KiriPalette.muted(model.isLight))
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded {
                                tableDivider
                                HStack(spacing: 0) {
                                    tableTitle("服务 / 容器", width: 260)
                                    tableTitle("状态", width: 135)
                                    tableTitle("CPU / 内存", width: 230)
                                    tableTitle("端口", width: 165)
                                    tableTitle("操作", width: 280)
                                }
                                tableDivider
                                ForEach(members) { container in
                                    HStack(spacing: 0) {
                                        tableValue(
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(container.Labels?["com.docker.compose.service"]
                                                     ?? container.title)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(KiriPalette.link(model.isLight))
                                                Text(container.title + " · " + (container.Image ?? ""))
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(KiriPalette.muted(model.isLight))
                                                    .lineLimit(1)
                                            }, width: 260)
                                        tableValue(
                                            Text(container.Status ?? container.State ?? "—"),
                                            width: 135)
                                        tableValue(containerResourceCell(container), width: 230)
                                        tableValue(portLinks(container.Ports), width: 165)
                                        tableValue(containerButtons(container), width: 280)
                                    }
                                    .frame(minHeight: 63)
                                    tableDivider
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KiriPalette.panel(model.isLight))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(KiriPalette.border(model.isLight)))
                    }
                }
                    .padding(20)
                    .frame(minWidth: 1180, alignment: .leading)
                }
            }
        }
        .background(KiriPalette.bg(model.isLight))
    }

    private var builds: some View {
        ScrollView {
            panelCard {
                Text("Dockerfile / BuildKit").font(.system(size:14,weight:.semibold))
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment:.leading,spacing:7) {
                        fieldLabel("构建目录")
                        styledField("/Users/you/project",text:$model.buildFolder)
                        Button("选择构建目录…") { model.chooseBuildFolder() }
                            .font(.system(size:11))
                    }
                    VStack(alignment:.leading,spacing:7) {
                        fieldLabel("镜像 Tag")
                        styledField("my-app:latest",text:$model.buildTag)
                    }
                }
                fieldLabel("目标架构")
                Picker("",selection:$model.buildPlatform) {
                    Text("linux/arm64").tag("linux/arm64")
                    Text("linux/amd64").tag("linux/amd64")
                }
                .labelsHidden().frame(width:165)
                Button("构建镜像") {
                    model.action("build",fields:[
                        "path":model.buildFolder,
                        "name":model.buildTag,
                        "platform":model.buildPlatform
                    ],title:"build")
                }.buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(spacing: 14) {
                panelCard {
                    Text("Kiri Moby VM").font(.system(size:14,weight:.semibold))
                    Text("使用独立标准 Docker Engine、ext4 数据盘和私有 Docker Socket。不会覆盖 OrbStack。")
                        .foregroundStyle(KiriPalette.muted(model.isLight))
                    HStack(spacing:8) {
                        Button("启动 VM") {
                            model.perform(["start"], title:"Start VM",showResult:false)
                        }.buttonStyle(.borderedProminent)
                        Button("停止 VM") {
                            if model.confirm("停止 VM 和正在运行的容器？",
                                             detail:"Docker 容器会被停止。") {
                                model.perform(["stop"],title:"Stop VM",showResult:false)
                            }
                        }.foregroundStyle(KiriPalette.red)
                    }
                }
                panelCard {
                    HStack {
                        Text("虚拟机资源上限")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if model.resourceEditsPending {
                            Text("未保存")
                                .foregroundStyle(KiriPalette.red)
                        } else if model.resourceRestartRequired {
                            Text("等待重启生效")
                                .foregroundStyle(.orange)
                        } else {
                            Text("已保存")
                                .foregroundStyle(KiriPalette.muted(model.isLight))
                        }
                    }
                    if let config = model.snapshot?.vm_config {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(value: $model.resourceCPUs,
                                    in: 1...max(config.max_cpus, 1)) {
                                HStack {
                                    Text("CPU")
                                    Spacer()
                                    Text("\(model.resourceCPUs) 核")
                                        .fontWeight(.semibold)
                                        .monospacedDigit()
                                }
                            }
                            HStack {
                                Text("最大内存")
                                Spacer()
                                Text(String(format: "%.2f GiB", Double(model.resourceMemoryMiB) / 1024))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(model.resourceMemoryMiB) },
                                    set: { model.resourceMemoryMiB = Int($0) }),
                                in: 1024.0...Double(max(1024, config.max_memory_mib)),
                                step: 256)
                            HStack {
                                Text("1 GiB")
                                Spacer()
                                Text(String(format: "上限 %.2f GiB", Double(config.max_memory_mib) / 1024))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(KiriPalette.muted(model.isLight))
                        }
                        .font(.system(size: 12))
                        if model.online {
                            Text("当前运行：\(model.snapshot?.info?.NCPU.map(String.init) ?? "—") CPU · \(model.snapshot?.memory?.vm_memory_ceiling_mib.map { String(format: "%.2f GiB", Double($0) / 1024) } ?? "读取中") 内存上限")
                                .font(.system(size: 11))
                                .foregroundStyle(KiriPalette.muted(model.isLight))
                        }
                        HStack(spacing: 8) {
                            Button("仅保存") { model.saveResources(apply: false) }
                                .disabled(!model.resourceEditsPending)
                            Button(model.online ? "保存并重启 VM" : "保存并应用") {
                                if !model.online || model.confirm(
                                    "应用新的 CPU 和内存上限？",
                                    detail: "需要重启虚拟机。运行中的容器将被中断，容器数据卷不会删除。") {
                                    model.saveResources(apply: true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.resourceEditsPending &&
                                      !model.resourceRestartRequired)
                        }
                    } else {
                        Text("正在读取 Mac 资源限制…")
                            .foregroundStyle(KiriPalette.muted(model.isLight))
                    }
                    Text("CPU 与最大内存是 VM 启动参数，修改后需重启才能生效；运行中的内存 Balloon 仍会自动伸缩，但不会改变已启动 VM 的物理内存上限。")
                        .font(.system(size: 11))
                        .foregroundStyle(KiriPalette.muted(model.isLight))
                }
                panelCard {
                    Text("Mac 目录共享").font(.system(size:14,weight:.semibold))
                    Text("选择允许 Docker 容器访问的 Mac 项目目录；未经授权不会共享整个 /Users 或 /Volumes。更改后需要重启 VM 才能生效。")
                        .foregroundStyle(KiriPalette.muted(model.isLight))
                    if model.shares.isEmpty {
                        Text("尚未授权目录")
                            .foregroundStyle(KiriPalette.muted(model.isLight))
                    }
                    ForEach(model.shares,id:\.self) { share in
                        HStack {
                            Text(share).font(.system(size:11,design:.monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength:8)
                            smallAction("移除",destructive:true) {
                                if model.confirm("移除对 \(share) 的共享授权？",
                                                 detail:"生效前请重新启动 VM。") {
                                    model.action("remove_share",
                                                 fields:["path":share],title:"Remove share")
                                }
                            }
                        }.padding(.vertical,3)
                    }
                    HStack(spacing: 8) {
                        Button("选择共享目录…") { model.chooseShare() }
                            .buttonStyle(.borderedProminent)
                        Button("应用更改并重启 VM") {
                            if model.confirm("重启 Moby VM 以应用目录授权？",
                                             detail:"运行中的容器会被中断。") {
                                model.action("apply_shares",title:"Apply shares")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

}

@main
private struct KiriMobyNativeApp: App {
    @StateObject private var model = MobyModel()

    var body: some Scene {
        WindowGroup("Kiri Moby") {
            RootView().environmentObject(model)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)

        .commands {
            CommandMenu("Moby") {
                Button("刷新") { model.refresh() }.keyboardShortcut("r")
                Button("启动 VM") {
                    model.perform(["start"],title:"Start VM",showResult:false)
                }
                Button("停止 VM") {
                    if model.confirm("停止 VM？",detail:"运行中的容器会停止。") {
                        model.perform(["stop"],title:"Stop VM")
                    }
                }
            }
        }

        WindowGroup("容器控制台", id: "container-console", for: ConsoleSession.self) { $session in
            if let session {
                DetachedConsoleView(session: session)
            } else {
                Text("请选择一个容器会话")
            }
        }
        .defaultSize(width: 860, height: 550)

        MenuBarExtra("Kiri Moby", systemImage:"shippingbox") {
            Text(model.online ? "Moby VM Running" : "Moby VM Stopped")
            Button("刷新") { model.refresh() }
            Button(model.online ? "停止 VM" : "启动 VM") {
                model.perform([model.online ? "stop" : "start"],
                              title:"VM",showResult:false)
            }
            Divider()
            Button("显示 Kiri Moby") {
                NSApplication.shared.activate(ignoringOtherApps:true)
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("退出 Kiri Moby") { NSApplication.shared.terminate(nil) }
        }
    }
}
