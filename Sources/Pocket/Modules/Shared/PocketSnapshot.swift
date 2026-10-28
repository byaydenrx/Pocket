// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// `Pocket --snapshot <dir>`: renders every menu panel tab and Settings page
/// to PNGs for layout review, then quits. Offscreen rendering cannot draw
/// Liquid Glass, so surfaces sit on a flat stand-in; layout, text and
/// spacing are what these are for.
@MainActor
enum PocketSnapshot {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panels: [(String, AnyView)] = [
            ("panel-01-mixer", AnyView(MixerSection(collapsible: false))),
            ("panel-02-system", AnyView(SystemSection(collapsible: false, showConnectedDevices: {}))),
            ("panel-03-network", AnyView(NetworkSection(collapsible: false))),
            ("panel-04-disk", AnyView(DiskSection(collapsible: false))),
            ("panel-05-power", AnyView(PowerSection(collapsible: false))),
            ("panel-06-toggles", AnyView(QuickTogglesSection(collapsible: false))),
            ("panel-07-controls", AnyView(QuickControlsSection(collapsible: false))),
            ("panel-08-reminders", AnyView(RemindersSection(collapsible: false))),
            ("panel-09-downloads", AnyView(DownloadsSection(collapsible: false))),
            ("panel-10-tasks", AnyView(TaskManagerSection(collapsible: false))),
            ("panel-11-clean", AnyView(CleanOptimizeSection(collapsible: false))),
            ("panel-12-display", AnyView(DisplaySection(collapsible: false))),
        ]
        for (name, view) in panels {
            save(view.padding(14).frame(width: 340), size: NSSize(width: 340, height: 900), name: name, dir: dir)
        }
        let pages = SettingsDirectory.sections(L10n.shared.s, language: L10n.shared.language)
            .flatMap(\.items)
            .filter { FeatureVisibilitySupport.isPageVisible($0.page, isAvailable: { $0.isAvailable }) }
        for (index, item) in pages.enumerated() {
            let name = String(format: "settings-%02d-%@", index, String(describing: item.page))
            save(SettingsPageContent(page: item.page).frame(width: 640, height: 1100),
                 size: NSSize(width: 640, height: 1100), name: name, dir: dir)
        }
        var titles = "Sidebar:\n"
        for section in SettingsDirectory.sidebarSections(L10n.shared.s, language: L10n.shared.language,
                                                         isAvailable: { $0.isAvailable }) {
            titles += "## \(section.title)\n" + section.items.map { "- \($0.title)  [\(String(describing: $0.destination.page))]" }.joined(separator: "\n") + "\n"
        }
        titles += "\nPanel tabs:\n" + PanelLayout.order.filter(\.isAvailable).map { "- \($0.title(L10n.shared.s))" }.joined(separator: "\n")
        try? titles.write(to: dir.appendingPathComponent("structure.txt"), atomically: true, encoding: .utf8)
        print("snapshots in \(dir.path)")
    }

    private static func save<V: View>(_ view: V, size: NSSize, name: String, dir: URL) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let fitting = hosting.fittingSize
        if fitting.height > 10, fitting.height < size.height {
            hosting.frame.size.height = fitting.height
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
