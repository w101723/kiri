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
        nameLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        symbolView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        symbolView.contentTintColor = .controlAccentColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            nameLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            subtitleLabel.textColor = selected
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7)
                : .secondaryLabelColor
        }
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
    case info = "Info"
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
                            InfoRow(label: "Tag", value: image.title)
                            InfoRow(label: "Size", value: sizeLabel(image.Size))
                            InfoRow(label: "Created",
                                    value: image.Created.map {
                                        Date(timeIntervalSince1970: TimeInterval($0)).formatted()
                                    } ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("Run Container") {
                                model.perform(["run", image.title], title: "Run container", showResult: false)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Inspect") {
                                model.action("inspect", fields: ["kind": "images", "id": image.Id],
                                             title: "inspect")
                            }
                            Button("Delete", role: .destructive) {
                                if model.confirm("Delete image \(image.title)?",
                                                 detail: "Docker refuses deletion while a container uses it.") {
                                    model.perform(["rmi", image.title], title: "Remove image", showResult: false)
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
                            InfoRow(label: "Name", value: volume.Name)
                            InfoRow(label: "Driver", value: volume.Driver ?? "local")
                            InfoRow(label: "Mountpoint", value: volume.Mountpoint ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("Inspect") {
                                model.action("inspect", fields: ["kind": "volumes", "id": volume.Name],
                                             title: "inspect")
                            }
                            Button("Delete", role: .destructive) {
                                if model.confirm("Delete volume \(volume.Name)?",
                                                 detail: "This may permanently remove stored data.") {
                                    model.perform(["rmvol", volume.Name],
                                                  title: "Remove volume", showResult: false)
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
                            InfoRow(label: "Name", value: network.Name)
                            InfoRow(label: "ID", value: network.Id)
                            InfoRow(label: "Driver", value: network.Driver ?? "—")
                            InfoRow(label: "Scope", value: network.Scope ?? "—")
                        }
                        .infoSectionStyle()
                        HStack {
                            Button("Inspect") {
                                model.action("inspect", fields: ["kind": "networks", "id": network.Id],
                                             title: "inspect")
                            }
                            if !["bridge", "host", "none"].contains(network.Name) {
                                Button("Delete", role: .destructive) {
                                    if model.confirm("Delete network \(network.Name)?",
                                                     detail: "An attached container may block deletion.") {
                                        model.perform(["rmnet", network.Id],
                                                      title: "Remove network", showResult: false)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "cube",
                    description: Text("Select a resource from the list."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.sidebar)
    }
}
