// Faithful ports of ArcBox Desktop's LocalRootFSOutline + LocalRootFSService
// (container/image Files tabs), browsed from a host-side exported rootfs tree.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import AppKit
import Foundation

enum FinderListMetrics {
    static let regularRowHeight: CGFloat = 20
    static let groupRowHeight: CGFloat = 18
}

struct LocalFileEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let sizeBytes: Int64?
    let modifiedDate: Date?
    let kind: String
    var children: [LocalFileEntry]?
    var loadError: String?

    var id: String { url.standardizedFileURL.path }
    var isExpandable: Bool { isDirectory }

    var systemImageName: String {
        switch kind {
        case "Directory": "folder"
        case "Symlink": "link"
        case "Executable": "terminal"
        default: "doc"
        }
    }

    var sizeDisplay: String {
        guard let sizeBytes else { return "" }
        return StatsFormat.bytes(UInt64(max(0, sizeBytes)))
    }

    var dateDisplay: String {
        guard let modifiedDate else { return "" }
        return LocalRootFSService.modifiedDateFormatter.string(from: modifiedDate)
    }
}

enum LocalRootFSService {
    static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceTypeKey,
        .nameKey,
    ]

    /// Whether an entry is an overlay whiteout — a character device of
    /// rdev 0:0 standing in for a name deleted in a lower layer.
    static func isWhiteout(_ url: URL, resourceType: URLFileResourceType?) -> Bool {
        guard resourceType == .characterSpecial else { return false }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_rdev == 0
    }

    static func resolveRootURL(path: String?) throws -> URL {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw KiriRootFSError.missingRootPath
        }
        let rootURL = URL(fileURLWithPath: rawPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw KiriRootFSError.pathNotFound(rootURL.path)
        }
        guard isDirectory.boolValue else {
            throw KiriRootFSError.notDirectory(rootURL.path)
        }
        return rootURL.standardizedFileURL
    }

    static func listDirectory(at directoryURL: URL, showHiddenFiles: Bool) throws -> [LocalFileEntry] {
        try listLayerItems(at: directoryURL, showHiddenFiles: showHiddenFiles)
            .map(\.entry)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One directory entry as read from a single layer, carrying the overlay
    /// bookkeeping that LayeredRootFS needs but a plain listing does not.
    struct LayerItem {
        let entry: LocalFileEntry
        let isWhiteout: Bool
    }

    static func listLayerItems(at directoryURL: URL, showHiddenFiles: Bool) throws -> [LayerItem] {
        var coordinatorError: NSError?
        var capturedError: Error?
        var entries: [LayerItem] = []

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: directoryURL, options: .withoutChanges, error: &coordinatorError) {
            coordinatedURL in
            do {
                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !showHiddenFiles {
                    options.insert(.skipsHiddenFiles)
                }

                let urls = try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: options
                )

                entries = try urls.compactMap { entryURL in
                    let values = try entryURL.resourceValues(forKeys: Self.resourceKeys)
                    if !showHiddenFiles && values.isHidden == true {
                        return nil
                    }

                    let isDirectory = values.isDirectory ?? false
                    let isSymbolicLink = values.isSymbolicLink ?? false
                    let kind = neutralKind(
                        at: entryURL,
                        isDirectory: isDirectory,
                        isSymbolicLink: isSymbolicLink
                    )

                    let entry = LocalFileEntry(
                        url: entryURL,
                        name: values.name ?? entryURL.lastPathComponent,
                        isDirectory: isDirectory,
                        isSymbolicLink: isSymbolicLink,
                        sizeBytes: isDirectory ? nil : Int64(values.fileSize ?? 0),
                        modifiedDate: values.contentModificationDate,
                        kind: kind,
                        children: nil,
                        loadError: nil
                    )
                    return LayerItem(
                        entry: entry,
                        isWhiteout: isWhiteout(entryURL, resourceType: values.fileResourceType)
                    )
                }
            } catch {
                capturedError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let capturedError {
            throw capturedError
        }

        return entries
    }

    private static func neutralKind(at url: URL, isDirectory: Bool, isSymbolicLink: Bool) -> String {
        if isSymbolicLink { return "Symlink" }
        if isDirectory { return "Directory" }

        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & 0o111 != 0 else {
            return "File"
        }
        return "Executable"
    }

    static func finderDefaultShowHiddenFiles() -> Bool {
        guard let finderDefaults = UserDefaults(suiteName: "com.apple.finder") else {
            return false
        }
        if let boolValue = finderDefaults.object(forKey: "AppleShowAllFiles") as? Bool {
            return boolValue
        }
        if let stringValue = finderDefaults.string(forKey: "AppleShowAllFiles") {
            return ["1", "true", "yes"].contains(stringValue.lowercased())
        }
        return false
    }
}

enum KiriRootFSError: LocalizedError {
    case missingRootPath
    case pathNotFound(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .missingRootPath:
            return "容器没有可用的文件系统路径。"
        case .pathNotFound(let path):
            return "路径不存在：\(path)"
        case .notDirectory(let path):
            return "路径不是目录：\(path)"
        }
    }
}

final class LocalFileNode: NSObject {
    let entry: LocalFileEntry
    weak var parent: LocalFileNode?
    var children: [LocalFileNode]?
    var isLoading = false

    init(entry: LocalFileEntry, parent: LocalFileNode?) {
        self.entry = entry
        self.parent = parent
    }

    /// The resource path represented by this node, without its host export prefix.
    func displayPath(rootPath: String) -> String {
        var components: [String] = []
        var node: LocalFileNode? = self
        while let current = node {
            components.append(current.entry.name)
            node = current.parent
        }
        return (rootPath as NSString).appendingPathComponent(
            components.reversed().joined(separator: "/"))
    }
}

final class ContextOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}
