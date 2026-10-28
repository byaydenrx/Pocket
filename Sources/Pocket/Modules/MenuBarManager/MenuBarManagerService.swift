// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// Hides menu bar icons the way Hidden Bar and Ice do: a divider item that,
/// when collapsed, grows wide enough to push every icon to its left off the
/// screen. ⌘-drag icons to the left of the divider to hide them. An optional
/// second divider holds icons that stay hidden until ⌥-clicking the arrow.
@MainActor
final class MenuBarManagerService: NSObject {
    static let shared = MenuBarManagerService()

    enum Key {
        static let expandOnHover = "menuBarManagerHover"
        static let autoCollapse = "menuBarManagerAutoCollapse"   // seconds, 0 = never
        static let arrowSymbol = "menuBarManagerArrow"
        static let showDivider = "menuBarManagerShowDivider"
        static let alwaysHidden = "menuBarManagerAlwaysHidden"
        static let shortcut = "menuBarManagerShortcut"
    }

    static let arrowChoices: [(symbol: String, name: String)] = [
        ("chevron.left", "Arrow"), ("chevron.left.2", "Double Arrow"), ("ellipsis", "Dots"),
        ("circle.fill", "Dot"), ("line.3.horizontal", "Lines"), ("eye.slash", "Eye"),
    ]

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var alwaysItem: NSStatusItem?
    private(set) var expanded = false
    private var showingAlwaysHidden = false
    private var collapseTimer: Timer?
    private var hoverArea: NSTrackingArea?
    private lazy var hotKey = PocketHotKey(defaultsKey: Key.shortcut, fallback: nil) { [weak self] in self?.toggle() }

    private static let collapsedLength: CGFloat = 10_000

    func syncWithPreferences() {
        let on = AppFeature.menuBarManager.isAvailable
            && UserDefaults.standard.bool(forKey: "menuBarManagerEnabled")
        on ? start() : stop()
    }

    private func start() {
        if toggleItem == nil {
            // Created right to left: the arrow, then the divider to its left.
            let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            toggle.autosaveName = "PocketMenuBarManagerArrow"
            toggle.button?.target = self
            toggle.button?.action = #selector(toggleClicked)
            toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            toggleItem = toggle
            let divider = NSStatusBar.system.statusItem(withLength: 12)
            divider.autosaveName = "PocketMenuBarManagerDivider"
            dividerItem = divider
        }
        syncAlwaysHiddenItem()
        applyAppearance()
        installHover()
        hotKey.register()
        collapse()
    }

    private func stop() {
        hotKey.unregister()
        collapseTimer?.invalidate()
        for item in [toggleItem, dividerItem, alwaysItem].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        toggleItem = nil
        dividerItem = nil
        alwaysItem = nil
        expanded = false
    }

    func settingsChanged() {
        guard toggleItem != nil else { return }
        syncAlwaysHiddenItem()
        applyAppearance()
        installHover()
        hotKey.register()
        expanded ? expand() : collapse()
    }

    private func syncAlwaysHiddenItem() {
        let wanted = UserDefaults.standard.bool(forKey: Key.alwaysHidden)
        if wanted, alwaysItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
            item.autosaveName = "PocketMenuBarManagerAlwaysHidden"
            alwaysItem = item
        } else if !wanted, let alwaysItem {
            NSStatusBar.system.removeStatusItem(alwaysItem)
            self.alwaysItem = nil
        }
    }

    private func applyAppearance() {
        let symbol = UserDefaults.standard.string(forKey: Key.arrowSymbol) ?? "chevron.left"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Show hidden menu bar icons")?
            .withSymbolConfiguration(.init(pointSize: symbol == "circle.fill" ? 7 : 12, weight: .semibold))
        image?.isTemplate = true
        toggleItem?.button?.image = image
        let showDivider = UserDefaults.standard.object(forKey: Key.showDivider) as? Bool ?? true
        let line = NSImage(size: NSSize(width: 2, height: 14), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        line.isTemplate = true
        dividerItem?.button?.image = showDivider ? line : nil
        alwaysItem?.button?.image = nil
    }

    // MARK: Expanding

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true, alwaysItem != nil {
            showingAlwaysHidden.toggle()
            alwaysItem?.length = showingAlwaysHidden ? 0 : Self.collapsedLength
            expand()
        } else {
            toggle()
        }
    }

    func toggle() { expanded ? collapse() : expand() }

    private func expand() {
        expanded = true
        dividerItem?.length = 12
        updateArrow()
        scheduleAutoCollapse()
    }

    private func collapse() {
        expanded = false
        collapseTimer?.invalidate()
        dividerItem?.length = Self.collapsedLength
        if showingAlwaysHidden {
            showingAlwaysHidden = false
            alwaysItem?.length = Self.collapsedLength
        }
        updateArrow()
    }

    private func updateArrow() {
        // The arrow points the way the icons will move.
        let symbol = UserDefaults.standard.string(forKey: Key.arrowSymbol) ?? "chevron.left"
        let flips = symbol.hasPrefix("chevron")
        toggleItem?.button?.layer?.setAffineTransform(expanded && flips ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        toggleItem?.button?.wantsLayer = true
        toggleItem?.button?.appearsDisabled = false
    }

    private func scheduleAutoCollapse() {
        collapseTimer?.invalidate()
        let seconds = UserDefaults.standard.object(forKey: Key.autoCollapse) as? Double ?? 10
        guard seconds > 0 else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Not while the pointer is up in the menu bar using an icon.
                if NSEvent.mouseLocation.y > (NSScreen.main?.visibleFrame.maxY ?? 0) {
                    self.scheduleAutoCollapse()
                } else {
                    self.collapse()
                }
            }
        }
    }

    // MARK: Hover

    private func installHover() {
        guard let button = toggleItem?.button else { return }
        if let hoverArea { button.removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard UserDefaults.standard.bool(forKey: Key.expandOnHover) else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        button.addTrackingArea(area)
        hoverArea = area
    }

    @objc func mouseEntered(with event: NSEvent) {
        if !expanded { expand() }
    }

    @objc func mouseExited(with event: NSEvent) {}

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: expanded ? "Hide Icons" : "Show Icons", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "⌘-drag icons left of the divider to hide them", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let settings = NSMenuItem(title: "Menu Bar Manager Settings…", action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        toggleItem?.menu = menu
        toggleItem?.button?.performClick(nil)
        toggleItem?.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuSettings() { appDelegate()?.openSettings(page: .menuBarManager) }
}

struct MenuBarManagerSettings: View {
    @AppStorage("menuBarManagerEnabled") private var enabled = false
    @AppStorage(MenuBarManagerService.Key.expandOnHover) private var hover = false
    @AppStorage(MenuBarManagerService.Key.autoCollapse) private var autoCollapse = 10.0
    @AppStorage(MenuBarManagerService.Key.arrowSymbol) private var arrow = "chevron.left"
    @AppStorage(MenuBarManagerService.Key.showDivider) private var showDivider = true
    @AppStorage(MenuBarManagerService.Key.alwaysHidden) private var alwaysHidden = false

    private func changed() { MenuBarManagerService.shared.settingsChanged() }

    var body: some View {
        Form {
            Section {
                Toggle("Hide menu bar icons behind an arrow", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in MenuBarManagerService.shared.syncWithPreferences() }
                Text("Hold ⌘ and drag icons to the left of the divider (│) to hide them. Click the arrow to show them; right-click it for options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Show hidden icons when the pointer reaches the arrow", isOn: $hover)
                    .onChange(of: hover) { _, _ in changed() }
                HStack {
                    Text("Hide again after")
                    Slider(value: $autoCollapse, in: 0...60, step: 5)
                    Text(autoCollapse == 0 ? "Never" : "\(Int(autoCollapse)) s")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
                Toggle("Always-hidden section (⌥-click the arrow to reveal it)", isOn: $alwaysHidden)
                    .onChange(of: alwaysHidden) { _, _ in changed() }
            }
            .disabled(!enabled)
            Section("Look") {
                Picker("Arrow", selection: $arrow) {
                    ForEach(MenuBarManagerService.arrowChoices, id: \.symbol) { choice in
                        Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
                    }
                }
                .onChange(of: arrow) { _, _ in changed() }
                Toggle("Show the divider", isOn: $showDivider)
                    .onChange(of: showDivider) { _, _ in changed() }
            }
            .disabled(!enabled)
            Section("Shortcut") {
                PocketShortcutRow(title: "Show or hide icons", defaultsKey: MenuBarManagerService.Key.shortcut, fallback: nil) { changed() }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}
