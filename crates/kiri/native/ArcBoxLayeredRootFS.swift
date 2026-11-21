// Faithful ports of ArcBox Desktop's LayeredRootFS / LayerStack /
// LayerMergeBadge. Kiri browses a host-side exported rootfs tree produced by
// the Docker CLI bridge (`ArcBoxRootfsExport`), so a stack has a single
// merged layer in the common case; the overlay merge logic is kept verbatim
// so layered exports behave exactly as upstream.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import Foundation

/// Browses an overlay layer stack as one merged filesystem.
struct LayeredRootFS {
    /// Layer directories, highest precedence first — the order overlayfs
    /// encodes as `upperdir` then `lowerdir=A:B:C`.
    let layers: [URL]

    init?(layers: [URL]) {
        guard !layers.isEmpty else { return nil }
        self.layers = layers
    }

    /// The merged contents of one directory, plus which layers are missing
    /// from it.
    struct Listing {
        let entries: [LocalFileEntry]
        let excludedLayers: Set<Int>
    }

    func listDirectory(relativePath: String, showHiddenFiles: Bool) -> Listing {
        var listings: [[LocalRootFSService.LayerItem]] = []
        var excluded: Set<Int> = []

        for (index, layer) in layers.enumerated() {
            let directory = Self.resolve(relativePath, in: layer)
            do {
                listings.append(try LocalRootFSService.listLayerItems(
                    at: directory, showHiddenFiles: showHiddenFiles))
            } catch {
                switch Self.fileType(of: directory) {
                case nil where Self.fileType(of: layer) != nil:
                    continue
                case .some(let type) where type != S_IFDIR:
                    return Listing(entries: Self.merge(listings), excludedLayers: excluded)
                default:
                    excluded.formUnion(index..<layers.count)
                }
                break
            }
        }

        return Listing(entries: Self.merge(listings), excludedLayers: excluded)
    }

    /// Maps a host URL that came out of `listDirectory` back to its path
    /// relative to the stack root, so expanding a node can re-merge across
    /// every layer rather than only the one the node happened to come from.
    func relativePath(forHostURL url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for layer in layers {
            let base = layer.standardizedFileURL.path
            if path == base {
                return ""
            }
            if path.hasPrefix(base + "/") {
                return String(path.dropFirst(base.count + 1))
            }
        }
        return nil
    }

    /// Merges per-layer listings, highest layer first.
    ///
    /// The first layer to name an entry decides it: a regular entry is taken
    /// as-is, a whiteout deletes the name for every layer below (and is
    /// itself hidden, being overlay bookkeeping rather than content).
    static func merge(_ listings: [[LocalRootFSService.LayerItem]]) -> [LocalFileEntry] {
        var decided: Set<String> = []
        var merged: [LocalFileEntry] = []

        for listing in listings {
            for item in listing {
                guard decided.insert(item.entry.name).inserted else { continue }
                if !item.isWhiteout {
                    merged.append(item.entry)
                }
            }
        }

        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func resolve(_ relativePath: String, in layer: URL) -> URL {
        relativePath.isEmpty ? layer : layer.appending(path: relativePath, directoryHint: .inferFromPath)
    }

    /// The `S_IFMT` bits at `url`, or `nil` if nothing is there.
    ///
    /// Deliberately `lstat`: a symlink is a non-directory to overlayfs and
    /// shadows lower layers, and following it here would merge past it.
    private static func fileType(of url: URL) -> mode_t? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return status.st_mode & S_IFMT
    }
}

/// What a Files tab is browsing, and how much of it is missing.
struct LayerStack {
    private(set) var layers: LayeredRootFS?
    private(set) var rootURL: URL?
    private(set) var reportedLayers = 0
    private(set) var excludedIndices: Set<Int> = []
    private(set) var unbrowsableLayers = 0

    var missingLayers: Int { excludedIndices.count + unbrowsableLayers }

    var describesAStack: Bool { rootURL != nil && reportedLayers > 1 }

    enum Unresolved: Equatable {
        case noPaths
        case outsideExport
        case exportUnavailable
    }

    /// Resolves guest layer paths into a browsable stack. Kiri's export is a
    /// host-side directory produced by the Docker CLI bridge, so guest paths
    /// map 1:1 onto host URLs.
    static func resolve(guestPaths: [String], exportRoot: URL? = nil) async -> LayerStack {
        var stack = LayerStack()
        stack.reportedLayers = guestPaths.count
        stack.rootURL = guestPaths.first.flatMap {
            try? LocalRootFSService.resolveRootURL(path: $0)
        }
        stack.unbrowsableLayers = stack.rootURL == nil ? guestPaths.count : 0
        stack.layers = stack.rootURL != nil && guestPaths.count > 1
            ? LayeredRootFS(layers: guestPaths.compactMap { URL(fileURLWithPath: $0, isDirectory: true) })
            : nil
        return stack
    }

    static func unresolved(guestPaths: [String]) -> Unresolved {
        guestPaths.first == nil ? .noPaths : .exportUnavailable
    }

    mutating func exclude(_ indices: Set<Int>) {
        excludedIndices.formUnion(indices)
    }
}

/// Resolves and materializes the filesystem tree a Files tab browses, via the
/// bundled Docker CLI on the host: `docker create` + `docker export` for a
/// container, and `docker create` + `docker export` of the image's scratch
/// container for an image. The export is a merged view, mirroring the
/// classic-graph-driver single-path case upstream.
enum ArcBoxRootfsExport {
    /// Stable per-subject cache root: `~/Library/Caches/Kiri Moby/rootfs/<kind>-<id>`.
    static func exportRoot(kind: String, id: String) -> URL {
        let safeID = id.replacingOccurrences(of: "/", with: "_")
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cache
            .appendingPathComponent("Kiri Moby", isDirectory: true)
            .appendingPathComponent("rootfs", isDirectory: true)
            .appendingPathComponent("\(kind)-\(safeID)", isDirectory: true)
    }

    /// Runs the export on a detached task (CLI round trips); returns the host
    /// path of the merged rootfs, or throws.
    static func resolve(kind: String, id: String, image: String?) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let root = exportRoot(kind: kind, id: id)
            let marker = root.appendingPathComponent(".kiri-export-complete")
            if FileManager.default.fileExists(atPath: marker.path) {
                return [root.path]
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scratch = "kiri-files-scratch-\(UUID().uuidString.prefix(8))"
            let reference = image ?? id
            let (_, createOutput) = MobyRuntime.dockerCapture(["create", "--name", scratch, reference])
            guard looksLikeContainerID(createOutput) else {
                throw KiriFilesTabError.exportFailed(createOutput)
            }
            defer {
                _ = MobyRuntime.dockerCapture(["rm", "-f", scratch])
            }
            let tarURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kiri-rootfs-\(UUID().uuidString.prefix(8)).tar")
            defer { try? FileManager.default.removeItem(at: tarURL) }
            let (rc, _) = MobyRuntime.dockerCapture(
                ["export", "-o", tarURL.path, scratch])
            guard rc == 0, FileManager.default.fileExists(atPath: tarURL.path) else {
                throw KiriFilesTabError.exportFailed("docker export 失败 (rc=\(rc))")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", tarURL.path, "-C", root.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw KiriFilesTabError.exportFailed("rootfs 解包失败 (rc=\(process.terminationStatus))")
            }
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            return [root.path]
        }.value
    }

    private static func looksLikeContainerID(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isHexDigit }
    }
}

enum KiriFilesTabError: LocalizedError {
    case dockerUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .dockerUnavailable:
            return "Docker 客户端不可用。"
        case .exportFailed(let reason):
            return "导出文件系统失败：\(reason)"
        }
    }
}
