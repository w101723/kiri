// Faithful port of ArcBox Desktop's LocalRootFSOutlineView + coordinator
// (NSOutlineView Finder-style browser). Copyright (c) 2026 ArcBox Labs; MIT.
import AppKit
import SwiftUI

struct LocalRootFSOutlineView: NSViewRepresentable {
    let rootURL: URL
    /// Layer stack to merge while browsing. `nil` browses `rootURL` alone —
    /// the plain single-directory case.
    var layers: LayeredRootFS?
    /// Semantic root shown and copied for guest files.
    var displayRootPath: String?
    let showHiddenFiles: Bool
    let reloadID: String
    @Binding var selectedPath: String?
    let onOpenURL: (URL) -> Void
    /// Reports, per listing, which layers are missing from it.
    var onExcludedLayers: ((Set<Int>) -> Void)?

    func makeCoordinator() -> LocalRootFSOutlineCoordinator {
        LocalRootFSOutlineCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
        context.coordinator.syncColumnWidthsToVisibleArea()
        context.coordinator.reloadIfNeeded()
    }
}

final class LocalRootFSOutlineCoordinator: NSObject {
    var parent: LocalRootFSOutlineView
    var rootNodes: [LocalFileNode] = []
    weak var scrollView: NSScrollView?
    var outlineView: ContextOutlineView?
    weak var nameColumn: NSTableColumn?
    weak var dateColumn: NSTableColumn?
    weak var sizeColumn: NSTableColumn?
    weak var kindColumn: NSTableColumn?
    var reloadKey: String = ""
    var generation: Int = 0
    var hasUserCustomizedColumns = false
    var isApplyingAutoColumnWidths = false

    init(parent: LocalRootFSOutlineView) {
        self.parent = parent
    }

    deinit {
        if let contentView = scrollView?.contentView {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: contentView)
            NotificationCenter.default.removeObserver(
                self, name: NSView.frameDidChangeNotification, object: contentView)
        }
        if let outlineView {
            NotificationCenter.default.removeObserver(
                self, name: NSTableView.columnDidResizeNotification, object: outlineView)
        }
    }

    func update(parent: LocalRootFSOutlineView) {
        self.parent = parent
    }

    func makeView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        let outline = ContextOutlineView(frame: .zero)
        outline.dataSource = self
        outline.delegate = self
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .controlBackgroundColor
        outline.rowSizeStyle = .small
        outline.rowHeight = FinderListMetrics.regularRowHeight
        outline.indentationPerLevel = 14
        outline.indentationMarkerFollowsCell = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.autoresizesOutlineColumn = false
        outline.floatsGroupRows = false
        outline.focusRingType = .none
        outline.autoresizingMask = [.width, .height]
        outline.setAccessibilityLabel("Files")

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "名称"
        nameColumn.minWidth = 80
        nameColumn.width = 320
        nameColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(nameColumn)
        outline.outlineTableColumn = nameColumn

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "修改日期"
        dateColumn.minWidth = 70
        dateColumn.width = 190
        dateColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(dateColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "大小"
        sizeColumn.minWidth = 60
        sizeColumn.width = 110
        sizeColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(sizeColumn)

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "种类"
        kindColumn.minWidth = 70
        kindColumn.width = 150
        kindColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(kindColumn)

        outline.doubleAction = #selector(handleDoubleClick)
        outline.target = self
        outline.menu = makeContextMenu()

        scrollView.documentView = outline
        self.scrollView = scrollView
        outlineView = outline
        self.nameColumn = nameColumn
        self.dateColumn = dateColumn
        self.sizeColumn = sizeColumn
        self.kindColumn = kindColumn

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClipViewFrameDidChange),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTableColumnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: outline)

        adjustColumnWidths(force: true)
        reloadIfNeeded(force: true)
        return scrollView
    }

    func syncColumnWidthsToVisibleArea() {
        adjustColumnWidths()
    }

    func reloadIfNeeded(force: Bool = false) {
        let newKey = "\(parent.rootURL.path)|\(parent.showHiddenFiles)|\(parent.reloadID)"
        guard force || newKey != reloadKey else { return }
        reloadKey = newKey
        hasUserCustomizedColumns = false
        adjustColumnWidths(force: true)
        loadRootNodes()
    }
}

// MARK: - Columns

extension LocalRootFSOutlineCoordinator {
    @objc func handleClipViewBoundsDidChange() {
        adjustColumnWidths()
    }

    @objc func handleClipViewFrameDidChange() {
        adjustColumnWidths()
    }

    @objc func handleTableColumnDidResize(_ notification: Notification) {
        markUserColumnCustomizationIfNeeded(from: notification)
    }

    func adjustColumnWidths(force: Bool = false) {
        if hasUserCustomizedColumns && !force {
            return
        }

        guard let outlineView,
            let scrollView = outlineView.enclosingScrollView,
            let nameColumn,
            let dateColumn,
            let sizeColumn,
            let kindColumn
        else {
            return
        }

        let visibleWidth = scrollView.contentSize.width
        guard visibleWidth > 0 else { return }

        let spacing = CGFloat(max(outlineView.numberOfColumns - 1, 0)) * outlineView.intercellSpacing.width
        let usableWidth = max(visibleWidth - spacing, 220)

        let nameWidth = floor(usableWidth * 0.38)
        let dateWidth = floor(usableWidth * 0.25)
        let sizeWidth = floor(usableWidth * 0.13)
        let kindWidth = max(usableWidth - nameWidth - dateWidth - sizeWidth, 60)

        isApplyingAutoColumnWidths = true
        nameColumn.width = nameWidth
        dateColumn.width = dateWidth
        sizeColumn.width = sizeWidth
        kindColumn.width = kindWidth
        outlineView.frame.size.width = visibleWidth
        isApplyingAutoColumnWidths = false
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        markUserColumnCustomizationIfNeeded(from: notification)
    }

    func markUserColumnCustomizationIfNeeded(from notification: Notification) {
        guard !isApplyingAutoColumnWidths else { return }

        let wasUserResize =
            (notification.userInfo?["NSTableColumnUserResized"] as? Bool)
            ?? {
                guard let eventType = NSApp.currentEvent?.type else { return false }
                return eventType == .leftMouseDragged || eventType == .leftMouseUp
            }()

        if wasUserResize {
            hasUserCustomizedColumns = true
        }
    }
}

// MARK: - Loading

extension LocalRootFSOutlineCoordinator {
    func loadRootNodes() {
        generation += 1
        let currentGeneration = generation
        let rootURL = parent.rootURL
        let layers = parent.layers
        let showHidden = parent.showHiddenFiles

        rootNodes = []
        outlineView?.reloadData()
        parent.selectedPath = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let entries: [LocalFileEntry]
            var excludedLayers: Set<Int> = []
            if let layers {
                let listing = layers.listDirectory(relativePath: "", showHiddenFiles: showHidden)
                entries = listing.entries
                excludedLayers = listing.excludedLayers
            } else {
                entries =
                    (try? LocalRootFSService.listDirectory(
                        at: rootURL, showHiddenFiles: showHidden)) ?? []
            }

            DispatchQueue.main.async {
                guard currentGeneration == self.generation else { return }
                self.parent.onExcludedLayers?(excludedLayers)
                self.rootNodes = entries.map { LocalFileNode(entry: $0, parent: nil) }
                self.outlineView?.reloadData()
                self.adjustColumnWidths(force: true)
                DispatchQueue.main.async {
                    self.adjustColumnWidths(force: true)
                }
            }
        }
    }

    func loadChildrenIfNeeded(for node: LocalFileNode) {
        guard node.entry.isExpandable, node.children == nil, !node.isLoading else { return }

        node.isLoading = true
        let currentGeneration = generation
        let layers = parent.layers
        let showHidden = parent.showHiddenFiles
        let url = node.entry.url

        DispatchQueue.global(qos: .userInitiated).async {
            let children: [LocalFileEntry]
            var excludedLayers: Set<Int> = []
            if let layers, let relativePath = layers.relativePath(forHostURL: url) {
                let listing = layers.listDirectory(
                    relativePath: relativePath, showHiddenFiles: showHidden)
                children = listing.entries
                excludedLayers = listing.excludedLayers
            } else {
                children =
                    (try? LocalRootFSService.listDirectory(at: url, showHiddenFiles: showHidden))
                    ?? []
            }

            DispatchQueue.main.async {
                guard currentGeneration == self.generation else { return }
                self.parent.onExcludedLayers?(excludedLayers)
                node.isLoading = false
                node.children = children.map { LocalFileNode(entry: $0, parent: node) }
                self.outlineView?.reloadItem(node, reloadChildren: true)
                self.adjustColumnWidths()
                DispatchQueue.main.async {
                    self.adjustColumnWidths()
                }
            }
        }
    }
}

// MARK: - Actions

extension LocalRootFSOutlineCoordinator {
    func selectedNode() -> LocalFileNode? {
        guard let outlineView else { return nil }
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? LocalFileNode
    }

    func toggleExpandOrCollapse(_ node: LocalFileNode) {
        guard let outlineView, node.entry.isExpandable else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            loadChildrenIfNeeded(for: node)
            outlineView.expandItem(node)
        }
    }

    func open(_ node: LocalFileNode) {
        if node.entry.isExpandable {
            toggleExpandOrCollapse(node)
        } else {
            parent.onOpenURL(node.entry.url)
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "打开", action: #selector(openSelectedItem), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let reveal = NSMenuItem(title: "在 Finder 中显示",
                                action: #selector(revealSelectedItem), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let copyPath = NSMenuItem(title: "拷贝路径", action: #selector(copySelectedPath), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)

        return menu
    }

    @objc func handleDoubleClick() {
        guard let node = selectedNode() else { return }
        open(node)
    }

    @objc func openSelectedItem() {
        guard let node = selectedNode() else { return }
        open(node)
    }

    @objc func revealSelectedItem() {
        guard let node = selectedNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.entry.url])
    }

    @objc func copySelectedPath() {
        guard let node = selectedNode() else { return }
        let path =
            parent.displayRootPath.map { node.displayPath(rootPath: $0) }
            ?? node.entry.url.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - Data source / delegate

extension LocalRootFSOutlineCoordinator: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? LocalFileNode {
            return node.children?.count ?? 0
        }
        return rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? LocalFileNode {
            return node.children?[index] as Any
        }
        return rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? LocalFileNode else { return false }
        return node.entry.isExpandable
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? LocalFileNode else { return }
        loadChildrenIfNeeded(for: node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = selectedNode() else {
            parent.selectedPath = nil
            return
        }
        parent.selectedPath = node.entry.id
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        self.outlineView(outlineView, isGroupItem: item)
            ? FinderListMetrics.groupRowHeight
            : FinderListMetrics.regularRowHeight
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? LocalFileNode,
            let identifier = tableColumn?.identifier.rawValue
        else {
            return nil
        }

        switch identifier {
        case "name":
            return nameCell(for: node, outlineView: outlineView)
        case "date":
            return textCell(
                outlineView: outlineView,
                identifier: "dateCell",
                text: node.entry.dateDisplay,
                alignment: .left
            )
        case "size":
            return textCell(
                outlineView: outlineView,
                identifier: "sizeCell",
                text: node.entry.sizeDisplay,
                alignment: .left
            )
        case "kind":
            return textCell(
                outlineView: outlineView,
                identifier: "kindCell",
                text: node.entry.kind,
                alignment: .left
            )
        default:
            return nil
        }
    }

    func nameCell(for node: LocalFileNode, outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("nameCell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? NSTableCellView(frame: .zero)
        cell.identifier = identifier

        if cell.imageView == nil {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.imageView?.image = NSImage(
            systemSymbolName: node.entry.systemImageName,
            accessibilityDescription: node.entry.kind
        )
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.textField?.stringValue = node.entry.name
        cell.textField?.font = .systemFont(ofSize: 12)
        return cell
    }

    func textCell(
        outlineView: NSOutlineView,
        identifier: String,
        text: String,
        alignment: NSTextAlignment
    ) -> NSView {
        let viewIdentifier = NSUserInterfaceItemIdentifier(identifier)
        let cellView: NSTableCellView
        if let reusable = outlineView.makeView(withIdentifier: viewIdentifier, owner: nil) as? NSTableCellView {
            cellView = reusable
        } else {
            let created = NSTableCellView(frame: .zero)
            created.identifier = viewIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 11)
            textField.textColor = NSColor.secondaryLabelColor
            textField.lineBreakMode = .byTruncatingTail
            created.addSubview(textField)
            created.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: created.centerYAnchor),
            ])

            cellView = created
        }

        guard let textField = cellView.textField else { return cellView }
        textField.stringValue = text
        textField.alignment = alignment
        return cellView
    }
}
