// Kiri Moby — native SwiftUI/AppKit frontend, macOS 14+.
// No WKWebView, JavaScript runtime, web server or embedded browser.
// Docker/VM operations are delegated to the existing Rust Moby adapter
// through an exact-path, local short-lived JSON command bridge.
import AppKit
import Darwin
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

@MainActor
private final class MobyModel: ObservableObject {
    @Published var page: Page = .containers
    @Published var search = ""
    @Published var snapshot: Snapshot?
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
        let operationKey = args.joined(separator: "\u{1F}")
        let vmTransition = args.first == "start" || args.first == "stop"
            || args.first == "restart"
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
        output.append(text)
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

private struct ExecTerminalView: View {
    @StateObject private var terminal = ExecTerminalSession()
    let containerID: String
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("容器终端", systemImage: "terminal")
                    .font(.system(size: 14, weight: .semibold))
                Text(String(containerID.prefix(12)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(terminal.running ? "已连接" : "已断开")
                    .foregroundStyle(terminal.running ? .green : .secondary)
                Button("Ctrl+C") { terminal.interrupt() }
                    .disabled(!terminal.running)
                Button("清屏") { terminal.output = "" }
            }
            ScrollView {
                Text(terminal.output)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            HStack {
                TextField("输入命令，按 Return 发送", text: $terminal.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { terminal.submit() }
                    .disabled(!terminal.running)
                Button("发送") { terminal.submit() }
                    .disabled(!terminal.running)
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { terminal.start(containerID: containerID) }
        .onDisappear { terminal.close() }
    }
}

@MainActor
private func openExecTerminal(_ containerID: String) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "Kiri Moby · Exec · " + String(containerID.prefix(12))
    window.contentView = NSHostingView(rootView: ExecTerminalView(containerID: containerID))
    window.center()
    window.makeKeyAndOrderFront(nil)
}

private struct RootView: View {
    @EnvironmentObject private var model: MobyModel
    // Original Kiri Moby shell: 44pt title strip, 212pt flat sidebar,
    // bottom-left VM card, toolbar with status chips and footer.
    // These are SwiftUI/AppKit views; no HTML, WKWebView or JavaScript.
    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            Rectangle().fill(KiriPalette.border(model.isLight)).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: model.sidebarCollapsed ? 60 : 212)
                Rectangle().fill(KiriPalette.border(model.isLight)).frame(width: 1)
                VStack(spacing: 0) {
                    pageHeader
                    Rectangle().fill(KiriPalette.border(model.isLight)).frame(height: 1)
                    Group {
                        if !model.online && model.page != .settings {
                            VStack(spacing: 14) {
                                Text("Moby VM 未连接").font(.system(size: 15, weight: .semibold))
                                Text(model.snapshot?.error ??
                                     "启动标准 Docker Engine 后显示容器和镜像。")
                                    .foregroundStyle(KiriPalette.muted(model.isLight))
                                Button("启动 VM") {
                                    model.perform(["start"], title: "Start VM", showResult: false)
                                }.buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            content
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(KiriPalette.bg(model.isLight))
            }
            footer
        }
        .foregroundStyle(KiriPalette.title(model.isLight))
        .font(.system(size: 12))
        .background(KiriPalette.bg(model.isLight))
        .preferredColorScheme(model.isLight ? .light : .dark)
        .frame(minWidth: 760, minHeight: 480)
        .task {
            model.begin()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                model.refresh()
            }
        }
        .onChange(of: model.page) { _, _ in model.search = "" }
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

    private var titleStrip: some View {
        HStack(spacing: 8) {
            // Leave space for AppKit's red/yellow/green window controls.
            Color.clear.frame(width: 64, height: 1)
            Button { model.sidebarCollapsed.toggle() } label: {
                Image(systemName: "sidebar.left")
            }.help("折叠侧边栏")
            Button {} label: { Image(systemName: "chevron.left") }.disabled(true)
            Button {} label: { Image(systemName: "chevron.right") }.disabled(true)
            Spacer(minLength: 24)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(KiriPalette.muted(model.isLight))
                TextField("Search containers, images…", text: $model.search)
                    .textFieldStyle(.plain)
                Text("⌘K").font(.system(size: 11))
                    .foregroundStyle(KiriPalette.faint(model.isLight))
            }
            .padding(.horizontal, 10).frame(width: 285, height: 28)
            .background(KiriPalette.panel(model.isLight))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(KiriPalette.border(model.isLight)))
            Button { model.page = .settings } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(KiriPalette.side(model.isLight))
    }

    private func navButton(_ page: Page) -> some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .frame(width: 18)
                    .foregroundStyle(model.page == page ?
                        KiriPalette.blue : KiriPalette.muted(model.isLight))
                if !model.sidebarCollapsed {
                    Text(page.rawValue).lineLimit(1)
                    Spacer(minLength: 2)
                    if let count = navCount(page) {
                        Text("\(count)")
                            .foregroundStyle(KiriPalette.faint(model.isLight))
                    }
                }
            }
            .padding(.horizontal, model.sidebarCollapsed ? 10 : 9)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .background(model.page == page ?
                KiriPalette.raised(model.isLight) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(model.page == page ? KiriPalette.border(model.isLight) : .clear))
        }
        .buttonStyle(.plain)
        .help(page.rawValue)
    }

    private func navCount(_ page: Page) -> Int? {
        switch page {
        case .containers: model.containers.count
        case .images: model.images.count
        case .volumes: model.volumes.count
        case .networks: model.networks.count
        default: nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if !model.sidebarCollapsed {
                    Text("DOCKER")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(KiriPalette.faint(model.isLight))
                    Spacer()
                    Button { model.isLight.toggle() } label: {
                        Image(systemName: model.isLight ? "moon" : "sun.max")
                    }.buttonStyle(.plain).help("切换浅色/深色主题")
                }
            }.padding(.horizontal, 8).frame(height: 30)
            ForEach([Page.containers, .compose, .images, .volumes, .networks, .builds],
                    id: \.self) { navButton($0) }
            if !model.sidebarCollapsed {
                Text("KIRI").font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(KiriPalette.faint(model.isLight))
                    .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            } else {
                Rectangle().fill(KiriPalette.border(model.isLight))
                    .frame(height: 1).padding(.vertical, 12)
            }
            navButton(.settings)
            Spacer(minLength: 15)
            vmCard
        }
        .padding(.horizontal, model.sidebarCollapsed ? 9 : 12)
        .padding(.top, 8).padding(.bottom, 14)
        .background(KiriPalette.side(model.isLight))
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

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Text(model.page.rawValue).font(.system(size: 15, weight: .semibold))
            Text(model.online ? "Docker Engine 已连接" : "VM 未连接")
                .foregroundStyle(KiriPalette.muted(model.isLight))
                .lineLimit(1)
            Spacer(minLength: 10)
            if model.page == .containers {
                HStack(spacing: 5) {
                    ForEach(ContainerFilter.allCases) { selected in
                        let count = model.containers.filter { selected.includes($0) }.count
                        Button("\(selected.rawValue)  \(count)") {
                            model.containerFilter = selected
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(model.containerFilter == selected ?
                            KiriPalette.blue.opacity(0.15) : .clear)
                        .foregroundStyle(model.containerFilter == selected ?
                            KiriPalette.link(model.isLight) : KiriPalette.muted(model.isLight))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(model.containerFilter == selected ?
                            KiriPalette.blue : KiriPalette.border(model.isLight)))
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("刷新") { model.refresh() }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .frame(height: 55)
        .background(KiriPalette.bg(model.isLight))
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text("Kiri Moby  ·  \(model.snapshot?.version?.Version.map { "Docker \($0)" } ?? "Linux VM")"
                + "  ·  \(model.containers.filter {$0.State == "running"}.count)"
                + " of \(model.containers.count) containers running"
                + "  ·  \(model.online ? "Linux VM running" : "Linux VM offline")"
                + "  ·  OrbStack/default Docker context unchanged")
                .foregroundStyle(KiriPalette.faint(model.isLight))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(KiriPalette.side(model.isLight))
        .overlay(alignment: .top) {
            Rectangle().fill(KiriPalette.border(model.isLight)).frame(height: 1)
        }
        .font(.system(size: 11))
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
        return Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(date: .numeric, time: .omitted)
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

    private func containerButtons(_ container: ContainerItem) -> some View {
        HStack(spacing: 5) {
            if container.State == "running" {
                smallAction("停止") { containerOp("stop", container) }
                smallAction("重启") { containerOp("restart", container) }
                smallAction("暂停") { containerOp("pause", container) }
                smallAction("执行") { openExecTerminal(container.Id) }
            } else if container.State == "paused" {
                smallAction("恢复") { containerOp("unpause", container) }
            } else {
                smallAction("启动") { containerOp("start", container) }
            }
            smallAction("日志") { model.showLiveLogs(container.Id) }
            smallAction("详情") {
                model.action("inspect", fields: ["kind":"containers", "id":container.Id],
                             title: "inspect")
            }
            smallAction("删除", destructive:true) {
                if model.confirm("确定强制删除容器 \(container.title)？",
                                 detail: "这不会自动删除命名数据卷。") {
                    containerOp("remove", container)
                }
            }
        }
    }

    private func containerOp(_ action: String, _ container: ContainerItem) {
        model.perform(["container", action, container.Id], title: action, showResult: false)
    }

    private func portLinks(_ ports: [PublishedPort]?) -> some View {
        HStack(spacing: 3) {
            let exposed = (ports ?? []).filter { $0.PublicPort != nil }
            if exposed.isEmpty { Text("—").foregroundStyle(KiriPalette.muted(model.isLight)) }
            ForEach(Array(exposed.enumerated()), id: \.offset) { offset, port in
                if offset > 0 { Text(",").foregroundStyle(KiriPalette.faint(model.isLight)) }
                if port.Type == "tcp", let published = port.PublicPort {
                    Button("\(published)→\(port.PrivatePort ?? 0)") {
                        model.action("open_local",
                            fields: ["url":"http://127.0.0.1:\(published)/"],
                            title:"open_local")
                    }
                    .foregroundStyle(KiriPalette.link(model.isLight))
                    .buttonStyle(.plain)
                } else {
                    Text("\(port.PublicPort ?? 0)→\(port.PrivatePort ?? 0)/\(port.Type ?? "udp")")
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var containers: some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        tableTitle("NAME", width: 152)
                        tableTitle("STATE", width: 110)
                        tableTitle("PORTS", width: 120)
                        tableTitle("SHARE", width: 38)
                        tableTitle("SIZE", width: 62)
                        tableTitle("CREATED", width: 80)
                        tableTitle("ACTIONS", width: 280)
                    }
                    tableDivider
                    if filteredContainers.isEmpty {
                        Text(model.containers.isEmpty ? "暂无容器" : "没有符合条件的容器")
                            .foregroundStyle(KiriPalette.muted(model.isLight))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                    ForEach(visualRows) { row in
                        switch row {
                        case .project(let project, let running, let count):
                            Button {
                                if model.collapsedProjects.contains(project) {
                                    model.collapsedProjects.remove(project)
                                } else {
                                    model.collapsedProjects.insert(project)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.collapsedProjects.contains(project) ?
                                          "chevron.right" : "chevron.down")
                                    Text(project).fontWeight(.semibold)
                                    Text("\(running) / \(count) running")
                                        .foregroundStyle(KiriPalette.muted(model.isLight))
                                    Spacer()
                                }
                                .padding(.horizontal, 12).frame(height: 36)
                                .background(KiriPalette.panel(model.isLight))
                            }
                            .buttonStyle(.plain)
                            tableDivider
                        case .container(let item, let nested):
                            HStack(spacing: 0) {
                                tableValue(
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .foregroundStyle(KiriPalette.link(model.isLight))
                                            .fontWeight(.semibold)
                                        Text(item.Image ?? "—")
                                            .foregroundStyle(KiriPalette.muted(model.isLight))
                                            .font(.system(size: 11)).lineLimit(1)
                                    }
                                    .padding(.leading, nested ? 18 : 0),
                                    width: 152)
                                tableValue(
                                    HStack(spacing: 7) {
                                        Circle().fill(item.State == "running" ?
                                            KiriPalette.mint : KiriPalette.muted(model.isLight))
                                            .frame(width: 7, height: 7)
                                        Text(item.Status ?? item.State ?? "—").lineLimit(2)
                                    }, width: 110)
                                tableValue(portLinks(item.Ports), width: 120)
                                tableValue(Text("—"), width: 38)
                                tableValue(
                                    Text((item.SizeRw ?? 0) > 0 ?
                                         sizeLabel(item.SizeRw) : "—"), width: 62)
                                tableValue(Text(dateLabel(item.Created)), width: 80)
                                tableValue(containerButtons(item), width: 280)
                            }
                            .frame(minHeight: 59)
                            tableDivider
                        }
                    }
                }
                .frame(minWidth: 1010)
            }
        }
        .background(KiriPalette.bg(model.isLight))
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

    private var compose: some View {
        ScrollView {
            panelCard {
                Text("Docker Compose").font(.system(size: 14, weight:.semibold))
                fieldLabel("Compose 文件路径")
                styledField("/Users/you/project/compose.yaml", text: $model.composeFile)
                HStack(spacing: 8) {
                    Button("选择 Compose 文件") { model.chooseFile() }
                    Button("Up -d") { composeAction("compose_up") }
                        .buttonStyle(.borderedProminent)
                    Button("查看状态") { composeAction("compose_ps") }
                    Button("查看日志") { composeAction("compose_logs") }
                    Button("Down") {
                        if model.confirm("停止并删除 Compose 项目的容器？",
                                         detail:"使用 docker compose down；持久化命名数据卷不自动删除。") {
                            composeAction("compose_down")
                        }
                    }.foregroundStyle(KiriPalette.red)
                }
                Text("使用标准 Docker Compose CLI，通过 Kiri Moby 独立 Socket 运行，不修改默认 Docker Context。")
                    .foregroundStyle(KiriPalette.muted(model.isLight))
            }
            .padding(20)
        }
    }

    private func composeAction(_ operation: String) {
        model.action(operation, fields:["path":model.composeFile], title:operation)
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
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
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
