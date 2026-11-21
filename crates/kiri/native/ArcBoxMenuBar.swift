// Faithful port of ArcBox Desktop's MenuBarView (260 pt popover panel:
// header + live stats tiles + metric cards + collapsible container list +
// actions) and AboutView (AppKit About panel), wired to kiri's MobyModel.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import AppKit
import SwiftUI

// MARK: - Hover button

/// ArcBox MenuBarHoverButton: plain button with a hover-highlighted rounded
/// background.
struct MenuBarHoverButton<Label: View>: View {
    var cornerRadius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Menu bar panel

/// The MenuBarExtra content: ArcBox's MenuBarView layout fed by MobyModel
/// polling (kiri has no daemon stream; counts come from the snapshot model).
struct KiriMenuBarPanel: View {
    @EnvironmentObject private var model: MobyModel

    @State private var containersExpanded = true

    var body: some View {
        mainPanel
            .padding(6)
            .animation(.easeInOut(duration: 0.2), value: containersExpanded)
            .onAppear {
                containersExpanded = hasContainers
            }
            .onChange(of: model.containers.isEmpty) { _, isEmpty in
                withAnimation(.easeInOut(duration: 0.2)) {
                    containersExpanded = !isEmpty
                }
            }
    }

    // MARK: Main panel

    var mainPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .padding(.bottom, 4)

            metricCards

            containersSection

            Divider()
                .padding(.vertical, 2)

            actionSection
        }
        .frame(width: 260)
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 12) {
            Text("Kiri Moby")
                .font(.headline)

            Spacer(minLength: 0)

            statusPill(title: daemonStateDisplay, color: daemonStateColor)
                .accessibilityLabel("引擎 \(daemonStateDisplay)")
        }
        .padding(.leading, 4)
        .padding(.horizontal, 2)
    }

    // MARK: Metric cards

    var metricCards: some View {
        HStack(spacing: 6) {
            metricCard(
                title: "容器",
                count: model.online ? model.containers.count : nil,
                symbol: "cube",
                tint: .accentColor
            ) {
                navigateToPage(.containers)
            }

            metricCard(
                title: "镜像",
                count: model.online ? model.images.count : nil,
                symbol: "circle.circle",
                tint: .indigo
            ) {
                navigateToPage(.images)
            }

            metricCard(
                title: "网络",
                count: model.online ? model.networks.count : nil,
                symbol: "point.3.filled.connected.trianglepath.dotted",
                tint: .cyan
            ) {
                navigateToPage(.networks)
            }
        }
        .padding(.bottom, 2)
    }

    func metricCard(
        title: String,
        count: Int?,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(count.map(String.init) ?? "—")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .frame(height: 70)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.30))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(count.map(String.init) ?? "Unavailable")
    }

    // MARK: Containers section

    var containersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            containersHeader

            if hasContainers {
                containerListViewport
            }
        }
    }

    var containerListViewport: some View {
        ZStack(alignment: .topLeading) {
            if containersExpanded {
                containerList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(height: containersExpanded ? containerListHeight : 0, alignment: .top)
        .clipped()
    }

    var containersHeader: some View {
        Button {
            guard hasContainers else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                containersExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cube")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)

                Text("容器")
                    .font(.system(size: 13, weight: .medium))

                Spacer(minLength: 0)

                Text(model.online ? "\(runningCount) 运行中" : "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hasContainers ? 1 : 0.35)
                    .rotationEffect(.degrees(containersExpanded && hasContainers ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        containersExpanded && hasContainers
                            ? AnyShapeStyle(.quaternary.opacity(0.30))
                            : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasContainers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("容器")
    }

    var containerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: containerRowSpacing) {
                ForEach(displayedContainers) { container in
                    containerRow(container)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: containerListHeight)
        .padding(.leading, 12)
    }

    func containerRow(_ container: ContainerItem) -> some View {
        MenuBarHoverButton {
            navigateToPage(.containers)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(container.State == "running"
                        ? AppColors.running : AppColors.stopped)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(container.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(container.State == "running" ? "运行中" : "已停止")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(height: containerRowHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(container.title), \(container.State)")
    }

    // MARK: Actions

    var actionSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuBarHoverButton(action: showMainWindow) {
                Label("显示 Kiri Moby", systemImage: "macwindow")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }

            MenuBarHoverButton {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }

            Divider()
                .padding(.vertical, 4)

            MenuBarHoverButton {
                model.perform([model.online ? "stop" : "start"], title: "VM", showResult: false)
            } label: {
                Label(model.online ? "停止 VM" : "启动 VM",
                      systemImage: model.online ? "power" : "play.fill")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }

            MenuBarHoverButton {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 Kiri Moby", systemImage: "power")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: Helpers

    var runningCount: Int {
        model.containers.filter { $0.State == "running" }.count
    }

    var hasContainers: Bool {
        !displayedContainers.isEmpty
    }

    var hasStoppedContainers: Bool {
        model.containers.contains { $0.State != "running" }
    }

    var displayedContainers: [ContainerItem] {
        model.containers.sorted { lhs, rhs in
            let lhsRunning = lhs.State == "running"
            let rhsRunning = rhs.State == "running"
            if lhsRunning != rhsRunning {
                return lhsRunning
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var containerListHeight: CGFloat {
        let rowCount = min(displayedContainers.count, maxVisibleContainerRows)
        let rowsHeight = CGFloat(rowCount) * containerRowHeight
        let spacingHeight = CGFloat(max(rowCount - 1, 0)) * containerRowSpacing
        return rowsHeight + spacingHeight
    }

    var maxVisibleContainerRows: Int { 8 }

    var containerRowHeight: CGFloat { 24 }

    var containerRowSpacing: CGFloat { 2 }

    var daemonStateDisplay: String {
        switch (model.online, model.snapshot?.error) {
        case (true, _): "运行中"
        case (false, let error?): error.isEmpty ? "已停止" : "错误"
        case (false, nil): "已停止"
        }
    }

    var daemonStateColor: Color {
        model.online ? AppColors.running : AppColors.stopped
    }

    func statusPill(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    func navigateToPage(_ page: Page) {
        model.page = page
        showMainWindow()
    }

    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first(where: { $0.title == "Kiri Moby" || $0.title.contains("Moby") })?
            .makeKeyAndOrderFront(nil)
    }
}

// MARK: - About panel

/// The custom About panel (AppKit port, upstream AboutViewController) fed
/// from kiri's bundle + guest Docker version.
@MainActor
final class KiriAboutViewController: NSViewController {
    private var currentPanel: NSPanel?

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var engineVersion: String {
        model?.snapshot?.version?.Version ?? "Unknown"
    }

    weak var model: MobyModel?

    var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var architecture: String {
        #if arch(arm64)
            return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
            return "Intel (x86_64)"
        #else
            return "Unknown"
        #endif
    }

    var systemInfo: String {
        """
        Desktop App: \(appVersion) (\(buildNumber))
        Docker Engine: \(engineVersion)
        macOS: \(macOSVersion)
        Architecture: \(architecture)
        """
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let title = label("Kiri Moby", font: .boldSystemFont(ofSize: 26), alignment: .center)
        let version = label(
            "Version \(appVersion) (\(buildNumber))",
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor,
            alignment: .center
        )
        let headerStack = NSStackView(views: [icon, title, version])
        headerStack.alignment = .centerX
        headerStack.orientation = .vertical
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let values = [
            ("Desktop App", appVersion),
            ("Docker Engine", engineVersion),
            ("macOS", macOSVersion),
            ("Architecture", architecture),
        ]
        var rows: [NSView] = []
        for (index, value) in values.enumerated() {
            rows.append(infoRow(label: value.0, value: value.1))
            if index < values.count - 1 {
                rows.append(separator())
            }
        }
        let copyButton = NSButton(
            title: "拷贝系统信息",
            target: self,
            action: #selector(copySystemInfo)
        )
        copyButton.bezelStyle = .inline
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.toolTip = "拷贝版本信息"
        let infoCard = card(containing: verticalStack(rows, spacing: 0))
        infoCard.translatesAutoresizingMaskIntoConstraints = false

        let footer = label(
            "UI 基于 ArcBox Desktop (MIT) 移植。© 2024–\(Calendar.current.component(.year, from: Date())) ArcBox Labs.",
            font: .systemFont(ofSize: 11),
            color: .tertiaryLabelColor,
            alignment: .center
        )
        footer.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = verticalStack(
            [headerStack, infoCard, footer], spacing: 20)
        documentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        view = scrollView
    }

    @objc func copySystemInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(systemInfo, forType: .string)
    }

    // Shared builders from the upstream layout.

    func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.alignment = .width
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func label(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = alignment
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func card(containing content: NSView, cornerRadius: CGFloat = 8) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = cornerRadius
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        box.contentView = content
        return box
    }

    func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func infoRow(label title: String, value: String) -> NSView {
        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .medium))
        let valueLabel = label(
            value,
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor,
            alignment: .right
        )
        valueLabel.isSelectable = true
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.orientation = .horizontal
        row.spacing = 12
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(title): \(value)")
        return padded(row, horizontal: 12, vertical: 8)
    }

    private func padded(_ content: NSView, horizontal: CGFloat, vertical: CGFloat) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
        return container
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Tracks the visible About panel to prevent duplicates (upstream
/// showAboutWindow).
@MainActor
private var currentAboutPanel: NSPanel?

@MainActor
func showKiriAboutWindow(model: MobyModel?) {
    if let existing = currentAboutPanel {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }

    let contentSize = NSSize(width: 500, height: 380)
    let panel = AboutPanel(
        contentRect: NSRect(origin: .zero, size: contentSize),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    panel.title = "关于 Kiri Moby"
    panel.isReleasedWhenClosed = false

    let controller = KiriAboutViewController()
    controller.model = model
    panel.contentViewController = controller
    panel.setContentSize(contentSize)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    currentAboutPanel = panel
}

private final class AboutPanel: NSPanel {
    override func close() {
        super.close()
        if currentAboutPanel === self {
            currentAboutPanel = nil
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
