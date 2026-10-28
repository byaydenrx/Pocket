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
final class DownloadsService: NSObject, NSWindowDelegate {
    static let shared = DownloadsService()
    static let shortcutKey = "downloadsShortcut"

    private(set) lazy var settings = DLSettings()
    private(set) lazy var store = DLStore(settings: settings)
    private let hover = DLHoverState()
    private var window: NSWindow?
    private var idleTimer: Timer?
    private var activeWatch: AnyCancellable?
    private lazy var hotKey = PocketHotKey(defaultsKey: Self.shortcutKey, fallback: nil) { [weak self] in self?.open() }

    var isAvailable: Bool { AppFeature.downloads.isAvailable }

    func syncWithPreferences() {
        guard isAvailable else {
            hotKey.unregister()
            shutdown()
            window?.close()
            return
        }
        hotKey.register()
        // Unfinished downloads from last time pick up again on their own.
        if DLStore.hasUnfinishedSession, !store.ready { startDaemon() }
    }

    func shortcutChanged() {
        if isAvailable { hotKey.register() }
    }

    /// Shows the window, starting aria2c if needed. Links (magnets, URLs,
    /// .torrent files) passed in are added right away.
    func open(_ urls: [URL] = []) {
        guard isAvailable else { return }
        startDaemon()
        let window = self.window ?? makeWindow()
        self.window = window
        if !urls.isEmpty { store.drop(urls) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Downloads"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // An empty unified toolbar makes the title bar tall enough to hold the link field beside the window buttons.
        window.toolbar = NSToolbar(identifier: "PocketDownloads")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = DLFirstClickHostingView(rootView: DLRootView(store: store, settings: settings, hover: hover))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrameAutosaveName("PocketDownloads")
        if !window.setFrameUsingName("PocketDownloads") { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard store.ready, window?.isVisible != true, store.activeCount == 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible != true, self.store.activeCount == 0 else { return }
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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppFeature.downloads.pocketDescription)
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
                    Spacer()
                    Button("Open Downloads") { DownloadsService.shared.open() }
                        .buttonStyle(.borderedProminent)
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
