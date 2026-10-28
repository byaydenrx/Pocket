// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// A titled box that opens and closes, the title inside it, like a grouped
/// disclosure in System Settings. Starts closed; remembers what you chose.
struct PocketDropdownBox<Content: View>: View {
    let title: String
    let systemImage: String
    @AppStorage private var expanded: Bool
    private let content: () -> Content

    init(title: String, systemImage: String, key: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
        _expanded = AppStorage(wrappedValue: false, "dropdownExpanded.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().padding(.horizontal, 12)
                content()
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }
}
