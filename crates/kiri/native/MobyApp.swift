// Kiri Moby — native SwiftUI/AppKit frontend, macOS 14+.
// AppKit/SwiftUI/SwiftTerm compose the entire UI; no embedded browser.
// Docker/VM operations use the in-process Swift HTTP-over-UDS client.
// Only the independent VM Host is a separate Swift process; Guest stays Rust.
import AppKit
import Foundation
import SwiftUI
import Charts
#if canImport(SwiftTerm)
import SwiftTerm
#endif
// SwiftTerm also declares a Color type; UI code uses SwiftUI.Color exclusively.
private typealias Color = SwiftUI.Color

/// Three-face negative-space hexagonal cube, 12.4pt tall on an 18pt
/// transparent canvas. NSImage.isTemplate lets macOS tint it automatically.
private struct RootView: View {
    @EnvironmentObject private var model: MobyModel
    @State private var selectedContainerIDs = Set<String>()
    @State private var selectedInspectorID: String?
    @State private var hoveredActionRowID: String?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var activeDetailTab: ContainerDetailTab = .overview
    @State private var loadedLogIDs = Set<String>()
    @State private var loadedTerminalIDs = Set<String>()
    @State private var showVMPopover = false
    @Environment(\.openWindow) private var openWindow
    // Three true navigation columns share a single native macOS titlebar.
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) {
                Section("Docker") {
                    ForEach([Page.containers, .volumes, .images, .builds,
                             .networks, .compose], id: \.self) { page in
                        nativeSidebarItem(page)
                    }
                }
                Section("系统") {
                    nativeSidebarItem(.overview)
                    nativeSidebarItem(.settings)
                }
            }
            .listStyle(.sidebar)
            .tint(Color.accentColor)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarEngineStatus
                    .contentShape(Rectangle())
                    .onTapGesture { showVMPopover.toggle() }
                    .popover(isPresented: $showVMPopover) { vmResourcePopover }
            }
            .navigationSplitViewColumnWidth(min: KiriLayoutMetrics.sidebarMin, ideal: KiriLayoutMetrics.sidebarIdeal, max: KiriLayoutMetrics.sidebarMax)
        } content: {
            VStack(spacing: 0) {
                if isSearching {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索容器、镜像、数据卷…", text: $model.search)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onExitCommand {
                                model.search = ""
                                isSearching = false
                            }
                        if !model.search.isEmpty {
                            Button {
                                model.search = ""
                                searchFocused = true
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("清空搜索")
                        }
                        Button("取消") {
                            model.search = ""
                            isSearching = false
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 39)
                    .background(Color(nsColor: .textBackgroundColor))
                    Divider().opacity(0.45)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.page == .containers {
                    containerList
                } else {
                    resourceNavigator
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background)
            .navigationTitle(model.page.displayName)
            .navigationSubtitle(currentPageSubtitle)
            .navigationSplitViewColumnWidth(min: KiriLayoutMetrics.contentMin, ideal: KiriLayoutMetrics.contentIdeal, max: KiriLayoutMetrics.contentMax)
            .toolbarSeparator()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if [.containers, .images, .volumes, .networks].contains(model.page) {
                        Button(action: createResource) { Image(systemName: "plus") }
                            .help("创建" + model.page.displayName)
                    }
                    if model.page == .containers {
                        Menu {
                            ForEach(ContainerFilter.allCases) { filter in
                                Button(filter.rawValue) { model.containerFilter = filter }
                            }
                        } label: {
                            Label("状态筛选", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .help("筛选容器状态")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearching.toggle()
                            if !isSearching { model.search = "" }
                        }
                        if isSearching { searchFocused = true }
                    } label: { Image(systemName: "magnifyingglass") }
                        .keyboardShortcut("f", modifiers: .command)
                        .help(isSearching ? "收起搜索" : "搜索（⌘F）")
                }
            }
        } detail: {
            Group {
                if model.page == .containers {
                    if let selected = selectedContainer {
                        ContainerWorkspaceDetail(
                            container: selected,
                            activeTab: $activeDetailTab,
                            loadedLogIDs: $loadedLogIDs,
                            loadedTerminalIDs: $loadedTerminalIDs,
                            onAction: { action, item in
                                if action == "restart" &&
                                    !model.confirm("重启 \(item.title)？",
                                        detail: "运行中的服务会短暂中断。") { return }
                                containerOp(action, item)
                            }
                        )
                        .environmentObject(model)
                    } else {
                        Text("未选择项目")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if !model.online && model.page != .settings {
                    ContentUnavailableView {
                        Label("Moby VM 未连接",
                              systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    } description: {
                        Text(model.snapshot?.error ??
                             "启动标准 Docker Engine 后即可管理容器。")
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
            .frame(minWidth: KiriLayoutMetrics.detailMin)
            .background(AppColors.sidebar)
            .toolbarSeparator()
            .toolbar {
                if model.page == .containers && selectedContainer != nil {
                    DetailTabPicker(selection: $activeDetailTab)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.page == .containers, let item = selectedContainer {
                        Button {
                            containerOp(item.State == "running" ? "stop" : "start", item)
                        } label: {
                            Image(systemName: item.State == "running" ? "stop.fill" : "play.fill")
                        }
                        .help(item.State == "running" ? "停止容器" : "启动容器")
                        Button {
                            if model.confirm("重启 \(item.title)？",
                                detail: "运行中的服务会短暂中断。") {
                                containerOp("restart", item)
                            }
                        } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(item.State != "running")
                            .help("重启容器")
                        if activeDetailTab != .overview {
                            Button {
                                let kind: ConsoleSession.Kind =
                                    activeDetailTab == .terminal ? .exec : .logs
                                openWindow(id: "container-console", value: ConsoleSession(
                                    kind: kind, containerID: item.Id, name: item.title))
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("在原生多标签窗口中弹出")
                        }
                    } else if model.page != .containers {
                        Button { model.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新资源")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .frame(minWidth: 980, minHeight: 640)
        .task {
            model.begin()
            #if KIRI_UI_PREVIEW
            if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
                let previewID = "a000000000000000"
                selectedContainerIDs = [previewID]
                selectedInspectorID = previewID
                activeDetailTab = .overview
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
        .onChange(of: model.page) { _, _ in
            model.search = ""
            isSearching = false
        }
        .onChange(of: selectedContainerIDs) { old, new in
            if let added = new.subtracting(old).first {
                selectedInspectorID = added
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
                        .onTapGesture { model.result = nil }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Text(result.title).font(.system(size: 14, weight: .semibold))
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
                            Button("关闭") { model.result = nil }
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
        let row = Label(page.displayName, systemImage: page.symbol)
        if let count = navCount(page) { row.badge(count).tag(page) }
        else { row.tag(page) }
    }

    private var vmResourcePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.online ? "Linux VM 运行中" : "Linux VM 已停止",
                  systemImage: "desktopcomputer")
                .font(.headline)
            Divider()
            Text("Kiri 私有 Docker · 默认 Context 不变")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            LabeledContent("运行中容器", value:
                "\(model.containers.filter { $0.State == "running" }.count) / \(model.containers.count)")
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
        // Quick actions in any page select the container and open its workspace.
        model.page = .containers
        selectedContainerIDs = [containerID]
        selectedInspectorID = containerID
        activeDetailTab = kind == .exec ? .terminal : .logs
        if kind == .exec { loadedTerminalIDs.insert(containerID) }
        else { loadedLogIDs.insert(containerID) }
    }

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
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            HStack(spacing: 8) {
                Circle()
                    .fill(model.online ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.online ? "Engine 运行中" : "Engine 已停止")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text(model.snapshot?.version?.Version.map { "v" + $0 } ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: KiriLayoutMetrics.sidebarStatusHeight)
        }
    }

    private var selectedContainer: ContainerItem? {
        model.containers.first(where: { $0.Id == selectedInspectorID })
    }

    private var currentPageSubtitle: String {
        switch model.page {
        case .containers:
            let running = model.containers.filter { $0.State == "running" }.count
            return "\(running) / \(model.containers.count) 运行中"
        case .images:
            let bytes = model.images.reduce(Int64(0)) { $0 + max(0, $1.Size ?? 0) }
            return "\(model.images.count) 个镜像 · \(sizeLabel(bytes)) 总计"
        case .volumes: return "\(model.volumes.count) 个数据卷"
        case .networks: return "\(model.networks.count) 个网络"
        case .compose: return "\(composeProjects.count) 个项目"
        case .builds: return "Dockerfile / BuildKit"
        case .overview: return model.online ? "标准 Docker Engine 运行中" : "引擎未启动"
        case .settings: return "虚拟机设置与目录授权"
        }
    }

    private func createResource() {
        switch model.page {
        case .containers:
            if let image = model.ask("输入要创建的容器镜像", placeholder: "nginx:alpine") {
                model.perform(["run", image], title: "新建容器", showResult: false)
            }
        case .images:
            if let name = model.ask("镜像名称", placeholder: "alpine:3.22") {
                model.perform(["pull", name], title: "Pull image", showResult: false)
            }
        case .volumes:
            if let name = model.ask("新 Volume 名称") {
                model.action("create_volume", fields: ["name": name], title: "Create volume")
            }
        case .networks:
            if let name = model.ask("网络名称") {
                model.action("create_network", fields: ["name": name], title: "Create network")
            }
        default: break
        }
    }

    // The middle column gives resources an actual navigable identity; the
    // right column retains full management controls for every existing page.
    private var resourceNavigator: some View {
        List {
            switch model.page {
            case .images:
                ForEach(model.images.filter { match([$0.title, $0.Id]) }) { item in
                    Button {
                        model.action("inspect", fields: ["kind": "images", "id": item.Id],
                                     title: "inspect")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                styledImageName(item.title)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Text(sizeLabel(item.Size))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 45, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            case .volumes:
                ForEach(model.volumes.filter { match([$0.Name, $0.Driver ?? ""]) }) { item in
                    Button {
                        model.action("inspect", fields: ["kind": "volumes", "id": item.Name],
                                     title: "inspect")
                    } label: {
                        Label(item.Name, systemImage: "externaldrive.fill")
                            .font(.system(size: 12))
                            .frame(minHeight: 45, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            case .networks:
                ForEach(model.networks.filter { match([$0.Name, $0.Id]) }) { item in
                    Button {
                        model.action("inspect", fields: ["kind": "networks", "id": item.Id],
                                     title: "inspect")
                    } label: {
                        Label(item.Name, systemImage: "network")
                            .font(.system(size: 12))
                            .frame(minHeight: 45, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            case .compose:
                ForEach(composeProjects.filter { match([$0]) }, id: \.self) { project in
                    Label(project, systemImage: "square.3.layers.3d")
                        .font(.system(size: 12))
                        .frame(minHeight: 45, alignment: .leading)
                }
            case .builds:
                Label("Dockerfile / BuildKit", systemImage: "hammer.fill")
                Label(model.buildPlatform, systemImage: "cpu")
            case .overview:
                Label("Docker Engine", systemImage: "shippingbox.fill")
                Label("VM 资源与内存", systemImage: "memorychip")
                Label("镜像和卷", systemImage: "square.stack.3d.up")
            case .settings:
                Label("虚拟机", systemImage: "cpu")
                Label("CPU 与内存", systemImage: "memorychip")
                Label("Mac 目录共享", systemImage: "folder")
            case .containers:
                EmptyView()
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .overview: overview
        case .containers: containerList
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
    // snapshot, preserving the same container ordering.
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
                .frame(width: 24, height: 25)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private func containerButtons(_ container: ContainerItem) -> some View {
        HStack(spacing: 3) {
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
                    .frame(width: 24, height: 25)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("更多操作")
        }
        .opacity(hoveredActionRowID == container.Id ? 1 : 0.65)
        .onHover { inside in
            if inside { hoveredActionRowID = container.Id }
            else if hoveredActionRowID == container.Id { hoveredActionRowID = nil }
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

    // SwiftUI observes only this cell when Docker telemetry changes.
    @ViewBuilder
    private func containerResourceCell(_ item: ContainerItem) -> some View {
        ContainerLiveMetricsView(telemetry: model.telemetry, item: item,
                                 isLight: model.isLight)
    }

    // Original ArcBox native AppKit list; Kiri's private Docker API owns the data.
    private var containerList: some View {
        ZStack {
            if model.containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text(model.online ? "Run your first container with Docker." :
                         "Start the Kiri Linux VM to manage containers.")
                } actions: {
                    Button("New Container") { createResource() }
                }
            } else {
                KiriArcBoxContainersList(
                    items: filteredContainers,
                    selectedID: selectedInspectorID,
                    collapsedProjects: model.collapsedProjects,
                    onSelect: { id in
                        selectedInspectorID = id
                        selectedContainerIDs = id.map { Set([$0]) } ?? []
                    },
                    onAction: { action, id in
                        guard let item = model.containers.first(where: { $0.Id == id }) else { return }
                        if action == "exec" { openConsole(.exec, containerID: id, name: item.title) }
                        else if action == "logs" { openConsole(.logs, containerID: id, name: item.title) }
                        else { containerOp(action, item) }
                    },
                    onOpenPort: { port in
                        model.action("open_local", fields: ["url": "http://127.0.0.1:\(port)/"],
                                     title: "open_local")
                    },
                    onGroupExpansion: { project, collapsed in
                        if collapsed { model.collapsedProjects.insert(project) }
                        else { model.collapsedProjects.remove(project) }
                    }
                )
            }
        }
        .background(AppColors.background)
    }

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
        .defaultSize(width: 1200, height: 800)
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

        MenuBarExtra {
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
        } label: {
            Image(nsImage: KiriMenuBarIcon.image)
                .renderingMode(.template)
                .opacity(model.online ? 1 : 0.42)
        }
    }
}
