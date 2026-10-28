// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Encore (MIT, © 2026 Byaydenrx): the now playing card over Music's Dock icon.

import AppKit
import SwiftUI

/// Shows the panel above Music's Dock icon while the pointer is on the icon or the panel.
@MainActor
final class DockNowPlayingService {
    static let shared = DockNowPlayingService()
    private var running = false
    private var playerObserver: NSObjectProtocol?
    /// 20 Hz near the Dock or while the card is up, 4 Hz everywhere else.
    private var interval: TimeInterval = 0

    private(set) lazy var model = DockNPPlayerModel()
    private lazy var dock = DockNPDockWatcher()
    private lazy var panel = DockNPEncorePanel(model: model)
    private var timer: Timer?
    private var shown = false
    private var trusted = false
    private var iconFrame: NSRect?
    private var hoverSince: Date?
    private var askedThisHover = false
    private var leftAt: Date?
    private var tickCount = 0
    private var previewing = false
    /// Left somewhere with ⌘ held: stays put and stops following the Dock hover.
    private var pinned = false
    /// Panel origin and pointer where the current drag started.
    private var dragFrom: (origin: NSPoint, mouse: NSPoint)?

    var isRunning: Bool { running }

    func syncWithPreferences() {
        let enabled = AppFeature.dockNowPlaying.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.dockNowPlayingEnabled)
        enabled ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        running = true
        model.onDrag = { [weak self] translation, ended in self?.drag(translation, ended: ended) }
        model.onClose = { [weak self] in self?.hide() }
        trusted = dock.trusted
        if !trusted { dock.requestAccess() }
        // Music posts this on every play, pause and track change.
        playerObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.shown { self.model.refresh() }
            }
        }
        retime(0.25)
        DockNPLog.write("Encore started; accessibility: \(trusted), Music running: \(DockNPMusicBridge.isRunning)")
    }

    private func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        interval = 0
        if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver) }
        playerObserver = nil
        hide()
    }

    private func retime(_ seconds: TimeInterval) {
        guard running, seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = seconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Whether the pointer is within reach of the Dock's screen edge, where
    /// hover detection needs its full rate.
    private func pointerNearDock() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return false }
        let frame = screen.frame
        let reach: CGFloat = 160
        switch dock.edge {
        case .bottom: return mouse.y < frame.minY + reach
        case .left: return mouse.x < frame.minX + reach
        case .right: return mouse.x > frame.maxX - reach
        }
    }

    /// Shows the panel in the middle of the screen with live data, for checking the look.
    func preview() {
        previewing = true
        guard let screen = NSScreen.main?.visibleFrame else { return }
        model.refresh { [self] in
            panel.setFrameOrigin(NSPoint(x: screen.midX - DockNPEncoreView.size.width / 2, y: screen.midY))
            shown = true
            appear()
        }
    }

    /// The card follows the pointer. Let go with ⌘ held and it stays there; otherwise it goes away.
    private func drag(_ translation: CGSize, ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended {
            guard dragFrom != nil else { return }
            dragFrom = nil
            if commandHeld() { pin() } else { hide() }
            return
        }
        // The gesture only starts after a few points of movement; count those too (SwiftUI's y points down).
        let from = dragFrom ?? (panel.frame.origin, NSPoint(x: mouse.x - translation.width, y: mouse.y + translation.height))
        dragFrom = from
        leftAt = nil
        panel.setFrameOrigin(NSPoint(x: from.origin.x + mouse.x - from.mouse.x, y: from.origin.y + mouse.y - from.mouse.y))
        dragHint()
    }

    /// Dimmed while a drop would dismiss the card, solid while ⌘ is held.
    private func dragHint() {
        let alpha: CGFloat = commandHeld() ? 1 : 0.55
        if panel.alphaValue != alpha { panel.animator().alphaValue = alpha }
    }

    /// ⌘ as the mouse event being handled saw it, or the keyboard right now.
    private func commandHeld() -> Bool {
        if let event = NSApp.currentEvent, [.leftMouseDragged, .leftMouseUp].contains(event.type),
           event.modifierFlags.contains(.command) { return true }
        return NSEvent.modifierFlags.contains(.command)
    }

    private func pin() {
        pinned = true
        model.pinned = true
        panel.level = .statusBar
        // Keep the whole card on the screen it was dropped on.
        let mouse = NSEvent.mouseLocation
        if let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            var frame = panel.frame
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - frame.height - 8)
            panel.setFrame(frame.integral, display: true, animate: true)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        DockNPLog.write("card pinned at \(Int(panel.frame.minX)),\(Int(panel.frame.minY))")
    }

    private func tick() {
        retime(shown || pinned || dragFrom != nil || pointerNearDock() ? 0.05 : 0.25)
        tickCount += 1
        if dragFrom != nil {
            // A gesture that never reports its end (e.g. cancelled by the system) still finishes here.
            if NSEvent.pressedMouseButtons & 1 == 0 { drag(.zero, ended: true) } else { dragHint() }
        }
        if pinned {
            let over = panel.frame.contains(NSEvent.mouseLocation)
            if model.hovering != over { model.hovering = over }
        }
        if previewing {
            model.tick()
            if tickCount % 20 == 0 { model.refresh() }
            return
        }
        if !trusted {
            if tickCount % 20 == 0, dock.trusted {
                trusted = true
                DockNPLog.write("accessibility granted")
            }
            return
        }

        var icon = dock.musicIconUnderPointer()
        if icon != nil && !DockNPMusicBridge.isRunning { icon = nil }

        if pinned || dragFrom != nil {
            // Off the Dock's leash: neither hovering the icon nor leaving the card moves or hides it.
            leftAt = nil
        } else if let icon {
            iconFrame = icon
            leftAt = nil
            if shown {
                place()
            } else {
                if hoverSince == nil { hoverSince = Date() }
                // A short dwell so sweeping across the Dock doesn't flash the panel; one read of Music per hover.
                if !askedThisHover, Date().timeIntervalSince(hoverSince!) >= 0.12 {
                    askedThisHover = true
                    model.refresh { [weak self] in
                        guard let self, hoverSince != nil, model.now != nil else { return }
                        show()
                    }
                }
            }
        } else {
            hoverSince = nil
            if shown {
                if keepOpen() {
                    leftAt = nil
                } else if let leftAt {
                    if Date().timeIntervalSince(leftAt) > 0.3 { hide() }
                } else {
                    leftAt = Date()
                }
            } else {
                askedThisHover = false
            }
        }

        if shown {
            if model.now == nil { hide(); return }
            model.tick()
            if tickCount % 20 == 0 { model.refresh() }
        }
    }

    /// True while the pointer is on the panel, crossing the gap between icon and panel, or dragging the timeline.
    private func keepOpen() -> Bool {
        if model.scrub != nil { return true }
        let mouse = NSEvent.mouseLocation
        let card = panel.frame
        if card.insetBy(dx: -6, dy: -6).contains(mouse) { return true }
        guard let icon = iconFrame else { return false }
        let gap: NSRect
        switch dock.edge {
        case .bottom: gap = NSRect(x: card.minX, y: icon.maxY - 4, width: card.width, height: card.minY - icon.maxY + 8)
        case .left: gap = NSRect(x: icon.maxX - 4, y: card.minY, width: card.minX - icon.maxX + 8, height: card.height)
        case .right: gap = NSRect(x: card.maxX - 4, y: card.minY, width: icon.minX - card.maxX + 8, height: card.height)
        }
        return gap.contains(mouse)
    }

    private func show() {
        place()
        guard !shown else { return }
        shown = true
        leftAt = nil
        appear()
    }

    private func appear() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Above the icon, clear of the Dock's own name label (or beside it for a side Dock).
    private func place() {
        guard let icon = iconFrame else { return }
        let size = DockNPEncoreView.size
        var origin: NSPoint
        switch dock.edge {
        case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: icon.maxY + 44)
        case .left: origin = NSPoint(x: icon.maxX + 14, y: icon.midY - size.height / 2)
        case .right: origin = NSPoint(x: icon.minX - 14 - size.width, y: icon.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) })?.frame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        let frame = NSRect(origin: origin, size: size).integral
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        askedThisHover = false
        model.scrub = nil
        pinned = false
        model.pinned = false
        model.hovering = false
        dragFrom = nil
        panel.level = .popUpMenu
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }
}

