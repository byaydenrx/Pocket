// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// Measure on screen: drag a box and read its size in points, or pick any
/// pixel's color and copy it as HEX. Both open from a shortcut and close with Esc.
@MainActor
final class ScreenRulerService {
    static let shared = ScreenRulerService()

    enum Key {
        static let rulerShortcut = "screenRulerShortcut"
        static let pickerShortcut = "pixelPickerShortcut"
        static let lastColors = "pixelPickerRecent"
    }

    static let defaultRulerShortcut = GlobalShortcut(keyCode: 15, modifiers: [.control, .option, .command]) // R
    static let defaultPickerShortcut = GlobalShortcut(keyCode: 8, modifiers: [.control, .option, .command])  // C

    private lazy var rulerKey = PocketHotKey(defaultsKey: Key.rulerShortcut, fallback: Self.defaultRulerShortcut) { [weak self] in self?.showRuler() }
    private lazy var pickerKey = PocketHotKey(defaultsKey: Key.pickerShortcut, fallback: Self.defaultPickerShortcut) { [weak self] in self?.pickColor() }
    private var overlays: [NSWindow] = []
    private var sampler: NSColorSampler?

    func syncWithPreferences() {
        if AppFeature.screenRuler.isAvailable {
            rulerKey.register()
            pickerKey.register()
        } else {
            rulerKey.unregister()
            pickerKey.unregister()
            closeRuler()
        }
    }

    func shortcutsChanged() { syncWithPreferences() }

    // MARK: Ruler

    func showRuler() {
        guard overlays.isEmpty else { closeRuler(); return }
        overlays = NSScreen.screens.map { screen in
            let window = RulerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = RulerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onClose = { [weak self] in self?.closeRuler() }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    func closeRuler() {
        guard !overlays.isEmpty else { return }
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        NSCursor.pop()
    }

    // MARK: Pixel picker

    func pickColor() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)),
                             Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            var recent = UserDefaults.standard.stringArray(forKey: Key.lastColors) ?? []
            recent.removeAll { $0 == hex }
            recent.insert(hex, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(12)), forKey: Key.lastColors)
            MainActor.assumeIsolated { self?.sampler = nil }
        }
    }
}

private final class RulerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Drag to draw a box; its size shows beside it. Shift locks a square,
/// Esc or a right-click closes, ⌘C copies "W × H".
private final class RulerView: NSView {
    var onClose: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var hover: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private var rect: NSRect? {
        guard let start, var end = current else { return nil }
        if NSEvent.modifierFlags.contains(.shift) {
            let side = max(abs(end.x - start.x), abs(end.y - start.y))
            end = NSPoint(x: start.x + (end.x >= start.x ? side : -side), y: start.y + (end.y >= start.y ? side : -side))
        }
        return NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func rightMouseDown(with event: NSEvent) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let rect {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(Int(rect.width)) × \(Int(rect.height))", forType: .string)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        let accent = NSColor.controlAccentColor
        if let hover, start == nil {
            accent.withAlphaComponent(0.6).setStroke()
            let h = NSBezierPath(); h.move(to: NSPoint(x: bounds.minX, y: hover.y)); h.line(to: NSPoint(x: bounds.maxX, y: hover.y))
            let v = NSBezierPath(); v.move(to: NSPoint(x: hover.x, y: bounds.minY)); v.line(to: NSPoint(x: hover.x, y: bounds.maxY))
            h.lineWidth = 0.5; v.lineWidth = 0.5; h.stroke(); v.stroke()
            label("Drag to measure · Shift = square · Esc to close", at: NSPoint(x: hover.x + 12, y: hover.y + 12))
        }
        guard let rect else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        accent.withAlphaComponent(0.18).setFill()
        rect.fill()
        accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        let diagonal = Int(hypot(rect.width, rect.height).rounded())
        label("\(Int(rect.width)) × \(Int(rect.height)) pt  ·  ↗ \(diagonal)", at: NSPoint(x: rect.maxX + 8, y: rect.minY - 24))
    }

    private func label(_ text: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = point
        origin.x = min(origin.x, bounds.maxX - size.width - 16)
        origin.y = max(min(origin.y, bounds.maxY - size.height - 12), bounds.minY + 8)
        let box = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: origin)
    }
}

struct ScreenRulerSettings: View {
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: ScreenRulerService.Key.lastColors) ?? []

    var body: some View {
        Form {
            Section {
                Text(AppFeature.screenRuler.pocketDescription).font(.callout)
                HStack {
                    Button("Measure Now") { ScreenRulerService.shared.showRuler() }
                    Button("Pick a Color") { ScreenRulerService.shared.pickColor() }
                }
            }
            Section("Shortcuts") {
                PocketShortcutRow(title: "Screen ruler", defaultsKey: ScreenRulerService.Key.rulerShortcut,
                                  fallback: ScreenRulerService.defaultRulerShortcut) { ScreenRulerService.shared.shortcutsChanged() }
                PocketShortcutRow(title: "Pick a pixel's color (copies HEX)", defaultsKey: ScreenRulerService.Key.pickerShortcut,
                                  fallback: ScreenRulerService.defaultPickerShortcut) { ScreenRulerService.shared.shortcutsChanged() }
            }
            if !recent.isEmpty {
                Section("Recent colors") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(recent, id: \.self) { hex in
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hex, forType: .string)
                            } label: {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 6).fill(Color(hexString: hex)).frame(height: 26)
                                    Text(hex).font(.caption2.monospaced())
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(hex)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { recent = UserDefaults.standard.stringArray(forKey: ScreenRulerService.Key.lastColors) ?? [] }
    }
}

private extension Color {
    init(hexString: String) {
        let value = Int(hexString.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
