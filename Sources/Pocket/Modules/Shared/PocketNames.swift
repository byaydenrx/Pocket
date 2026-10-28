// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// User-chosen names for anything in Pocket's panel: quick toggles, tiles,
/// tabs. An empty name means the built-in one.
enum PocketNames {
    static let changed = Notification.Name("PocketNamesChanged")

    private static func key(_ id: String) -> String { "customName.\(id)" }

    static func custom(_ id: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key(id))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func title(_ id: String, _ fallback: String) -> String { custom(id) ?? fallback }

    static func set(_ name: String?, for id: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key(id)) } else { UserDefaults.standard.set(trimmed, forKey: key(id)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Asks for a new name in a small alert; returns after the user answers.
    @MainActor
    static func promptRename(id: String, current: String, fallback: String) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(current)”"
        alert.informativeText = "Leave it empty to go back to “\(fallback)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = custom(id) ?? ""
        field.placeholderString = fallback
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { set(field.stringValue, for: id) }
    }
}

/// Redraws a view when any custom name changes.
final class PocketNamesObserver: ObservableObject {
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(forName: PocketNames.changed, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

extension RawRepresentable where RawValue == String {
    /// "sleepNow" → "Sleep Now", for prompts that only have an id.
    var readableName: String {
        var out = ""
        for ch in rawValue {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}
