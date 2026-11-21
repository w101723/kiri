// Adapted from ArcBox Desktop (c) 2026 ArcBox Labs. SPDX-License-Identifier: MIT.
// Kiri integration modifications 2026; see Kiri NOTICE for attribution.
import SwiftUI

extension View {
    /// Keeps the system toolbar separator visible across content and detail
    /// columns instead of letting macOS 26 replace it with a soft scroll edge.
    func toolbarSeparator() -> some View {
        overlay(alignment: .top) {
            Divider()
        }
    }
}
