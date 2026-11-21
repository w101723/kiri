// Faithful ports of ArcBox Desktop's shared toolbar and feedback components.
// Copyright (c) 2026 ArcBox Labs; MIT license.
import Foundation
import SwiftUI

/// Generic sort menu button for toolbar usage (ArcBox Components/SortMenuButton).
struct SortMenuButton<Field: Hashable & CaseIterable & RawRepresentable>: View
where Field.RawValue == String, Field.AllCases: RandomAccessCollection {
    @Binding var sortBy: Field
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(Field.allCases, id: \.self) { field in
                    Button {
                        sortBy = field
                    } label: {
                        if sortBy == field {
                            Label(field.rawValue, systemImage: "checkmark")
                        } else {
                            Text(field.rawValue)
                        }
                    }
                }
            }
            Section("Order") {
                Button {
                    ascending = true
                } label: {
                    if ascending {
                        Label("Ascending", systemImage: "checkmark")
                    } else {
                        Text("Ascending")
                    }
                }
                Button {
                    ascending = false
                } label: {
                    if !ascending {
                        Label("Descending", systemImage: "checkmark")
                    } else {
                        Text("Descending")
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

/// Lightweight toast banner that slides in from the top
/// (ArcBox Components/ToastView).
struct ToastView: View {
    let message: String
    var icon: String = "exclamationmark.triangle.fill"
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.error)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(AppColors.text)

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.error.opacity(0.3), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// View modifier that shows a toast when `message` is non-nil.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var dismissAfter: Duration? = .seconds(4)

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let msg = message {
                ToastView(message: msg) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        message = nil
                    }
                }
                .task {
                    if let dismissAfter {
                        try? await Task.sleep(for: dismissAfter)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            message = nil
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// ArcBox ToastView.errorToast: toast bound to one message binding.
    func errorToast(message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }

    /// ArcBox ToastView.listErrorToast: operation error sticky, refresh error
    /// auto-dismissing, namespaced by the resource the list shows.
    func listErrorToast(operationError: Binding<String?>,
                        refreshError: Binding<String?>,
                        resourceName: String) -> some View {
        modifier(ListErrorToastModifier(operationError: operationError,
                                        refreshError: refreshError,
                                        resourceName: resourceName))
    }
}

private struct ListErrorToastModifier: ViewModifier {
    @Binding var operationError: String?
    @Binding var refreshError: String?
    let resourceName: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let msg = operationError {
                ToastView(message: msg) {
                    withAnimation(.easeInOut(duration: 0.2)) { operationError = nil }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let msg = refreshError {
                ToastView(message: "\(resourceName.capitalized): \(msg)") {
                    withAnimation(.easeInOut(duration: 0.2)) { refreshError = nil }
                }
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.easeInOut(duration: 0.2)) { refreshError = nil }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// Formatting for resource values (ArcBox Views/Activity/StatsFormat).
enum StatsFormat {
    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond).rounded()), countStyle: .memory) + "/s"
    }

    static func load(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

// Ported from ArcBox Desktop (MIT): Components/SheetErrorMessage.swift
/// Inline failure message for a sheet that stays open after a failed action.
struct SheetErrorMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.error)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
