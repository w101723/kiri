// Adapted from ArcBox Desktop (c) 2026 ArcBox Labs. SPDX-License-Identifier: MIT.
// Kiri integration modifications 2026; see Kiri NOTICE for attribution.
import SwiftUI

/// Reusable status dot + label badge
struct StatusBadge: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: AppMetrics.statusDot, height: AppMetrics.statusDot)
            Text(label)
                .font(.callout)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
