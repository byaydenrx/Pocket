// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Fetch (MIT, © 2026 Byaydenrx): aria2c with a simple window.

import AppKit
import Combine
import SwiftUI

/// Owns the Downloads window and the aria2c daemon behind it. aria2c runs
/// only while the window is open or something is downloading; a minute after
/// both stop it exits, so the feature costs nothing at rest.
@MainActor
final class DownloadsService: NSObject {
    static let shared = DownloadsService()
    static let shortcutKey = "downloadsShortcut"

    private(set) lazy var settings = DLSettings()
    private(set) lazy var store = DLStore(settings: settings)
    private let hover = DLHoverState()
    private var idleTimer: Timer?
    private var activeWatch: AnyCancellable?
    private lazy var hotKey = PocketHotKey(defaultsKey: Self.shortcutKey, fallback: nil) { [weak self] in self?.open() }

    var isAvailable: Bool { AppFeature.downloads.isAvailable }

    func syncWithPreferences() {
        guard isAvailable else {
            hotKey.unregister()
            shutdown()
            return
        }
        hotKey.register()
        // Unfinished downloads from last time pick up again on their own.
        if DLStore.hasUnfinishedSession, !store.ready { startDaemon() }
    }

    func shortcutChanged() {
        if isAvailable { hotKey.register() }
    }

    private var panelVisible = false

    /// Opens the menu panel; Downloads lives there as a tab. Links passed in
    /// (magnets, URLs, .torrent files) are added right away.
    func open(_ urls: [URL] = []) {
        guard isAvailable else { return }
        startDaemon()
        if !urls.isEmpty { store.drop(urls) }
        appDelegate()?.openMenuPanel()
    }

    func panelAppeared() {
        panelVisible = true
        startDaemon()
        idleTimer?.invalidate()
    }

    func panelDisappeared() {
        panelVisible = false
        scheduleIdleCheck()
    }

    private func startDaemon() {
        if activeWatch == nil {
            activeWatch = store.$activeCount.removeDuplicates().sink { [weak self] _ in
                self?.scheduleIdleCheck()
            }
        }
        guard !store.ready else { return }
        store.start()
        store.requestNotifications()
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard store.ready, !panelVisible, store.activeCount == 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panelVisible, self.store.activeCount == 0 else { return }
                self.shutdown()
            }
        }
    }

    private func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
        activeWatch = nil
        if store.ready { store.quit() }
    }

    /// Called when Pocket quits: aria2c saves its session and exits with it.
    func applicationWillTerminate() {
        if store.ready { store.quit() }
    }
}

final class DLFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DownloadsSettings: View {
    @ObservedObject private var settings = DownloadsService.shared.settings

    var body: some View {
        Form {
            Section {
                Text(AppFeature.downloads.pocketDescription + " Downloads lives in the menu panel as its own tab.")
                    .font(.callout)
                if DLAria2.binary() == nil {
                    HStack(spacing: 6) {
                        Label("aria2c isn't installed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Link("How to install", destination: DLAria2.installHelp)
                    }
                    .font(.caption)
                }
            }
            Section("Shortcut") {
                PocketShortcutRow(title: "Open Downloads", defaultsKey: DownloadsService.shortcutKey, fallback: nil) {
                    DownloadsService.shared.shortcutChanged()
                }
            }
            Section("Options") {
                DLSettingsView(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}
