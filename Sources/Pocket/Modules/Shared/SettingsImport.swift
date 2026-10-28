// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit

/// One-time import from Vorssaint, which Pocket replaces, run before anything reads
/// a setting. Both only read the other app's preferences; nothing is changed
/// there. They can also be run again from Settings › General.
enum SettingsImport {
    private static let didImportVorssaintKey = "pocketDidImportVorssaint"

    static let vorssaintDomain = "com.vorssaint.utils"

    static var vorssaintSettingsExist: Bool {
        !(UserDefaults.standard.persistentDomain(forName: vorssaintDomain) ?? [:]).isEmpty
    }

    /// Called once from main.swift before defaults are registered.
    static func runAtFirstLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didImportVorssaintKey) {
            defaults.set(true, forKey: didImportVorssaintKey)
            // Only on a fresh Pocket: never overwrite choices made in Pocket.
            let fresh = (defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]).count <= 1
            if fresh, vorssaintSettingsExist { _ = importVorssaint() }
        }
        // Pocket has no install/uninstall step: every feature is present and
        // idle until its own switch is on. Older Pocket builds (and Vorssaint
        // imports) left some uninstalled; bring them all back once.
        if !defaults.bool(forKey: "pocketMigration.allFeaturesPresent.v1") {
            defer { defaults.set(true, forKey: "pocketMigration.allFeaturesPresent.v1") }
            for feature in AppFeature.allCases { defaults.set(true, forKey: feature.availabilityKey) }
        }
    }

    // MARK: Vorssaint

    /// Keys that describe that app's own install rather than a choice: update
    /// state, onboarding and release-note bookkeeping, window positions.
    private static func isInstallBookkeeping(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return key.hasPrefix("NS") || key.hasPrefix("SU") || key.hasPrefix("com.apple")
            || lowered.contains("update") || lowered.contains("release") || lowered.contains("whatsnew")
            || lowered.contains("onboarding") || lowered.contains("lastseen") || lowered.contains("showcase")
            || lowered.contains("signing") || lowered.contains("telemetry")
    }

    /// Copies every Vorssaint setting (features, switcher, shelf, panel order,
    /// shortcuts…) into Pocket. Returns how many were copied.
    @discardableResult
    static func importVorssaint() -> Int {
        guard let saved = UserDefaults.standard.persistentDomain(forName: vorssaintDomain) else { return 0 }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in saved where !isInstallBookkeeping(key) {
            defaults.set(value, forKey: key)
            count += 1
        }
        // The brand-mark choices carried the old name.
        for key in [DefaultsKey.keepAwakeActiveIcon] where defaults.string(forKey: key) == "vorssaint" {
            defaults.set("pocket", forKey: key)
        }
        for feature in AppFeature.allCases { defaults.set(true, forKey: feature.availabilityKey) }
        // Pocket dims the menu bar icon while awake instead of tinting it.
        defaults.set(KeepAwakeIconTint.dimmed.rawValue, forKey: DefaultsKey.keepAwakeIconTint)
        return count
    }
}

import SwiftUI

/// Settings › General: run the imports again on purpose.
struct SettingsImportCard: View {
    @State private var message: String?

    var body: some View {
        if SettingsImport.vorssaintSettingsExist {
            SettingsCard(title: "Import") {
                VStack(alignment: .leading, spacing: 10) {
                    if SettingsImport.vorssaintSettingsExist {
                        HStack {
                            Text("Settings from Vorssaint")
                            Spacer()
                            Button("Import…") { importVorssaint() }
                        }
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func importVorssaint() {
        let alert = NSAlert()
        alert.messageText = "Replace Pocket's settings with Vorssaint's?"
        alert.informativeText = "Features, panel layout, switcher, shelf and shortcuts are copied from Vorssaint. Pocket restarts afterwards."
        alert.addButton(withTitle: "Import and Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsImport.importVorssaint()
        UserDefaults.standard.synchronize()
        let path = Bundle.main.bundlePath
        try? DetachedProcess.spawn("/bin/sh", ["-c", "sleep 1; /usr/bin/open \"$0\"", path])
        NSApp.terminate(nil)
    }
}
