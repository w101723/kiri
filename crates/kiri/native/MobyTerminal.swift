// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif
private typealias Color = SwiftUI.Color

@MainActor
final class ContainerLogSession: ObservableObject {
    @Published var content = ""
    @Published var following = true
    @Published var tailLines = 1000
    @Published var error: String?
    private var previousSnapshot = ""
    private var refreshing = false

    func clear() {
        // Retain the previous snapshot so old lines do not reappear on poll.
        content = ""
    }

    func refresh(containerID: String) async {
        #if KIRI_UI_PREVIEW
        if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
            if !content.isEmpty { return }
            content = """
            2026-01-20 10:14:32 [notice] nginx/1.27.2
            2026-01-20 10:14:32 [notice] built with OpenSSL 3.3
            2026-01-20 10:14:32 [notice] using the "epoll" event method
            2026-01-20 10:14:32 [notice] start worker processes
            2026-01-20 10:14:32 [notice] start worker process 29
            2026-01-20 10:14:32 [notice] start worker process 30
            2026-01-20 10:14:32 [notice] start worker process 31
            2026-01-20 10:16:08 172.17.0.1 - - "GET / HTTP/1.1" 200
            2026-01-20 10:16:08 172.17.0.1 - - "GET /favicon.ico" 404
            """
            return
        }
        #endif
        guard !refreshing, following else { return }
        refreshing = true
        defer { refreshing = false }
        let input = ["action": "logs", "id": containerID,
                     "tail": String(tailLines)]
        guard let json = try? JSONSerialization.data(withJSONObject: input),
              let encoded = String(data: json, encoding: .utf8) else {
            error = "无法编码日志请求"
            return
        }
        let answer = await Task.detached(priority: .utility) {
            Result { try request(["action", encoded], as: Reply.self) }
        }.value
        switch answer {
        case .success(let reply):
            guard reply.ok else {
                error = reply.error ?? "读取日志失败"
                return
            }
            error = nil
            let next = reply.message ?? ""
            if next == previousSnapshot { return }
            if next.hasPrefix(previousSnapshot) {
                content += String(next.dropFirst(previousSnapshot.count))
            } else {
                content = next
            }
            previousSnapshot = next
            if content.count > 240_000 {
                content.removeFirst(content.count - 240_000)
            }
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

/// NSTextView keeps the native find bar, selection and text system and can
/// apply deltas without rebuilding a SwiftUI Text layout on each log update.
struct NativeLogTextView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let content: String
    let following: Bool

    final class Coordinator {
        var rendered = ""
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.hasHorizontalScroller = true
        scroller.autohidesScrollers = true
        scroller.drawsBackground = true
        scroller.backgroundColor = ConsoleAppearance.canvasNS(colorScheme)
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = ConsoleAppearance.foregroundNS(colorScheme)
        view.backgroundColor = scroller.backgroundColor
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scroller.documentView = view
        return scroller
    }
    func updateNSView(_ scroller: NSScrollView, context: Context) {
        guard let view = scroller.documentView as? NSTextView else { return }
        let foreground = ConsoleAppearance.foregroundNS(colorScheme)
        let background = ConsoleAppearance.canvasNS(colorScheme)
        scroller.backgroundColor = background
        view.backgroundColor = background
        view.textColor = foreground
        guard let storage = view.textStorage else { return }
        storage.addAttribute(.foregroundColor, value: foreground,
                             range: NSRange(location: 0, length: storage.length))
        let previous = context.coordinator.rendered
        guard previous != content else { return }
        if content.hasPrefix(previous) {
            let suffix = String(content.dropFirst(previous.count))
            storage.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: foreground
            ]))
        } else {
            storage.setAttributedString(NSAttributedString(string: content, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: foreground
            ]))
        }
        context.coordinator.rendered = content
        if following {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }
}

/// Console colors follow the system appearance, including live appearance changes.
enum ConsoleAppearance {
    // A cool, high-contrast terminal surface without forcing system dark mode.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
                        : Color(red: 246 / 255, green: 248 / 255, blue: 250 / 255)
    }
    static func toolbar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 30 / 255, green: 30 / 255, blue: 34 / 255)
                        : .white
    }
    static func foreground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.88)
                        : Color(red: 31 / 255, green: 35 / 255, blue: 40 / 255)
    }
    static func canvasNS(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark ? NSColor(calibratedRed: 24 / 255, green: 24 / 255,
                                  blue: 27 / 255, alpha: 1)
                        : NSColor(calibratedRed: 246 / 255, green: 248 / 255,
                                  blue: 250 / 255, alpha: 1)
    }
    static func foregroundNS(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark ? NSColor(calibratedWhite: 0.88, alpha: 1)
                        : NSColor(calibratedRed: 31 / 255, green: 35 / 255,
                                  blue: 40 / 255, alpha: 1)
    }
}
enum ConsoleCommand: String {
    case copy, clear, interrupt, toggleFollow
    case last200, last1000, last5000
}
let consoleCommandNotification = Notification.Name("dev.kiri.moby.console.action")

struct ContainerLogWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session = ContainerLogSession()
    let containerID: String
    let containerName: String

    var body: some View {
        NativeLogTextView(content: session.content, following: session.following)
            .frame(minHeight: 150)
            .background(ConsoleAppearance.canvas(colorScheme))
            .task(id: session.tailLines) {
                while !Task.isCancelled {
                    if session.following {
                        await session.refresh(containerID: containerID)
                    }
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { break }
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: consoleCommandNotification)) { notification in
                guard notification.object as? String == "logs:" + containerID,
                      let action = notification.userInfo?["action"] as? String,
                      let command = ConsoleCommand(rawValue: action) else { return }
                switch command {
                case .copy:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.content, forType: .string)
                case .clear: session.clear()
                case .toggleFollow: session.following.toggle()
                case .last200: session.tailLines = 200
                case .last1000: session.tailLines = 1000
                case .last5000: session.tailLines = 5000
                case .interrupt: break
                }
            }
    }
}

// Screenshot-only content. This block does not exist in the production build.
#if KIRI_UI_PREVIEW
let previewTerminalOutput = """
/ # cat /etc/os-release
PRETTY_NAME="Alpine Linux v3.19"
NAME="Alpine Linux"
VERSION_ID="3.19.1"
ID=alpine
HOME_URL="https://alpinelinux.org/"

/ # ls -l /var/log
total 8
-rw-r--r-- 1 root root 615 Jan 20 10:14 access.log
-rw-r--r-- 1 root root 615 Jan 20 10:14 error.log

/ #
"""
#endif

#if canImport(SwiftTerm)
@MainActor
final class SwiftTermTerminalControls: ObservableObject {
    weak var terminal: LocalProcessTerminalView?
    func interrupt() { terminal?.process.send(data: [0x03][...]) }
    func copy() { terminal?.copy(self) }
    func clear() { terminal?.feed(byteArray: Array("\u{001B}[2J\u{001B}[H".utf8)[...]) }
}

// SwiftTerm's LocalProcessTerminalView owns the PTY, UTF-8/ANSI parser,
// keyboard handling and resize/SIGWINCH. The child is the bundled official
// Docker CLI, pinned to Kiri's private socket instead of the user's context.
struct NativeSwiftTermExecView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let containerID: String
    @ObservedObject var controls: SwiftTermTerminalControls

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = ConsoleAppearance.canvasNS(colorScheme)
        view.nativeForegroundColor = ConsoleAppearance.foregroundNS(colorScheme)
        controls.terminal = view
        let cli = MobyPaths.docker.path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            view.feed(byteArray: Array("内置 Docker CLI 不存在：\(cli)\r\n".utf8)[...])
            return view
        }
        let env = MobyRuntime.terminalEnvironment()
        let environment = env.map { "\($0.key)=\($0.value)" }.sorted()
        view.startProcess(executable: cli,
                          args: ["exec", "-it", containerID, "/bin/sh"],
                          environment: environment)
        return view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        view.nativeBackgroundColor = ConsoleAppearance.canvasNS(colorScheme)
        view.nativeForegroundColor = ConsoleAppearance.foregroundNS(colorScheme)
    }
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: ()) {
        view.terminate()
    }
}
#endif

struct ExecTerminalView: View {
    @Environment(\.colorScheme) private var colorScheme
    #if canImport(SwiftTerm)
    @StateObject private var swiftTermControls = SwiftTermTerminalControls()
    #endif
    let containerID: String
    let containerName: String

    var body: some View {
        Group {
            #if KIRI_UI_PREVIEW
            // CI captures the appearance without launching Docker or a PTY.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(previewTerminalOutput.components(separatedBy: "\n").enumerated()),
                            id: \.offset) { _, line in
                        if line.hasPrefix("/ #") {
                            (Text("/ #").foregroundColor(Color(red: 0 / 255, green: 128 / 255, blue: 145 / 255))
                             + Text(String(line.dropFirst(3)))
                                .foregroundColor(ConsoleAppearance.foreground(colorScheme)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(ConsoleAppearance.foreground(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            #elseif canImport(SwiftTerm)
            NativeSwiftTermExecView(containerID: containerID,
                                    controls: swiftTermControls)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 150)
            #else
            ContentUnavailableView("终端不可用", systemImage: "terminal",
                                   description: Text("此构建未包含 SwiftTerm；请使用正式 Kiri Moby 应用。"))
            #endif
        }
        .frame(minHeight: 155)
        .background(ConsoleAppearance.canvas(colorScheme))
        .onReceive(NotificationCenter.default.publisher(
            for: consoleCommandNotification)) { notification in
            guard notification.object as? String == "exec:" + containerID,
                  let action = notification.userInfo?["action"] as? String,
                  let command = ConsoleCommand(rawValue: action) else { return }
            switch command {
            case .copy:
                #if KIRI_UI_PREVIEW
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(previewTerminalOutput, forType: .string)
                #elseif canImport(SwiftTerm)
                swiftTermControls.copy()
                #endif
            case .clear:
                #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
                swiftTermControls.clear()
                #endif
            case .interrupt:
                #if canImport(SwiftTerm) && !KIRI_UI_PREVIEW
                swiftTermControls.interrupt()
                #endif
            case .toggleFollow, .last200, .last1000, .last5000:
                break
            }
        }
    }
}

/// The table must stay one-line-dense: network and block I/O live in a
/// dedicated native popover instead of tiny 9pt numbers in every cell.
