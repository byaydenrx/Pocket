// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

struct MenuBarTimerSettings: View {
    @AppStorage(DefaultsKey.menuBarTimerEnabled) private var enabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Show the timer in the menu bar", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in MenuBarTimerService.shared.syncWithPreferences() }
                Text(AppFeature.menuBarTimer.pocketDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                PocketShortcutRow(title: "Open the timer",
                                  defaultsKey: MenuBarTimerService.shortcutKey,
                                  fallback: MenuBarTimerService.defaultShortcut) {
                    MenuBarTimerService.shared.shortcutChanged()
                }
                Text("The shortcut also stops a ringing alarm. ⌥-click the menu bar item to repeat the last timer; right-click it for the alarm sound and icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("What you can type") {
                ForEach(["5", "25m focus", "1h30", "1:30", "90s", "3pm", "at 15:30"], id: \.self) { example in
                    HStack {
                        Text(example).monospaced()
                        Spacer()
                        if let request = TimerParser.parse(example) {
                            Text(request.until.map { "until \(TimerFormat.time($0))" } ?? TimerFormat.length(request.seconds))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
