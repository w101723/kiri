import Foundation
import SwiftUI

/// Live CPU/RAM/IO observations do not invalidate the whole three-column shell.
@MainActor
final class MobyTelemetry: ObservableObject {
    @Published var containerStats: [String: ContainerResourceUsage] = [:]
    @Published var statsHistory: [String: [ContainerHistoryPoint]] = [:]
    @Published var statsUpdatedAt: Date?
    @Published var statsError: String?
    @Published var statsTruncated = false
}
