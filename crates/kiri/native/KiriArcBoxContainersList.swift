// Kiri adapts ArcBox Desktop's original AppKit container cells to the private
// Docker Engine socket. Copyright (c) 2026 ArcBox Labs; MIT, see NOTICE.
import AppKit
import Foundation
import SwiftUI

extension ContainerViewModel {
    init(kiri item: ContainerItem) {
        let state: ContainerState
        switch item.State?.lowercased() {
        case "running": state = .running
        case "restarting": state = .restarting
        case "paused": state = .paused
        case "dead", "removing": state = .dead
        default: state = .stopped
        }
        let ports: [PortMapping] = (item.Ports ?? []).compactMap { port in
            guard let internalPort = port.PrivatePort, (0...65535).contains(internalPort),
                  let externalPort = port.PublicPort, (0...65535).contains(externalPort) else { return nil }
            return PortMapping(hostPort: UInt16(externalPort), containerPort: UInt16(internalPort),
                               protocol: port.Type ?? "tcp")
        }
        self.init(
            id: item.Id, name: item.title, image: item.Image ?? "—", state: state,
            ports: ports, createdAt: Date(timeIntervalSince1970: TimeInterval(item.Created ?? 0)),
            composeProject: item.composeProject,
            composeService: item.Labels?["com.docker.compose.service"],
            labels: item.Labels ?? [:], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0
        )
    }
}

@MainActor
final class KiriArcBoxOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    var rowMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

@MainActor
private final class ArcBoxKiriNode: NSObject {
    enum Kind {
        case section(String)
        case project(String, [ContainerViewModel])
        case container(ContainerViewModel)
    }
    let kind: Kind
    let children: [ArcBoxKiriNode]
    init(_ kind: Kind, children: [ArcBoxKiriNode] = []) {
        self.kind = kind; self.children = children; super.init()
    }
}

struct KiriArcBoxContainersList: NSViewControllerRepresentable {
    let items: [ContainerItem]
    let selectedID: String?
    let collapsedProjects: Set<String>
    let onSelect: (String?) -> Void
    let onAction: (String, String) -> Void
    let onOpenPort: (Int) -> Void
    let onGroupExpansion: (String, Bool) -> Void

    func makeNSViewController(context: Context) -> KiriArcBoxContainersController {
        KiriArcBoxContainersController()
    }

    func updateNSViewController(_ controller: KiriArcBoxContainersController, context: Context) {
        controller.update(items: items.map(ContainerViewModel.init(kiri:)),
                          selectedID: selectedID, collapsed: collapsedProjects,
                          onSelect: onSelect, onAction: onAction, onOpenPort: onOpenPort,
                          onGroupExpansion: onGroupExpansion)
    }
}

@MainActor
final class KiriArcBoxContainersController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = KiriArcBoxOutlineView()
    private var roots: [ArcBoxKiriNode] = []
    private var signature = ""
    private var programmatic = false
    private var currentSelection: String?
    private var onSelect: (String?) -> Void = { _ in }
    private var onAction: (String, String) -> Void = { _, _ in }
    private var onOpenPort: (Int) -> Void = { _ in }
    private var onGroupExpansion: (String, Bool) -> Void = { _, _ in }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ArcBoxResource"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = AppMetrics.rowHeight
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .textBackgroundColor
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.rowMenu = { [weak self] row in self?.makeMenu(for: row) }
        scroll.documentView = outline
        view = scroll
    }

    func update(items: [ContainerViewModel], selectedID: String?,
                collapsed: Set<String>, onSelect: @escaping (String?) -> Void,
                onAction: @escaping (String, String) -> Void,
                onOpenPort: @escaping (Int) -> Void,
                onGroupExpansion: @escaping (String, Bool) -> Void) {
        self.onSelect = onSelect
        self.onAction = onAction
        self.onOpenPort = onOpenPort
        self.onGroupExpansion = onGroupExpansion
        let newSignature = items.map {
            [$0.id, $0.name, $0.image, $0.state.rawValue, $0.composeProject ?? "",
             $0.ports.map(\.id).joined(separator: ",")].joined(separator: "|")
        }.joined(separator: "\u{1e}") + ":" + collapsed.sorted().joined(separator: ",")
        if newSignature != signature {
            programmatic = true
            signature = newSignature
            roots = Self.makeTree(items)
            outline.reloadData()
            for section in roots {
                outline.expandItem(section)
                for node in section.children {
                    if case .project(let project, _) = node.kind,
                       !collapsed.contains(project) {
                        outline.expandItem(node)
                    }
                }
            }
            // The OutlineView may clear selection on reload; restore even when ID unchanged.
            currentSelection = nil
            programmatic = false
        }
        if currentSelection != selectedID {
            programmatic = true
            currentSelection = selectedID
            if let selectedID,
               let row = (0..<outline.numberOfRows).first(where: { i in
                   guard let node = outline.item(atRow: i) as? ArcBoxKiriNode,
                         case .container(let container) = node.kind else { return false }
                   return container.id == selectedID
               }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else { outline.deselectAll(nil) }
            programmatic = false
        }
    }

    private static func makeTree(_ items: [ContainerViewModel]) -> [ArcBoxKiriNode] {
        var result: [ArcBoxKiriNode] = []
        for running in [true, false] {
            let subset = items.filter { $0.isRunning == running }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if subset.isEmpty { continue }
            let projects = Array(Set(subset.compactMap(\.composeProject))).sorted()
            var children: [ArcBoxKiriNode] = []
            for project in projects {
                let members = subset.filter { $0.composeProject == project }
                children.append(ArcBoxKiriNode(.project(project, members), children: members.map {
                    ArcBoxKiriNode(.container($0))
                }))
            }
            children += subset.filter { $0.composeProject == nil || $0.composeProject == "" }
                .map { ArcBoxKiriNode(.container($0)) }
            result.append(ArcBoxKiriNode(.section(running ? "In Use" : "Stopped"),
                                         children: children))
        }
        return result
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ArcBoxKiriNode)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? ArcBoxKiriNode)?.children ?? roots)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as? ArcBoxKiriNode)?.children.isEmpty ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? ArcBoxKiriNode else { return false }
        if case .container = node.kind { return true }
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? ArcBoxKiriNode else { return AppMetrics.rowHeight }
        if case .section = node.kind { return 34 }
        return AppMetrics.rowHeight
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ResourceListRowView(horizontalInset: 8)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArcBoxKiriNode else { return nil }
        switch node.kind {
        case .section(let title):
            let id = NSUserInterfaceItemIdentifier("ArcBoxSection")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? NSTableCellView()
            cell.identifier = id
            let label: NSTextField
            if let old = cell.textField { label = old }
            else {
                label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
                ])
                cell.textField = label
            }
            label.stringValue = title.uppercased()
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return cell
        case .project(let project, let members):
            let id = NSUserInterfaceItemIdentifier("ArcBoxComposeCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? ContainerGroupTableCellView)
                ?? ContainerGroupTableCellView(frame: .zero)
            cell.identifier = id
            cell.configure(project: project, containers: members,
                           isExpanded: outlineView.isItemExpanded(node),
                           onToggle: { [weak self] in
                               let verb = members.contains(where: \.isRunning) ? "stop" : "start"
                               for member in members { self?.onAction(verb, member.id) }
                           }, onDelete: { [weak self] in
                               let alert = NSAlert()
                               alert.messageText = "删除 Compose 项目 \(project) 的容器？"
                               alert.informativeText = "仅删除容器，不会删除命名数据卷。"
                               alert.alertStyle = .warning
                               alert.addButton(withTitle: "删除")
                               alert.addButton(withTitle: "取消")
                               if alert.runModal() == .alertFirstButtonReturn {
                                   for member in members { self?.onAction("remove", member.id) }
                               }
                           })
            return cell
        case .container(let container):
            let id = NSUserInterfaceItemIdentifier("ArcBoxContainerCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? ContainerTableCellView)
                ?? ContainerTableCellView(frame: .zero)
            cell.identifier = id
            cell.configure(container: container, useDNS: false,
                           onOpenPort: { [weak self] port in
                               if port.protocol.lowercased() == "tcp" && port.hostPort > 0 {
                                   self?.onOpenPort(Int(port.hostPort))
                               }
                           }, onToggle: { [weak self] in
                               self?.onAction(container.isRunning ? "stop" : "start", container.id)
                           }, onDelete: { [weak self] in
                               let alert = NSAlert()
                               alert.messageText = "删除容器 \(container.name)？"
                               alert.informativeText = "不会删除命名数据卷。"
                               alert.alertStyle = .warning
                               alert.addButton(withTitle: "删除")
                               alert.addButton(withTitle: "取消")
                               if alert.runModal() == .alertFirstButtonReturn {
                                   self?.onAction("remove", container.id)
                               }
                           })
            return cell
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !programmatic, outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? ArcBoxKiriNode,
              case .container(let item) = node.kind else { return }
        if currentSelection != item.id { currentSelection = item.id; onSelect(item.id) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !programmatic,
              let node = notification.userInfo?["NSObject"] as? ArcBoxKiriNode,
              case .project(let project, _) = node.kind else { return }
        onGroupExpansion(project, false)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !programmatic,
              let node = notification.userInfo?["NSObject"] as? ArcBoxKiriNode,
              case .project(let project, _) = node.kind else { return }
        onGroupExpansion(project, true)
    }
    private func makeMenu(for row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? ArcBoxKiriNode,
              case .container(let item) = node.kind else { return nil }
        let menu = NSMenu()
        let options: [(String, String)] = [
            ("概览", "select"), ("终端", "exec"), ("日志", "logs"),
            (item.isRunning ? "停止" : "启动", item.isRunning ? "stop" : "start"),
            ("重启", "restart"), ("暂停", "pause"), ("恢复", "unpause"),
            ("删除容器", "remove")
        ]
        for (title, verb) in options {
            if verb == "pause" && !item.isRunning { continue }
            if verb == "unpause" && item.state != .paused { continue }
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ["id": item.id, "verb": verb]
            if (verb == "exec" || verb == "restart") && !item.isRunning { entry.isEnabled = false }
            if verb == "remove" { menu.addItem(.separator()) }
            menu.addItem(entry)
        }
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject as? [String: String],
              let id = obj["id"], let verb = obj["verb"] else { return }
        if verb == "select" { currentSelection = id; onSelect(id); return }
        if verb == "remove" {
            let alert = NSAlert()
            alert.messageText = "确定删除此容器？"
            alert.informativeText = "命名数据卷不会删除。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { onAction(verb, id) }
        } else { onAction(verb, id) }
    }
}
