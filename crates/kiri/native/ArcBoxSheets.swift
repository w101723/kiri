// Faithful ports of ArcBox Desktop's PullImageSheet and NewNetworkSheet,
// wired to Kiri's docker CLI bridge instead of the ArcBox daemon client.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import AppKit
import SwiftUI

/// Platform options for pulling images (ArcBox PullImageSheet).
enum ImagePlatform: String, CaseIterable, Identifiable {
    case auto = "auto"
    case linuxAmd64 = "linux/amd64"
    case linuxArm64 = "linux/arm64"

    var id: String { rawValue }
}

struct KiriPullImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: MobyModel
    var onPulled: () -> Void = {}

    @State private var isPulling = false
    @State private var errorMessage: String?
    @State private var pullLog: String?
    @State private var image = ""
    @State private var platform: ImagePlatform = .auto

    private var imageIsEmpty: Bool {
        image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pull Image")
                    .font(.system(size: 13, weight: .semibold))
                Text("Images are used to run containers. They contain an application and its dependencies.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SheetErrorMessage(message: errorMessage)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }

            Form {
                Section {
                    TextField("Image", text: $image, prompt: Text("e.g. alpine:latest"))
                    Picker("Platform", selection: $platform) {
                        ForEach(ImagePlatform.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                }
                if let pullLog {
                    Section {
                        Text(pullLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .truncationMode(.tail)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isPulling)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isPulling ? "Pulling…" : "Pull") {
                    Task { await pull() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(imageIsEmpty || isPulling)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
    }

    private func pull() async {
        isPulling = true
        errorMessage = nil
        pullLog = nil
        let ref = image.trimmingCharacters(in: .whitespaces)
        let platformArg = platform == .auto ? [] : ["--platform", platform.rawValue]
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = MobyRuntime.dockerInvocation(["image", "pull"] + platformArg + [ref])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error.localizedDescription)") }
            let handle = pipe.fileHandleForReading
            var log = ""
            while process.isRunning {
                if let chunk = try? handle.readData(ofLength: 4096), !chunk.isEmpty {
                    log += String(decoding: chunk, as: UTF8.self)
                    if log.count > 4000 { log = String(log.suffix(4000)) }
                }
            }
            let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            log = (log + tail).trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, log)
        }.value
        isPulling = false
        if result.0 == 0 {
            onPulled()
            dismiss()
        } else {
            errorMessage = result.1.isEmpty ? "Pull failed (\(result.0))" : result.1
            pullLog = result.1
        }
    }
}

struct KiriNewNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: MobyModel
    var onCreated: () -> Void = {}

    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var name = ""
    @State private var driver = "bridge"

    private let drivers = ["bridge", "host", "macvlan", "none"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Network")
                    .font(.system(size: 13, weight: .semibold))
                Text("Networks let containers talk to each other and to the host.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
                SheetErrorMessage(message: errorMessage)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. my-bridge"))
                    Picker("Driver", selection: $driver) {
                        ForEach(drivers, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        let clean = name.trimmingCharacters(in: .whitespaces)
        let selectedDriver = driver
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            MobyRuntime.dockerCapture(["network", "create", "--driver", selectedDriver, clean])
        }.value
        isCreating = false
        if result.0 == 0 {
            onCreated()
            dismiss()
        } else {
            errorMessage = result.1.isEmpty ? "Create failed (\(result.0))" : result.1
        }
    }
}
