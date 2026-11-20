// Kiri Moby — native SwiftUI/AppKit frontend, macOS 14+.
// No WKWebView, JavaScript runtime, web server or embedded browser.
// Docker/VM operations are delegated to the existing Rust Moby adapter
// through an exact-path, local short-lived JSON command bridge.
import AppKit
import Foundation
import SwiftUI

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
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
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

private struct BalloonInfo: Decodable {
    let balloon_target_mib: Int?
    let guest_available_kib: Int?
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
                  options: .regularExpression) != nil)
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

@MainActor
private final class MobyModel: ObservableObject {
    @Published var page: Page = .containers
    @Published var search = ""
    @Published var snapshot: Snapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var result: TextResult?
    @Published var composeFile = ""
    @Published var buildFolder = ""
    @Published var buildTag = ""
    @Published var buildPlatform = "linux/arm64"
    @Published var isLight = false
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

    func begin() {
        guard !bootRequested else { return }
        bootRequested = true
        refresh()
        // Idempotent: if the VM is already online, Rust start_vm() is a no-op.
        perform(["start"], title: "Start VM", showResult: false)
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let answer = await Task.detached(priority: .utility) {
                Result { try request(["snapshot"], as: Snapshot.self) }
            }.value
            refreshing = false
            switch answer {
            case .success(let value): snapshot = value
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func perform(_ args: [String], title: String, showResult: Bool = true) {
        guard !busy else { return }
        busy = true
        Task {
            let answer = await Task.detached(priority: .userInitiated) {
                Result { try request(args, as: Reply.self) }
            }.value
            busy = false
            switch answer {
            case .success(let reply):
                if reply.ok {
                    if showResult {
                        result = TextResult(title: title, body: reply.message ?? "完成")
                    }
                } else {
                    error = reply.error ?? "\(title) failed"
                }
            case .failure(let failure):
                error = failure.localizedDescription
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

private struct RootView: View {
    @EnvironmentObject private var model: MobyModel
    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
                    .padding(.vertical, 5)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.page.rawValue).font(.title2.bold())
                        Text(model.online ? "Docker Engine 已连接" : "Moby VM 未连接")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let balloon = model.snapshot?.memory?.balloon_target_mib {
                        Label("\(balloon) MiB", systemImage: "memorychip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("搜索", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .disabled([Page.settings, .compose, .builds].contains(model.page))
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新")
                    Button {
                        if model.online && !model.confirm("停止 VM？", detail: "正在运行的容器也会停止。") { return }
                        model.perform([model.online ? "stop" : "start"],
                                      title: model.online ? "Stop VM" : "Start VM", showResult: false)
                    } label: {
                        Image(systemName: model.online ? "stop.fill" : "play.fill")
                    }
                    .help(model.online ? "停止 VM" : "启动 VM")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                Divider()
                Group {
                    if !model.online && ![Page.settings, .overview].contains(model.page) {
                        ContentUnavailableView("Moby VM 未连接",
                            systemImage: "shippingbox",
                            description: Text("启动标准 Docker Engine 后显示容器、镜像和数据卷"))
                            .overlay(alignment: .bottom) {
                                Button("启动 VM") {
                                    model.perform(["start"], title: "Start VM", showResult: false)
                                }.buttonStyle(.borderedProminent).padding(.bottom, 70)
                            }
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 540)
        .task {
            model.begin()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                model.refresh()
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
        .sheet(item: $model.result) { result in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(result.title).font(.title3.bold())
                    Spacer()
                    Button("关闭") { model.result = nil }
                }
                ScrollView {
                    Text(result.body).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(minWidth: 600, minHeight: 390)
        }
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

    private var containers: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.containers.count) 个容器").foregroundStyle(.secondary)
                Spacer()
                Button("运行镜像") {
                    if let name = model.ask("运行镜像", placeholder: "alpine:3.22") {
                        model.perform(["run", name], title: "Run container")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(16)
            List {
                ForEach(model.containers.filter {
                    match([$0.title, $0.Image ?? "", $0.Id, $0.composeProject ?? ""])
                }) { container in
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(container.State == "running" ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(container.title).fontWeight(.semibold)
                            Text(container.Image ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 15)
                        Text(container.Status ?? container.State ?? "—")
                            .foregroundStyle(container.State == "running" ? .green : .secondary)
                            .font(.caption)
                        if let port = container.localPort {
                            Button(":\(port)") {
                                model.action("open_local",
                                    fields: ["url":"http://127.0.0.1:\(port)/"], title: "Open port")
                            }.buttonStyle(.link).font(.caption)
                        }
                        Menu {
                            Button("详情") { model.action("inspect",
                                fields: ["kind":"containers", "id":container.Id], title: "Inspect") }
                            Button("日志") { model.action("logs",
                                fields: ["id":container.Id], title: "Logs") }
                            Button("执行命令") {
                                if let command = model.ask("执行 Shell 命令", placeholder: "pwd") {
                                    model.action("exec",
                                        fields: ["id":container.Id, "command":command], title: "Exec")
                                }
                            }
                            Divider()
                            ForEach(["start","stop","restart","pause","unpause"], id: \.self) { operation in
                                Button(operation.capitalized) {
                                    model.perform(["container",operation,container.Id],
                                                  title: operation.capitalized)
                                }
                            }
                            Divider()
                            Button("删除容器", role: .destructive) {
                                if model.confirm("删除 \(container.title)？",
                                    detail: "将强制删除此容器；命名数据卷不会自动删除。") {
                                    model.perform(["container","remove",container.Id],title:"Remove")
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .frame(width: 30)
                    }.padding(.vertical, 7)
                }
            }.listStyle(.inset)
        }
    }

    private var images: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.images.count) 个镜像").foregroundStyle(.secondary)
                Spacer()
                Button("拉取镜像") {
                    if let name = model.ask("拉取 Docker 镜像", placeholder: "alpine:3.22") {
                        model.perform(["pull",name], title: "Pull image")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(16)
            List(model.images.filter { match([$0.title, $0.Id]) }) { image in
                HStack {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.secondary)
                    VStack(alignment:.leading) {
                        Text(image.title).fontWeight(.medium)
                        Text(String(image.Id.prefix(22))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sizeLabel(image.Size)).font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("运行") { model.perform(["run",image.title], title:"Run container") }
                        Button("详情") {
                            model.action("inspect",
                                fields:["kind":"images","id":image.Id],title:"Inspect image")
                        }
                        Divider()
                        Button("删除", role:.destructive) {
                            if model.confirm("删除镜像？",detail:image.title) {
                                model.perform(["rmi",image.Id],title:"Remove image")
                            }
                        }
                    } label: { Image(systemName:"ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width:30)
                }.padding(.vertical,7)
            }.listStyle(.inset)
        }
    }

    private var volumes: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.volumes.count) 个数据卷").foregroundStyle(.secondary)
                Spacer()
                Button("创建 Volume") {
                    if let name = model.ask("新 Volume 名称") {
                        model.action("create_volume",fields:["name":name],title:"Create volume")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(16)
            List(model.volumes.filter { match([$0.Name,$0.Mountpoint ?? ""]) }) { item in
                HStack {
                    Image(systemName:"externaldrive").foregroundStyle(.secondary)
                    VStack(alignment:.leading) {
                        Text(item.Name).fontWeight(.medium)
                        Text(item.Mountpoint ?? "local")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(item.Driver ?? "local").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("详情") {
                            model.action("inspect",
                                fields:["kind":"volumes","id":item.Name],title:"Inspect volume")
                        }
                        Button("删除",role:.destructive) {
                            if model.confirm("删除 Volume \(item.Name)？",
                                detail:"此操作可能永久删除数据。") {
                                model.perform(["rmvol",item.Name],title:"Remove volume")
                            }
                        }
                    } label: { Image(systemName:"ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width:30)
                }.padding(.vertical,7)
            }.listStyle(.inset)
        }
    }

    private var networks: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.networks.count) 个网络").foregroundStyle(.secondary)
                Spacer()
                Button("创建网络") {
                    if let name = model.ask("新网络名称") {
                        model.action("create_network",fields:["name":name],title:"Create network")
                    }
                }.buttonStyle(.borderedProminent)
            }.padding(16)
            List(model.networks.filter { match([$0.Name,$0.Id]) }) { item in
                HStack {
                    Image(systemName:"network").foregroundStyle(.secondary)
                    Text(item.Name).fontWeight(.medium)
                    Spacer()
                    Text(item.Driver ?? "bridge").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("详情") {
                            model.action("inspect",
                                fields:["kind":"networks","id":item.Id],title:"Inspect network")
                        }
                        Button("删除",role:.destructive) {
                            if model.confirm("删除网络 \(item.Name)？",
                                detail:"正在使用的网络无法删除。") {
                                model.perform(["rmnet",item.Id],title:"Remove network")
                            }
                        }
                    } label: { Image(systemName:"ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width:30)
                }.padding(.vertical,7)
            }.listStyle(.inset)
        }
    }

    private var compose: some View {
        Form {
            Section("Docker Compose") {
                HStack {
                    TextField("Compose .yaml/.yml 文件", text:$model.composeFile)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { model.chooseFile() }
                }
                HStack {
                    Button("Up -d") { composeAction("compose_up") }
                        .buttonStyle(.borderedProminent)
                    Button("Down") {
                        if model.confirm("停止 Compose 项目？",detail:"将停止并删除项目容器。") {
                            composeAction("compose_down")
                        }
                    }
                    Button("PS") { composeAction("compose_ps") }
                    Button("Logs") { composeAction("compose_logs") }
                }
                Text("通过已安装的 Docker Compose 插件执行；不会修改默认 Docker Context。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func composeAction(_ operation: String) {
        model.action(operation,fields:["path":model.composeFile],title:operation)
    }

    private var builds: some View {
        Form {
            Section("Docker Buildx") {
                HStack {
                    TextField("构建目录",text:$model.buildFolder)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { model.chooseBuildFolder() }
                }
                TextField("镜像标签",text:$model.buildTag,prompt:Text("my-app:latest"))
                Picker("目标架构",selection:$model.buildPlatform) {
                    Text("linux/arm64").tag("linux/arm64")
                    Text("linux/amd64").tag("linux/amd64")
                }
                Button("构建镜像") {
                    model.action("build",fields:[
                        "path":model.buildFolder,
                        "name":model.buildTag,
                        "platform":model.buildPlatform
                    ],title:"Buildx")
                }.buttonStyle(.borderedProminent)
                Text("使用标准 Docker Buildx --load。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var settings: some View {
        Form {
            Section("Kiri Moby VM") {
                HStack {
                    Button("启动 VM") { model.perform(["start"],title:"Start VM",showResult:false) }
                    Button("停止 VM") {
                        if model.confirm("停止 VM？",detail:"将停止正在运行的容器。") {
                            model.perform(["stop"],title:"Stop VM")
                        }
                    }
                    Button("重启 VM") {
                        if model.confirm("重启 VM？",detail:"正在运行的容器会暂时中断。") {
                            model.perform(["restart"],title:"Restart VM")
                        }
                    }
                }
                LabeledContent("VM 状态",value:model.online ? "Running" : "Stopped")
                LabeledContent("Balloon 目标",
                    value:model.snapshot?.memory?.balloon_target_mib.map { "\($0) MiB" } ?? "—")
            }
            Section("Mac 目录共享") {
                ForEach(model.shares,id:\.self) { share in
                    HStack {
                        Text(share).textSelection(.enabled)
                        Spacer()
                        Button("移除",role:.destructive) {
                            model.action("remove_share",fields:["path":share],title:"Remove share")
                        }
                    }
                }
                HStack {
                    Button("授权目录…") { model.chooseShare() }
                    Button("应用共享变更（重启 VM）") {
                        if model.confirm("应用目录共享？",detail:"将重启 Linux VM。") {
                            model.action("apply_shares",title:"Apply shares")
                        }
                    }
                }
                Text("只共享显式授权的 /Users 或 /Volumes 项目目录；不会自动共享整个 Mac。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

@main
private struct KiriMobyNativeApp: App {
    @StateObject private var model = MobyModel()

    var body: some Scene {
        WindowGroup("Kiri Moby") {
            RootView().environmentObject(model)
        }
        .defaultSize(width: 1130, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
