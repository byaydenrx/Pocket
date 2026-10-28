// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import Carbon.HIToolbox

/// One-time imports from the apps Pocket replaces, run before anything reads
/// a setting. Both only read the other app's preferences; nothing is changed
/// there. They can also be run again from Settings › General.
enum SettingsImport {
    private static let didImportVorssaintKey = "pocketDidImportVorssaint"
    private static let didImportRectangleKey = "pocketDidImportRectangle"

    static let vorssaintDomain = "com.vorssaint.utils"
    static let rectangleDomain = "com.knollsoft.Rectangle"

    static var vorssaintSettingsExist: Bool {
        !(UserDefaults.standard.persistentDomain(forName: vorssaintDomain) ?? [:]).isEmpty
    }

    static var rectangleSettingsExist: Bool {
        !(UserDefaults.standard.persistentDomain(forName: rectangleDomain) ?? [:]).isEmpty
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
        if !defaults.bool(forKey: didImportRectangleKey) {
            defaults.set(true, forKey: didImportRectangleKey)
            if rectangleSettingsExist { _ = importRectangle() }
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
        // Pocket dims the menu bar icon while awake instead of tinting it.
        defaults.set(KeepAwakeIconTint.dimmed.rawValue, forKey: DefaultsKey.keepAwakeIconTint)
        return count
    }

    // MARK: Rectangle

    /// Rectangle action name → Pocket window action.
    private static let rectangleActions: [String: WindowLayoutAction] = [
        "leftHalf": .leftHalf, "rightHalf": .rightHalf, "topHalf": .topHalf, "bottomHalf": .bottomHalf,
        "centerHalf": .centerHalf,
        "topLeft": .topLeft, "topRight": .topRight, "bottomLeft": .bottomLeft, "bottomRight": .bottomRight,
        "firstThird": .leftThird, "centerThird": .centerThird, "lastThird": .rightThird,
        "firstTwoThirds": .leftTwoThirds, "centerTwoThirds": .centerTwoThirds, "lastTwoThirds": .rightTwoThirds,
        "firstFourth": .leftQuarter, "secondFourth": .leftMiddleQuarter, "thirdFourth": .rightMiddleQuarter,
        "lastFourth": .rightQuarter,
        "topLeftSixth": .topLeftSixth, "topCenterSixth": .topCenterSixth, "topRightSixth": .topRightSixth,
        "bottomLeftSixth": .bottomLeftSixth, "bottomCenterSixth": .bottomCenterSixth,
        "bottomRightSixth": .bottomRightSixth,
        "maximize": .maximize, "almostMaximize": .marginMaximize, "center": .center, "restore": .restore,
        "nextDisplay": .nextDisplay, "previousDisplay": .previousDisplay,
        "larger": .larger, "smaller": .smaller,
    ]

    struct RectangleResult {
        var imported: [WindowLayoutAction] = []
        /// Rectangle shortcuts with no Pocket action (move left, maximize height…).
        var skipped: [String] = []
    }

    /// Copies Rectangle's keyboard shortcuts into Pocket's window layouts and
    /// turns window shortcuts on. Actions Rectangle leaves unbound are cleared
    /// too, so Pocket ends up with exactly Rectangle's set.
    @discardableResult
    static func importRectangle() -> RectangleResult {
        var result = RectangleResult()
        guard let saved = UserDefaults.standard.persistentDomain(forName: rectangleDomain) else { return result }
        let defaults = UserDefaults.standard
        var assigned: [GlobalShortcut] = []
        for (name, value) in saved {
            guard let dict = value as? [String: Any] else { continue }
            let keyCode = (dict["keyCode"] as? NSNumber)?.int64Value
            let flags = (dict["modifierFlags"] as? NSNumber)?.uintValue
            guard let action = rectangleActions[name] else {
                if keyCode != nil, !["reflowTodo", "toggleTodo"].contains(name) { result.skipped.append(name) }
                continue
            }
            if let keyCode, let flags {
                let shortcut = GlobalShortcut(keyCode: keyCode,
                                              modifiers: GlobalShortcutModifiers(eventFlags: NSEvent.ModifierFlags(rawValue: flags)))
                defaults.set(shortcut.storageValue, forKey: action.shortcutKey)
                assigned.append(shortcut)
                result.imported.append(action)
            } else {
                defaults.set(WindowLayoutAction.clearedShortcutStorageValue, forKey: action.shortcutKey)
            }
        }
        // A Pocket default that Rectangle reuses for something else would
        // steal the key; clear it.
        let mapped = Set(rectangleActions.values)
        for action in WindowLayoutAction.shortcutActions where !mapped.contains(action) {
            if let shortcut = action.savedShortcut, assigned.contains(shortcut) {
                defaults.set(WindowLayoutAction.clearedShortcutStorageValue, forKey: action.shortcutKey)
            }
        }
        if !result.imported.isEmpty {
            defaults.set(true, forKey: DefaultsKey.windowLayoutShortcutsEnabled)
            defaults.set(true, forKey: AppFeature.windowLayout.availabilityKey)
        }
        return result
    }
}

import SwiftUI

/// Settings › General: run the imports again on purpose.
struct SettingsImportCard: View {
    @State private var message: String?

    var body: some View {
        if SettingsImport.vorssaintSettingsExist || SettingsImport.rectangleSettingsExist {
            SettingsCard(title: "Import") {
                VStack(alignment: .leading, spacing: 10) {
                    if SettingsImport.vorssaintSettingsExist {
                        HStack {
                            Text("Settings from Vorssaint")
                            Spacer()
                            Button("Import…") { importVorssaint() }
                        }
                    }
                    if SettingsImport.rectangleSettingsExist {
                        HStack {
                            Text("Keyboard shortcuts from Rectangle")
                            Spacer()
                            Button("Import") { importRectangle() }
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

    private func importRectangle() {
        let result = SettingsImport.importRectangle()
        WindowLayoutService.shared.syncWithPreferences()
        var text = "Imported \(result.imported.count) shortcuts."
        if !result.skipped.isEmpty { text += " Not available in Pocket: \(result.skipped.sorted().joined(separator: ", "))." }
        text += " Quit Rectangle so both apps don't fight over the same keys."
        message = text
    }
}
