// Native ArcBox-style resource list for Kiri Docker Images, Volumes, Networks.
// Uses ArcBox's original ResourceListRowView, AppColors and AppMetrics.
// Copyright (c) 2026 ArcBox Labs (MIT) for original ArcBox UI elements.
import AppKit
import Foundation
import SwiftUI

struct KiriArcBoxResourceEntry: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var tintColor: NSColor? = nil
    var styledImageTitle: Bool = false
}

struct KiriArcBoxResourceList: NSViewControllerRepresentable {
    let items: [KiriArcBoxResourceEntry]
    let selectedID: String?
    let onSelect: (String?) -> Void

    func makeNSViewController(context: Context) -> KiriArcBoxResourceController {
        KiriArcBoxResourceController()
    }
    func updateNSViewController(_ controller: KiriArcBoxResourceController, context: Context) {
        controller.update(items: items, selectedID: selectedID, onSelect: onSelect)
    }
}

@MainActor
private final class KiriArcBoxResourceCell: NSTableCellView {
    private let iconBox = NSBox()
    private let symbolView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var currentEntry: KiriArcBoxResourceEntry?

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconBox.boxType = .custom
        iconBox.borderWidth = 0
        iconBox.cornerRadius = 6
        iconBox.fillColor = AppColors.iconBackgroundNSColor
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        iconBox.addSubview(symbolView)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [nameLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBox)
        addSubview(labels)
        imageView = symbolView
        textField = nameLabel
        NSLayoutConstraint.activate([
            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: AppMetrics.rowIcon),
            iconBox.heightAnchor.constraint(equalToConstant: AppMetrics.rowIcon),
            symbolView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 22),
            symbolView.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ item: KiriArcBoxResourceEntry) {
        currentEntry = item
        subtitleLabel.stringValue = item.subtitle
        symbolView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)
        let tint = item.tintColor ?? .controlAccentColor
        symbolView.contentTintColor = tint
        iconBox.fillColor = tint.withAlphaComponent(0.11)
        updateTextAppearance()
    }

    private func updateTextAppearance() {
        guard let item = currentEntry else { return }
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7)
            : .secondaryLabelColor
        subtitleLabel.textColor = secondary
        if !item.styledImageTitle {
            nameLabel.stringValue = item.title
            nameLabel.textColor = primary
            return
        }

        // Work with NSString/UTF-16 ranges so registry ports and Unicode names
        // do not confuse the last slash / tag separator.
        let title = item.title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: nameLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: primary
        ]
        let styled = NSMutableAttributedString(string: item.title, attributes: attributes)
        let slash = title.range(of: "/", options: .backwards)
        let prefixEnd = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
        if prefixEnd > 0 {
            styled.addAttribute(.foregroundColor, value: secondary,
                                range: NSRange(location: 0, length: prefixEnd))
        }
        let colon = title.range(of: ":", options: .backwards)
        if colon.location != NSNotFound && colon.location >= prefixEnd {
            styled.addAttribute(.foregroundColor, value: secondary,
                                range: NSRange(location: colon.location,
                                               length: title.length - colon.location))
        }
        nameLabel.attributedStringValue = styled
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextAppearance() }
    }
}

@MainActor
final class KiriArcBoxResourceController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var items: [KiriArcBoxResourceEntry] = []
    private var selectedID: String?
    private var programmatic = false
    private var onSelect: (String?) -> Void = { _ in }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ArcBoxResource"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = AppMetrics.rowHeight
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .textBackgroundColor
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        view = scroll
    }

    func update(items: [KiriArcBoxResourceEntry], selectedID: String?,
                onSelect: @escaping (String?) -> Void) {
        self.onSelect = onSelect
        if self.items != items {
            self.items = items
            programmatic = true
            table.reloadData()
            self.selectedID = nil
            programmatic = false
        }
        if self.selectedID != selectedID {
            programmatic = true
            self.selectedID = selectedID
            if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            programmatic = false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ResourceListRowView(horizontalInset: 8)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("KiriArcBoxResourceCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? KiriArcBoxResourceCell)
            ?? KiriArcBoxResourceCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !programmatic, items.indices.contains(table.selectedRow) else { return }
        let id = items[table.selectedRow].id
        if selectedID != id { selectedID = id; onSelect(id) }
    }
}

enum KiriArcBoxResourceInfoTab: String, CaseIterable, Identifiable, DetailTab {
    case info = "详情"
    var id: String { rawValue }
}

struct KiriArcBoxResourceDetail: View {
    @EnvironmentObject private var model: MobyModel
    let page: Page
    let selectedID: String?

    var body: some View {
        Group {
            if let id = selectedID, page == .images,
               let image = model.images.first(where: { $0.Id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 0) {
                            InfoRow(label: "ID", value: image.Id)
                            InfoRow(label: "标签", value: image.title)
                            InfoRow(label: "大小", value: sizeLabel(image.Size))
                            InfoRow(label: "创建时间",
                                    value: image.Created.map {
                                        Date(timeIntervalSince1970: TimeInterval($0)).formatted()
                                    } ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("运行容器") {
                                model.perform(["run", image.title], title: "运行容器", showResult: false)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("查看详情") {
                                model.action("inspect", fields: ["kind": "images", "id": image.Id],
                                             title: "inspect")
                            }
                            Button("删除", role: .destructive) {
                                if model.confirm("删除镜像 \(image.title)？",
                                                 detail: "正在被容器使用的镜像无法删除。") {
                                    model.perform(["rmi", image.title], title: "删除镜像", showResult: false)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else if let id = selectedID, page == .volumes,
                      let volume = model.volumes.first(where: { $0.Name == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 0) {
                            InfoRow(label: "名称", value: volume.Name)
                            InfoRow(label: "驱动", value: volume.Driver ?? "local")
                            InfoRow(label: "挂载点", value: volume.Mountpoint ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("查看详情") {
                                model.action("inspect", fields: ["kind": "volumes", "id": volume.Name],
                                             title: "inspect")
                            }
                            Button("删除", role: .destructive) {
                                if model.confirm("删除存储卷 \(volume.Name)？",
                                                 detail: "此操作可能永久删除存储的数据。") {
                                    model.perform(["rmvol", volume.Name],
                                                  title: "删除存储卷", showResult: false)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else if let id = selectedID, page == .networks,
                      let network = model.networks.first(where: { $0.Id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 0) {
                            InfoRow(label: "名称", value: network.Name)
                            InfoRow(label: "ID", value: network.Id)
                            InfoRow(label: "驱动", value: network.Driver ?? "—")
                            InfoRow(label: "范围", value: network.Scope ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("查看详情") {
                                model.action("inspect", fields: ["kind": "networks", "id": network.Id],
                                             title: "inspect")
                            }
                            if !["bridge", "host", "none"].contains(network.Name) {
                                Button("删除", role: .destructive) {
                                    if model.confirm("删除网络 \(network.Name)？",
                                                     detail: "存在关联容器时无法删除此网络。") {
                                        model.perform(["rmnet", network.Id],
                                                      title: "删除网络", showResult: false)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("未选择项目", systemImage: "cube",
                    description: Text("从列表中选择一项以查看详情。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.sidebar)
    }
}
