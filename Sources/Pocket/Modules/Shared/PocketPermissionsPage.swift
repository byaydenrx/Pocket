// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// Replaces upstream's Features hub. Pocket has no install step, so this page
/// is only about what macOS lets Pocket do, and which features use each grant.
struct PocketPermissionsPage: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section {
                Text("Every Pocket feature is built in and stays idle until you switch it on in its own page. Grant only what the features you use need; each row lists who asks for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionsPortalSections(hub: FeatureStrings.hub(l10n.language))
            }
        }
        .formStyle(.grouped)
    }
}
