// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI

// The outer NavigationSplitView intentionally stays two columns. Only the
// Containers page hosts this draggable, full-height native workspace.
enum ContainerDetailTab: String, CaseIterable, Identifiable, DetailTab {
    case overview = "Info"
    case logs = "Logs"
    case files = "Files"
    case terminal = "Terminal"
    case metrics = "Metrics"
    var id: String { rawValue }
}

/// Searchable, bounded Docker log snapshots in a padded charcoal card.
struct EmbeddedContainerLogsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let containerID: String
    let isActive: Bool
    @StateObject private var session = ContainerLogSession()
    @State private var query = ""

    private var visibleLog: String {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return session.content }
        return session.content.components(separatedBy: "\n")
            .filter { $0.localizedCaseInsensitiveContains(search) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("过滤日志", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("过滤容器日志")
                Menu {
                    Button("最近 200 行") { session.tailLines = 200 }
                    Button("最近 1,000 行") { session.tailLines = 1000 }
                    Button("最近 5,000 行") { session.tailLines = 5000 }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .help("日志行数")
                Button {
                    session.following.toggle()
                    if session.following {
                        Task { await session.refresh(containerID: containerID) }
                    }
                } label: {
                    Image(systemName: session.following ? "pause.fill" : "play.fill")
                }
                .help(session.following ? "暂停实时跟随" : "继续实时跟随")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleLog, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制可见日志")
                Button { session.clear() } label: {
                    Image(systemName: "paintbrush")
                }
                .help("清空日志显示")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(ConsoleAppearance.toolbar(colorScheme))
            Divider()
            if let error = session.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            NativeLogTextView(content: visibleLog,
                              following: session.following && query.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ConsoleAppearance.canvas(colorScheme))
        .task(id: "\(session.tailLines)-\(isActive)") {
            while !Task.isCancelled {
                if isActive && session.following {
                    await session.refresh(containerID: containerID)
                }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
    }
}

/// Per-container terminal views are cached with stable ForEach IDs. Changing
/// Overview/Logs/Terminal only changes visibility; SwiftTerm's NSView and PTY
/// are not dismantled by tab switches or by selecting another container.
struct ContainerWorkspaceDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: MobyModel
    @Environment(\.openWindow) private var openWindow
    let container: ContainerItem
    @Binding var activeTab: ContainerDetailTab
    @Binding var loadedLogIDs: Set<String>
    @Binding var loadedTerminalIDs: Set<String>
    let onAction: (String, ContainerItem) -> Void

    private func ensureCurrentSession() {
        switch activeTab {
        case .overview, .metrics, .files: break
        case .logs: loadedLogIDs.insert(container.Id)
        case .terminal:
            if container.State == "running" { loadedTerminalIDs.insert(container.Id) }
        }
    }

    private func postTerminal(_ action: ConsoleCommand, containerID: String) {
        NotificationCenter.default.post(
            name: consoleCommandNotification, object: "exec:" + containerID,
            userInfo: ["action": action.rawValue])
    }

    private struct TerminalToolbarAction: View {
        let title: String
        let symbol: String
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(hovered ? 0.065 : 0),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

    private func terminalCard(_ containerID: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.containers.first(where: { $0.Id == containerID })?.State
                          == "running" ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text("sh · 容器终端")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                TerminalToolbarAction(title: "清屏", symbol: "paintbrush") {
                    postTerminal(.clear, containerID: containerID)
                }
                .help("清屏")
                TerminalToolbarAction(title: "Ctrl+C", symbol: "stop.fill") {
                    postTerminal(.interrupt, containerID: containerID)
                }
                .help("发送 Ctrl+C")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: KiriLayoutMetrics.consoleHeaderHeight)
            .background(ConsoleAppearance.toolbar(colorScheme))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            ExecTerminalView(containerID: containerID,
                containerName: model.containers.first(where: { $0.Id == containerID })?.title
                    ?? String(containerID.prefix(12)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ConsoleAppearance.canvas(colorScheme))
    }

    var body: some View {
        ZStack {
            // Unlike PTY sessions, Info and Metrics are lightweight and
            // should only exist while visible to avoid duplicate inspect calls.
            if activeTab == .overview {
                KiriArcBoxContainerInfoTab(telemetry: model.telemetry, container: container)
            }
            if activeTab == .files {
                KiriFilesTabView(kind: "containers", id: container.Id, image: container.Image)
            }
            if activeTab == .metrics {
                ModernInspectorView(telemetry: model.telemetry,
                                    item: container, onAction: onAction)
            }

            ForEach(loadedLogIDs.sorted(), id: \.self) { id in
                EmbeddedContainerLogsView(
                    containerID: id, isActive: activeTab == .logs && container.Id == id)
                    .opacity(activeTab == .logs && container.Id == id ? 1 : 0)
                    .allowsHitTesting(activeTab == .logs && container.Id == id)
                    .accessibilityHidden(activeTab != .logs || container.Id != id)
            }
            ForEach(loadedTerminalIDs.sorted(), id: \.self) { id in
                terminalCard(id)
                    .opacity(activeTab == .terminal && container.Id == id ? 1 : 0)
                    .allowsHitTesting(activeTab == .terminal && container.Id == id)
                    .accessibilityHidden(activeTab != .terminal || container.Id != id)
            }
            if activeTab == .terminal && container.State != "running" {
                ContentUnavailableView("容器未运行", systemImage: "terminal",
                    description: Text("先启动容器，再打开交互式终端。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { ensureCurrentSession() }
        .onChange(of: activeTab) { _, _ in ensureCurrentSession() }
        .onChange(of: container.Id) { _, _ in ensureCurrentSession() }
    }
}

/// Airy, semantically colored native resource row. Stopped containers are
/// visually subdued; all actions remain accessible on hover/context menu.
struct CompactContainerRow: View {
    let item: ContainerItem
    let onAction: (String) -> Void
    @State private var hovered = false

    private var running: Bool { item.State == "running" }

    private var brand: (symbol: String, color: Color) {
        let name = (item.title + " " + (item.Image ?? "")).lowercased()
        if ["mysql", "postgres", "mariadb", "mongo"].contains(where: name.contains) {
            return ("cylinder.split.1x2", .indigo)
        }
        if ["redis", "memcached"].contains(where: name.contains) {
            return ("bolt.horizontal.circle.fill", .orange)
        }
        if ["nginx", "caddy", "traefik", "apache"].contains(where: name.contains) {
            return ("globe", .green)
        }
        return ("shippingbox.fill", .blue)
    }

    private var portHint: String? {
        item.Ports?.first(where: { $0.Type == "tcp" && $0.PublicPort != nil })
            .flatMap { $0.PublicPort.map(String.init) }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: brand.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(running ? brand.color : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    (running ? brand.color : Color.secondary).opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(running ? Color.primary : Color.secondary)
                    .lineLimit(1)
                styledImageName(item.Image ?? "—")
                    .font(.system(size: 10.5, design: .monospaced))
                    .opacity(running ? 1 : 0.62)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if hovered {
                Button {
                    onAction(running ? "stop" : "start")
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                }
                .help(running ? "停止" : "启动")
                Button { onAction("exec") } label: {
                    Image(systemName: "terminal")
                }
                .disabled(!running)
                .help("打开终端")
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(running ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    if let portHint {
                        Text(":\(portHint)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: KiriLayoutMetrics.containerRowHeight)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

