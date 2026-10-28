// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tick (MIT, © 2026 Byaydenrx): the timer keeps its own menu bar item.

import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Menu bar

/// Sits on top of the status item: click, ⌥-click, right-click, and audio files dropped on it.
final class TimerStatusView: NSView {
    var onClick: (() -> Void)?
    var onOptionClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onAudio: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(); return }
        if event.modifierFlags.contains(.option) { onOptionClick?(); return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    private func audio(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: TimerSoundLibrary.isAudio)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { audio(info) == nil ? [] : .copy }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let url = audio(info) else { return false }
        onAudio?(url)
        return true
    }
}

/// Lets the first click land on what it hits instead of just activating the window.
final class TimerFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class TimerAlarmPanel: NSPanel {
    init(model: TimerModel) {
        super.init(contentRect: NSRect(origin: .zero, size: TimerAlarmView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = TimerFirstClickHostingView(rootView: TimerAlarmView(model: model))
    }

    override var canBecomeKey: Bool { false }
}

/// The idle menu bar icon, picked from the right-click menu.
enum TimerMenuIcon {
    static let choices: [(symbol: String, name: String)] = [
        ("hourglass", "Hourglass"), ("timer", "Timer"), ("stopwatch", "Stopwatch"), ("clock", "Clock"),
        ("alarm", "Alarm Clock"), ("deskclock", "Desk Clock"), ("bell", "Bell"), ("cup.and.saucer", "Cup"),
        ("frying.pan", "Pan"), ("flame", "Flame"), ("leaf", "Leaf"), ("circle.fill", "Dot"),
    ].filter { NSImage(systemSymbolName: $0.0, accessibilityDescription: nil) != nil }

    static var current: String {
        let saved = TimerStore.defaults.string(forKey: "icon") ?? "hourglass"
        return choices.contains { $0.symbol == saved } ? saved : "hourglass"
    }

    static func image(_ symbol: String) -> NSImage? {
        // The dot is drawn smaller so it sits like a status light rather than a blob.
        let size: CGFloat = symbol == "circle.fill" ? 7 : 13
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Timer")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        image?.isTemplate = true
        return image
    }
}

@MainActor
final class MenuBarTimerService: NSObject, NSPopoverDelegate {
    static let shared = MenuBarTimerService()
    static let shortcutKey = "menuBarTimerShortcut"
    static let defaultShortcut = GlobalShortcut(keyCode: Int64(kVK_ANSI_T), modifiers: [.control, .option])

    private lazy var model = TimerModel()
    private var running = false
    private lazy var hotKey = PocketHotKey(defaultsKey: Self.shortcutKey, fallback: Self.defaultShortcut) { [weak self] in self?.hotKeyPressed() }
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hosting: NSHostingView<TimerPopoverView>?
    private lazy var alarm = TimerAlarmPanel(model: model)
    private var blink: Timer?
    private var outsideClickMonitor: Any?
    /// The app that was in front before the popover opened; it gets focus back after Return or Esc.
    private var previousApp: NSRunningApplication?
    private var contentHeight: CGFloat = 0

    var isRunning: Bool { running }

    func syncWithPreferences() {
        let enabled = AppFeature.menuBarTimer.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.menuBarTimerEnabled)
        enabled ? start() : stop()
        if running { hotKey.register() }
    }

    func shortcutChanged() {
        if running { hotKey.register() }
    }

    private func start() {
        guard !running else { return }
        running = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PocketMenuBarTimer"
        statusItem = item
        let button = item.button!
        button.imagePosition = .imageLeading
        let overlay = TimerStatusView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.clicked() }
        overlay.onOptionClick = { [weak self] in self?.model.again() }
        overlay.onRightClick = { [weak self] in self?.showMenu() }
        overlay.onAudio = { [weak self] url in
            guard let self else { return }
            do { try self.model.sounds.add(url) } catch { self.model.sounds.alert("Pocket can’t play “\(url.lastPathComponent)”.") }
            self.showPopover()
        }
        button.addSubview(overlay)

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let host = TimerFirstClickHostingView(rootView: TimerPopoverView(model: model))
        host.sizingOptions = []
        hosting = host
        let controller = NSViewController()
        controller.view = host
        popover.contentViewController = controller
        fitPopover()

        model.onChange = { [weak self] in self?.refresh() }
        model.onStarted = { [weak self] in self?.closePopover(returnFocus: true) }
        model.onEscape = { [weak self] in self?.closePopover(returnFocus: true) }
        model.onHeight = { [weak self] height in
            guard let self, height > 0 else { return }
            self.contentHeight = ceil(height)
            self.fitPopover()
        }
        model.onRing = { [weak self] in self?.showAlarm() }
        model.onRingStopped = { [weak self] in self?.hideAlarm() }
        refresh()
        TimerLog.write("menu bar timer started")
    }

    /// Takes the item out of the menu bar. A running timer keeps its end date
    /// in the timer's defaults and resumes when the feature comes back.
    private func stop() {
        guard running else { return }
        running = false
        hotKey.unregister()
        closePopover(returnFocus: false)
        hideAlarm()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        hosting = nil
        popover.contentViewController = nil
    }

    /// Opens the timer popover from elsewhere in Pocket (panel, Command Bar).
    func open() {
        guard running else { return }
        popover.isShown ? closePopover(returnFocus: true) : showPopover()
    }

    // MARK: Status item

    private func refresh() {
        guard let button = statusItem?.button else { return }
        // While a timer counts down only the time shows; the icon comes back when it's idle.
        var symbol: String?
        var title = ""
        var paused = false
        switch model.phase {
        case .idle: symbol = TimerMenuIcon.current
        case .running: title = TimerFormat.clock(model.remaining)
        case .paused: title = TimerFormat.clock(model.remaining); paused = true
        case .ringing: symbol = "bell.fill"; title = "0:00"
        }
        if button.image?.name() != symbol {
            let image = symbol.flatMap { TimerMenuIcon.image($0) }
            image?.setName(symbol)
            button.image = image
        }
        button.imagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .baselineOffset: 0.5,
            .foregroundColor: paused ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if button.attributedTitle != text { button.attributedTitle = text }
        if popover.isShown { fitPopover() }
    }

    private func clicked() {
        if model.phase == .ringing { model.dismiss(); return }
        popover.isShown ? closePopover(returnFocus: true) : showPopover()
    }

    private func hotKeyPressed() {
        if model.phase == .ringing { model.dismiss(); return }
        popover.isShown ? closePopover(returnFocus: true) : showPopover()
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        switch model.phase {
        case .ringing:
            add("Stop Alarm", #selector(menuStop))
        case .running, .paused:
            if case .paused = model.phase { add("Resume", #selector(menuPause)) } else { add("Pause", #selector(menuPause)) }
            add("Add 5 Minutes", #selector(menuAddFive))
            add("Stop", #selector(menuStop))
        case .idle:
            if let last = model.last { add("Again: \(last.title)", #selector(menuAgain)) }
        }
        menu.addItem(.separator())
        add("Choose Alarm Sound…", #selector(menuChooseSound))
        let icons = NSMenu()
        for choice in TimerMenuIcon.choices {
            let item = NSMenuItem(title: choice.name, action: #selector(menuIcon(_:)), keyEquivalent: "")
            item.target = self
            item.image = TimerMenuIcon.image(choice.symbol)
            item.representedObject = choice.symbol
            item.state = choice.symbol == TimerMenuIcon.current ? .on : .off
            icons.addItem(item)
        }
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = icons
        menu.addItem(iconItem)
        let hint = NSMenuItem(title: "Open: \(hotKey.shortcut?.displayString ?? "no shortcut")   Repeat last: ⌥-click", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        add("Timer Settings…", #selector(menuSettings))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuStop() { model.stop() }
    @objc private func menuPause() { model.togglePause() }
    @objc private func menuAddFive() { model.add(300) }
    @objc private func menuAgain() { model.again() }
    @objc private func menuChooseSound() { model.sounds.choose() }

    @objc private func menuIcon(_ item: NSMenuItem) {
        guard let symbol = item.representedObject as? String else { return }
        TimerStore.defaults.set(symbol, forKey: "icon")
        refresh()
    }

    @objc private func menuSettings() {
        appDelegate()?.openSettings(page: .menuBarTimer)
    }

    // MARK: Popover

    private func fitPopover() {
        guard let hosting else { return }
        let size = NSSize(width: TimerPopoverView.width, height: contentHeight > 0 ? contentHeight : ceil(hosting.fittingSize.height))
        if popover.contentSize != size {
            hosting.frame = NSRect(origin: .zero, size: size)
            popover.contentSize = size
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        model.invalid = false
        fitPopover()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            if let field = model.field { window.makeFirstResponder(field) }
        }
        // Clicking in another app closes the popover, but not when the press turns into a drag
        // (so an audio file can be dragged from Finder into it).
        var downAt: NSPoint?
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let here = NSEvent.mouseLocation
                switch event.type {
                case .leftMouseDown: downAt = here
                case .leftMouseDragged:
                    if let start = downAt, hypot(here.x - start.x, here.y - start.y) > 4 { downAt = nil }
                case .leftMouseUp:
                    if downAt != nil { self.closePopover(returnFocus: false) }
                    downAt = nil
                default: self.closePopover(returnFocus: false)
                }
            }
        }
    }

    private func closePopover(returnFocus: Bool) {
        guard popover.isShown else { return }
        popover.performClose(nil)
        if returnFocus, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        statusItem?.button?.highlight(false)
        model.input = ""
        model.invalid = false
    }

    // MARK: Alarm

    private func showAlarm() {
        closePopover(returnFocus: false)
        let size = TimerAlarmView.size
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = visible.maxX - size.width - 10
        if let frame = statusItem?.button?.window?.frame, frame.maxX > visible.minX, frame.minX < visible.maxX {
            x = min(max(frame.maxX - size.width, visible.minX + 10), visible.maxX - size.width - 10)
        }
        alarm.setFrame(NSRect(x: x, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        alarm.alphaValue = 0
        alarm.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; alarm.animator().alphaValue = 1 }
        var on = true
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                on.toggle()
                self?.statusItem?.button?.alphaValue = on ? 1 : 0.3
            }
        }
    }

    private func hideAlarm() {
        blink?.invalidate()
        blink = nil
        statusItem?.button?.alphaValue = 1
        guard alarm.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; alarm.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated { self?.alarm.orderOut(nil) }
        }
    }
}

