// Container Info presentation adapted from ArcBox Desktop's ContainerInfoTab.
// Copyright (c) 2026 ArcBox Labs; MIT license. Kiri-specific Docker adapter.
import Foundation
import SwiftUI

private struct KiriArcBoxLabelEntry: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

struct KiriArcBoxContainerInfoTab: View {
    @ObservedObject var telemetry: MobyTelemetry
    let container: ContainerItem
    @State private var inspect: ContainerInspectDetails?

    private var portMappings: [PortMapping] {
        (container.Ports ?? []).compactMap { port in
            guard let target = port.PrivatePort, (0...65535).contains(target),
                  let host = port.PublicPort, (0...65535).contains(host) else { return nil }
            return PortMapping(hostPort: UInt16(host), containerPort: UInt16(target),
                               protocol: port.Type ?? "tcp")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    InfoRow(label: "Name", value: container.title)
                    InfoRow(label: "ID", value: container.Id)
                    InfoRow(label: "Image", value: container.Image ?? "—")
                    InfoRow(label: "Status", value: container.Status ?? container.State ?? "—")
                }
                .infoSectionStyle()

                if let project = container.composeProject, !project.isEmpty {
                    VStack(spacing: 0) {
                        InfoRow(label: "Compose Project", value: project)
                        if let service = container.Labels?["com.docker.compose.service"] {
                            InfoRow(label: "Service", value: service)
                        }
                    }
                    .infoSectionStyle()
                }

                if !portMappings.isEmpty {
                    InfoTableView(title: "Port Forwards",
                                  columns: ["Host Port", "Container Port", "Protocol"],
                                  items: portMappings) { port in
                        HStack {
                            if port.protocol.lowercased() == "tcp" && port.hostPort > 0,
                               let url = URL(string: "http://127.0.0.1:\(port.hostPort)/") {
                                Link(String(port.hostPort), destination: url)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(String(port.hostPort))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(String(port.containerPort))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(port.protocol.uppercased())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let mounts = inspect?.Mounts, !mounts.isEmpty {
                    InfoTableView(title: "Mounts",
                                  columns: ["Source", "Destination"],
                                  items: mounts) { mount in
                        HStack(alignment: .top) {
                            Text(mount.Source ?? "—")
                                .foregroundStyle(AppColors.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(mount.Destination ?? "—")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .textSelection(.enabled)
                    }
                }

                let labels = (container.Labels ?? [:]).sorted { $0.key < $1.key }
                    .map { KiriArcBoxLabelEntry(key: $0.key, value: $0.value) }
                if !labels.isEmpty {
                    InfoTableView(title: "Labels", columns: ["Key", "Value"],
                                  items: labels) { label in
                        HStack(alignment: .top) {
                            Text(label.key)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(label.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .textSelection(.enabled)
                    }
                }

                if let live = telemetry.containerStats[container.Id] {
                    VStack(spacing: 0) {
                        InfoRow(label: "CPU",
                            value: live.cpu_percent.map { String(format: "%.1f%%", $0) } ?? "—")
                        InfoRow(label: "Memory", value: sizeLabel(live.memory_bytes))
                        InfoRow(label: "Network RX / TX",
                                value: "\(sizeLabel(live.net_rx_bytes)) / \(sizeLabel(live.net_tx_bytes))")
                    }
                    .infoSectionStyle()
                }
            }
            .padding(16)
        }
        .background(AppColors.sidebar)
        .task(id: container.Id) {
            inspect = nil
            #if KIRI_UI_PREVIEW
            if ProcessInfo.processInfo.environment["KIRI_MOBY_UI_PREVIEW"] == "1" {
                let sample = #"{"Mounts":[{"Type":"bind","Source":"/Users/demo/site","Destination":"/srv/project","RW":true}]}"#
                inspect = try? JSONDecoder().decode(ContainerInspectDetails.self, from: Data(sample.utf8))
                return
            }
            #endif
            guard let payload = try? JSONSerialization.data(withJSONObject: [
                "action": "inspect", "kind": "containers", "id": container.Id
            ]), let encoded = String(data: payload, encoding: .utf8) else { return }
            let response = await Task.detached(priority: .utility) {
                try? request(["action", encoded], as: Reply.self)
            }.value
            if response?.ok == true, let message = response?.message {
                inspect = try? JSONDecoder().decode(ContainerInspectDetails.self,
                                                    from: Data(message.utf8))
            }
        }
    }
}
