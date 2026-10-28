// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

struct DockNowPlayingSettings: View {
    @AppStorage(DefaultsKey.dockNowPlayingEnabled) private var enabled = false
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show the card when hovering Music in the Dock", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in DockNowPlayingService.shared.syncWithPreferences() }
                Text(AppFeature.dockNowPlaying.pocketDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if enabled, !permissions.accessibility {
                    Label("Needs Accessibility to find Music's Dock icon.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Using the card") {
                Label("Hover the Music icon in the Dock: the card shows while Music is open.", systemImage: "cursorarrow.motionlines")
                Label("Drag the timeline to scrub. Back, play/pause and skip work right on the card.", systemImage: "slider.horizontal.below.rectangle")
                Label("Drag the card by its background and let go with ⌘ held to pin it anywhere. Let go without ⌘ to put it away.", systemImage: "pin")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
