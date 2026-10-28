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
            Section("Pomodoro") {
                PomodoroStepper(title: "Focus", key: TimerModel.PomodoroKey.focus, fallback: 25)
                PomodoroStepper(title: "Short break", key: TimerModel.PomodoroKey.shortBreak, fallback: 5)
                PomodoroStepper(title: "Long break", key: TimerModel.PomodoroKey.longBreak, fallback: 15)
                PomodoroStepper(title: "Long break every", key: TimerModel.PomodoroKey.rounds, fallback: 4, unit: "rounds", range: 2...8)
                PomodoroToggle()
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


/// The timer keeps its settings in its own domain, so these bind by hand.
private struct PomodoroStepper: View {
    let title: String
    let key: String
    let fallback: Double
    var unit = "min"
    var range: ClosedRange<Double> = 1...120
    @State private var value: Double = 0

    var body: some View {
        Stepper(value: Binding(get: { value }, set: { value = $0; TimerStore.defaults.set($0, forKey: key) }),
                in: range, step: unit == "min" ? 5 : 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .onAppear {
            let stored = TimerStore.defaults.double(forKey: key)
            value = stored > 0 ? stored : fallback
        }
    }
}

private struct PomodoroToggle: View {
    @State private var on = TimerStore.defaults.bool(forKey: TimerModel.PomodoroKey.keepAwake)
    var body: some View {
        Toggle("Keep the Mac awake while focusing", isOn: Binding(get: { on }, set: {
            on = $0
            TimerStore.defaults.set($0, forKey: TimerModel.PomodoroKey.keepAwake)
        }))
    }
}
