// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// Replaces upstream's Features hub. Pocket has no install step, so this page
/// is only about what macOS lets Pocket do, and which features use each grant.
struct PocketPermissionsPage: View {
    @ObservedObject private var l10n = L10n.shared

    /// Only grants some Pocket feature can actually use.
    private var permissions: [AppPermission] {
        let used = Set(AppFeature.allCases.flatMap(\.permissions))
        return AppPermission.allCases.filter { used.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Permissions").font(.title2.bold())
                    Text("Every Pocket feature is built in and stays idle until you turn it on. Grant only what the features you use need; each row lists who asks for it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionsPortalSections(hub: FeatureStrings.hub(l10n.language), visiblePermissions: permissions)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(22)
        }
    }
}
