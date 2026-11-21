// Faithful ports of ArcBox Desktop's LayerMergeBadge, ContainerFilesTab and
// ImageFilesTab / ImageDetailView, backed by kiri's host-side rootfs export.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import AppKit
import SwiftUI

/// Says how many layers a Files tab merged, and warns when some of them
/// could not be read.
struct LayerMergeBadge: View {
    private let total: Int
    private let unavailable: Int
    private let describesAStack: Bool

    init(stack: LayerStack) {
        total = stack.reportedLayers
        unavailable = stack.missingLayers
        describesAStack = stack.describesAStack
    }

    private var isComplete: Bool { unavailable == 0 }

    @ViewBuilder
    var body: some View {
        if describesAStack {
            badge
        }
    }

    private var badge: some View {
        HStack(spacing: 4) {
            if !isComplete {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            }

            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(isComplete ? AppColors.textMuted : AppColors.warning)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .help(
            isComplete
                ? "Merged view of all \(total) filesystem layers."
                : "\(unavailable) of \(total) layers are unavailable; "
                    + "files that only exist in them are missing from this view."
        )
    }

    private var label: String { Self.label(total: total, unavailable: unavailable) }

    static func label(total: Int, unavailable: Int) -> String {
        unavailable == 0
            ? "merged from \(total) layers"
            : "merged from \(total - unavailable) of \(total) layers"
    }
}

/// Shared Files-tab scaffold: path toolbar + outline browser (upstream
/// ContainerFilesTab / ImageFilesTab share this shape).
struct KiriFilesTabView: View {
    let kind: String
    let id: String
    let image: String?

    @State private var selectedPath: String?
    @State private var stack = LayerStack()
    @State private var errorMessage: String?
    @State private var isLoadingRoot = false
    @State private var refreshToken = UUID()
    @State private var showHiddenFiles = LocalRootFSService.finderDefaultShowHiddenFiles()

    private var reloadID: String {
        "\(id)|\(showHiddenFiles)|\(refreshToken.uuidString)"
    }

    private var selectedURL: URL? {
        guard let selectedPath else { return nil }
        return URL(filePath: selectedPath, directoryHint: .inferFromPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
        .task(id: reloadID) {
            await resolveRootPath(requestID: reloadID)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)

            Text("/")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Path: /")

            LayerMergeBadge(stack: stack)

            Spacer()

            Button(
                action: { showHiddenFiles.toggle() },
                label: {
                    Image(systemName: showHiddenFiles ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                }
            )
            .buttonStyle(.plain)
            .help(showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件")
            .accessibilityLabel(showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件")

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新文件")

            Button(action: revealSelectedInFinder) {
                Image(systemName: "finder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(selectedURL == nil)
            .help("在 Finder 中显示所选文件")
            .accessibilityLabel("在 Finder 中显示所选文件")
        }
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingRoot {
            VStack {
                Spacer()
                ProgressView("正在加载文件…")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }
        } else if let errorMessage {
            errorState(errorMessage)
        } else if let rootURL = stack.rootURL {
            LocalRootFSOutlineView(
                rootURL: rootURL,
                layers: stack.layers,
                displayRootPath: "/",
                showHiddenFiles: showHiddenFiles,
                reloadID: reloadID,
                selectedPath: $selectedPath,
                onOpenURL: { url in
                    _ = NSWorkspace.shared.open(url)
                },
                onExcludedLayers: { stack.exclude($0) }
            )
        } else {
            errorState(kind == "images"
                ? "镜像没有可解析的文件系统路径。"
                : "容器没有可解析的文件系统路径。")
        }
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.textMuted)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Text("文件系统通过 Docker CLI 导出到宿主机缓存目录后浏览（只读）。")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button("重试") {
                refresh()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        refreshToken = UUID()
    }

    private func resolveRootPath(requestID: String) async {
        guard requestID == reloadID, !Task.isCancelled else { return }
        errorMessage = nil
        isLoadingRoot = true
        selectedPath = nil
        stack = LayerStack()
        defer {
            if requestID == reloadID, !Task.isCancelled {
                isLoadingRoot = false
            }
        }

        do {
            let guestPaths = try await ArcBoxRootfsExport.resolve(
                kind: kind, id: id, image: image)
            guard requestID == reloadID, !Task.isCancelled else { return }
            let resolvedStack = await LayerStack.resolve(guestPaths: guestPaths)
            guard requestID == reloadID, !Task.isCancelled else { return }
            stack = resolvedStack
            guard stack.rootURL != nil else {
                errorMessage = "导出的文件系统不可用，请重试。"
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestID == reloadID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func revealSelectedInFinder() {
        guard let url = selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Column 3 for images: Info / Files tab-based detail (upstream
/// ImageDetailView), wired to kiri's model.
struct KiriImageDetailView: View {
    @EnvironmentObject private var model: MobyModel
    let image: ImageItem
    @Binding var activeTab: KiriImageDetailTab
    @State private var inspectError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch activeTab {
                case .info:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(spacing: 0) {
                                InfoRow(label: "ID", value: image.Id)
                                InfoRow(label: "标签", value: image.title)
                                InfoRow(label: "创建时间",
                                        value: image.Created.map {
                                            Date(timeIntervalSince1970: TimeInterval($0)).formatted()
                                        } ?? "—")
                                InfoRow(label: "大小",
                                        value: StatsFormat.bytes(UInt64(max(0, image.Size ?? 0))))
                            }
                            .infoSectionStyle()
                            HStack {
                                Button("运行容器") {
                                    model.perform(["run", image.title], title: "运行容器",
                                                  showResult: false)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("删除", role: .destructive) {
                                    if model.confirm("删除镜像 \(image.title)？",
                                                     detail: "正在被容器使用的镜像无法删除。") {
                                        model.perform(["rmi", image.title], title: "删除镜像",
                                                      showResult: false)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                case .files:
                    KiriFilesTabView(kind: "images", id: image.Id, image: image.title)
                }

                // Terminal tab placeholder: kiri images keep Info/Files.
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            DetailTabPicker(selection: $activeTab)
        }
    }
}

enum KiriImageDetailTab: String, CaseIterable, Identifiable, DetailTab {
    case info = "详情"
    case files = "文件"
    var id: String { rawValue }
}
