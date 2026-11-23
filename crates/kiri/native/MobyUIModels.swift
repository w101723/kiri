// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI

enum Page: String, CaseIterable, Hashable, Identifiable {
    case overview = "总览"
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case machines = "Machines"
    case activity = "Activity"
    case compose = "Compose"
    case builds = "Builds"
    case settings = "Settings"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .overview: "Docker 引擎"
        case .containers: "容器"
        case .images: "镜像"
        case .volumes: "存储卷"
        case .networks: "网络"
        case .machines: "Linux 环境"
        case .activity: "活动监视"
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
        case .activity: "waveform.path.ecg"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .machines: "desktopcomputer"
        case .compose: "square.3.layers.3d"
        case .builds: "hammer"
        case .settings: "gearshape"
        }
    }
}

struct PublishedPort: Decodable {
    let IP: String?
    let PrivatePort: Int?
    let PublicPort: Int?
    let `Type`: String?
}

struct ContainerItem: Decodable, Identifiable {
    let Id: String
    let Names: [String]?
    let Image: String?
    let State: String?
    let Status: String?
    let Ports: [PublishedPort]?
    let Labels: [String: String]?
    let Created: Int64?
    var id: String { Id }
    var title: String { Names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String(Id.prefix(12)) }
    var composeProject: String? { Labels?["com.docker.compose.project"] }
}

struct ImageItem: Decodable, Identifiable {
    let Id: String
    let RepoTags: [String]?
    let Size: Int64?
    let Created: Int64?
    var id: String { Id }
    var title: String { RepoTags?.first(where: {$0 != "<none>:<none>"}) ?? String(Id.prefix(18)) }
}

struct VolumeItem: Decodable, Identifiable {
    let Name: String
    let Driver: String?
    let Mountpoint: String?
    var id: String { Name }
}

struct NetworkItem: Decodable, Identifiable {
    let Id: String
    let Name: String
    let Driver: String?
    let Scope: String?
    var id: String { Id }
}

struct DockerInfo: Decodable {
    let NCPU: Int?
    let MemTotal: Int64?
    let Architecture: String?
    let Driver: String?
}

struct DockerVersion: Decodable {
    let Version: String?
}

struct VmResourceSettings: Decodable {
    let cpus: Int
    let memory_mib: Int
    let max_cpus: Int
    let max_memory_mib: Int
}

struct BalloonInfo: Decodable {
    let vm_memory_ceiling_mib: Int?
    let balloon_target_mib: Int?
    let guest_available_kib: Int?
    let guest_total_kib: Int?
}

/// Aggregated from Docker /containers/{id}/stats, read-only and bounded.
struct ContainerResourceUsage: Decodable {
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

struct ContainerStatsReply: Decodable {
    let ok: Bool
    let stats: [String: ContainerResourceUsage]?
    let truncated: Bool?
    let error: String?
}

/// Typed, read-only Docker inspect payload for the selected container.
struct ContainerInspectDetails: Decodable {
    struct Configuration: Decodable {
        let Env: [String]?
        let Image: String?
        let WorkingDir: String?
        let User: String?
    }
    struct Mount: Decodable, Identifiable {
        let `Type`: String?
        let Source: String?
        let Destination: String?
        let RW: Bool?
        var id: String { (Destination ?? "") + "\u{1F}" + (Source ?? "") }
    }
    let Config: Configuration?
    let Mounts: [Mount]?
}
struct ContainerHistoryPoint: Identifiable {
    let timestamp: Date
    let cpuPercent: Double?
    let memoryPercent: Double?
    var id: Date { timestamp }
}

struct Snapshot: Decodable {
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
    let machines: [MachineItem]?
    let kubernetes: String?
}

/// One btrfs-subvolume machine from the guest controller's machine_list.
struct MachineItem: Decodable, Identifiable, Hashable {
    let name: String
    let state: String
    let distro: String?
    var id: String { name }
    var isRunning: Bool { state == "running" }
}

/// Distro presets offered when creating a machine.
enum MachineDistro: String, CaseIterable, Identifiable {
    case alpine, debian, ubuntu, fedora
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Reply: Decodable {
    let ok: Bool
    let message: String?
    let error: String?
}


/// Matches the four original Kiri container status tabs exactly.
enum ContainerFilter: String, CaseIterable, Identifiable {
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


struct TextResult: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

enum NativeError: Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let s): s
        }
    }
}

/// Native in-process Docker/VM client. No short-lived Rust subcommand per refresh.
func bridge(_ arguments: [String]) throws -> Data {
    try MobyRuntime.request(arguments)
}

func request<T: Decodable>(_ args: [String], as: T.Type) throws -> T {
    let bytes = try bridge(args)
    do {
        return try JSONDecoder().decode(T.self, from: bytes)
    } catch {
        throw NativeError.malformed("Invalid Kiri native response: \(error)")
    }
}

// CI visual reference only. This code is excluded from release builds.
// No live Docker access or synthetic data are ever used in a normal App.
