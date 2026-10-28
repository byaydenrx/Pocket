// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide shortcut for one Pocket module, stored like every other
/// Pocket shortcut (a `GlobalShortcut` storage string under `defaultsKey`).
/// No Accessibility permission is needed: Carbon hot keys reach the app
/// directly. Each instance owns one id under the 'PKMD' signature, so modules
/// never answer each other's keys or the upstream registrars'.
final class PocketHotKey {
    private static let signature: OSType = 0x504B_4D44 // 'PKMD'
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static var live: [UInt32: PocketHotKey] = [:]

    let defaultsKey: String
    let fallback: GlobalShortcut?
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private var registered: GlobalShortcut?
    var action: () -> Void

    init(defaultsKey: String, fallback: GlobalShortcut?, action: @escaping () -> Void = {}) {
        self.defaultsKey = defaultsKey
        self.fallback = fallback
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    /// The saved shortcut, the fallback when none was saved, or nil when the
    /// user cleared it (stored as an empty string).
    var shortcut: GlobalShortcut? {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey) {
            return raw.isEmpty ? nil : GlobalShortcut(storageValue: raw)
        }
        return fallback
    }

    func register() {
        guard let shortcut, shortcut.isValid else { unregister(); return }
        if ref != nil, registered == shortcut { return }
        unregister()
        Self.installHandler()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return }
        ref = newRef
        registered = shortcut
        Self.live[id] = self
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
        Self.live[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            if let event {
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            }
            // Other registrars share this target; hand their keys back.
            guard hotKeyID.signature == PocketHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async { PocketHotKey.live[id]?.action() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A Settings row that records a module shortcut into `defaultsKey`.
struct PocketShortcutRow: View {
    let title: String
    let defaultsKey: String
    let fallback: GlobalShortcut?
    var onChange: () -> Void = {}

    @ObservedObject private var l10n = L10n.shared
    @AppStorage private var stored: String
    @State private var error: String?

    init(title: String, defaultsKey: String, fallback: GlobalShortcut?, onChange: @escaping () -> Void = {}) {
        self.title = title
        self.defaultsKey = defaultsKey
        self.fallback = fallback
        self.onChange = onChange
        _stored = AppStorage(wrappedValue: fallback?.storageValue ?? "", defaultsKey)
    }

    private var current: GlobalShortcut? {
        stored.isEmpty ? nil : GlobalShortcut(storageValue: stored)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                ShortcutRecorderButton(
                    shortcut: current ?? fallback ?? .keepAwakeDefault,
                    isEnabled: true,
                    waitingTitle: l10n.s.shortcutPressKeys,
                    emptyTitle: current == nil ? l10n.s.shortcutNone : nil,
                    clearAction: { stored = ""; onChange() },
                    notCapturedAction: { error = l10n.s.shortcutNotCaptured },
                    invalidAction: { error = l10n.s.shortcutInvalid },
                    captureAction: { shortcut in
                        error = nil
                        stored = shortcut.storageValue
                        onChange()
                    }
                )
                .frame(width: 120)
                Button {
                    stored = ""
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(current == nil)
                .help("Remove this shortcut")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

extension AppDelegate {
    /// Opens Settings at one page (used by module menus and panel rows).
    func openSettings(page: SettingsPage) {
        openSettingsWindow()
        SettingsRouter.shared.request(FeatureSettingsDestination(page))
    }
}

extension View {
    /// Liquid Glass prominent buttons on macOS 26, bordered prominent before.
    @ViewBuilder
    func pocketProminentButton() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
#else
        buttonStyle(.borderedProminent)
#endif
    }
}

extension View {
    /// A small round Liquid Glass chip (close buttons and badges over previews);
    /// a frosted circle before macOS 26.
    @ViewBuilder
    func pocketGlassCircle(highlighted: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.clear.interactive(), in: Circle())
                .overlay(Circle().fill(Color.white.opacity(highlighted ? 0.14 : 0)))
        } else {
            background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6))
        }
#else
        background(Circle().fill(.ultraThinMaterial))
#endif
    }
}
