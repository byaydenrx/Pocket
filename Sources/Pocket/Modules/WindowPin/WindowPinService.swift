// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// Keeps windows "on top". macOS gives no app the power to float another
/// app's window, so a pinned window gets a live floating copy (ScreenCaptureKit)
/// that shows while you work elsewhere and steps aside the moment you click
/// it to use the real window. Focus mode dims everything behind the front window.
@MainActor
final class WindowPinService: NSObject {
    static let shared = WindowPinService()

    enum Key {
        static let pinShortcut = "windowPinShortcut"
        static let focusShortcut = "windowFocusShortcut"
        static let opacity = "windowPinOpacity"
        static let frameRate = "windowPinFrameRate"
        static let showBorder = "windowPinBorder"
        static let focusDim = "windowFocusDim"
        static let focusEnabled = "windowFocusEnabled"
    }

    static let defaultPinShortcut = GlobalShortcut(keyCode: 35, modifiers: [.control, .option, .command]) // P
    static let defaultFocusShortcut = GlobalShortcut(keyCode: 3, modifiers: [.control, .option, .command]) // F

    private lazy var pinKey = PocketHotKey(defaultsKey: Key.pinShortcut, fallback: Self.defaultPinShortcut) { [weak self] in self?.togglePinFrontWindow() }
    private lazy var focusKey = PocketHotKey(defaultsKey: Key.focusShortcut, fallback: Self.defaultFocusShortcut) { [weak self] in self?.toggleFocus() }
    private var pins: [CGWindowID: PinnedWindow] = [:]
    private var activationToken: NSObjectProtocol?
    private var running = false

    // Focus mode
    private var dimWindows: [NSWindow] = []
    private var focusTimer: Timer?
    private var lastFront: CGWindowID = 0

    func syncWithPreferences() {
        let on = AppFeature.windowPin.isAvailable && UserDefaults.standard.bool(forKey: "windowPinEnabled")
        on ? start() : stop()
    }

    func settingsChanged() {
        guard running else { return }
        pinKey.register()
        focusKey.register()
        for pin in pins.values { pin.applySettings() }
        if UserDefaults.standard.bool(forKey: Key.focusEnabled) { applyDim() }
    }

    private func start() {
        guard !running else { return }
        running = true
        pinKey.register()
        focusKey.register()
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivated() }
        }
        if UserDefaults.standard.bool(forKey: Key.focusEnabled) { startFocus() }
    }

    private func stop() {
        guard running else { return }
        running = false
        pinKey.unregister()
        focusKey.unregister()
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        for pin in pins.values { pin.close() }
        pins = [:]
        stopFocus()
    }

    // MARK: Pinning

    var pinnedCount: Int { pins.count }

    func togglePinFrontWindow() {
        guard running else { return }
        guard let (id, pid) = Self.frontWindow() else { NSSound.beep(); return }
        if let pin = pins.removeValue(forKey: id) {
            pin.close()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        let pin = PinnedWindow(windowID: id, pid: pid)
        pin.onClose = { [weak self] in self?.pins[id] = nil }
        pins[id] = pin
        pin.start()
    }

    func unpinAll() {
        for pin in pins.values { pin.close() }
        pins = [:]
    }

    private func appActivated() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for pin in pins.values { pin.ownerActivated(front == pin.pid) }
        if focusTimer != nil { refreshFocus() }
    }

    /// The frontmost normal window and its owner.
    static func frontWindow() -> (CGWindowID, pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = getpid()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 60 else { continue }
            return (id, pid)
        }
        return nil
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first, let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        // CG coordinates (top-left origin) to AppKit (bottom-left).
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Focus mode

    func toggleFocus() {
        let on = !UserDefaults.standard.bool(forKey: Key.focusEnabled)
        UserDefaults.standard.set(on, forKey: Key.focusEnabled)
        on ? startFocus() : stopFocus()
    }

    private func startFocus() {
        guard running, focusTimer == nil else { return }
        dimWindows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            return window
        }
        applyDim()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshFocus() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
        refreshFocus(force: true)
    }

    private func applyDim() {
        let dim = UserDefaults.standard.object(forKey: Key.focusDim) as? Double ?? 0.45
        for window in dimWindows { window.alphaValue = dim }
    }

    private func stopFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        for window in dimWindows { window.orderOut(nil) }
        dimWindows = []
        lastFront = 0
    }

    /// Keeps the dim layer just below whichever window is in front.
    private func refreshFocus(force: Bool = false) {
        guard let (front, _) = Self.frontWindow() else { return }
        guard force || front != lastFront else { return }
        lastFront = front
        for window in dimWindows { window.order(.below, relativeTo: Int(front)) }
    }
}

/// One pinned window's floating live copy.
@MainActor
final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let pid: pid_t
    var onClose: (() -> Void)?

    private var panel: NSPanel?
    private var imageLayer = CALayer()
    private var stream: SCStream?
    private var frameTimer: Timer?
    private let queue = DispatchQueue(label: "com.byaydenrx.pocket.window-pin")

    init(windowID: CGWindowID, pid: pid_t) {
        self.windowID = windowID
        self.pid = pid
    }

    func start() {
        guard let frame = WindowPinService.bounds(of: windowID) else { return }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = PinMirrorView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        imageLayer.frame = view.bounds
        imageLayer.contentsGravity = .resize
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        view.onClick = { [weak self] in self?.activateOriginal() }
        view.onClose = { [weak self] in self?.close() }
        panel.contentView = view
        self.panel = panel
        applySettings()
        Task { await startStream(size: frame.size) }
        // Follow the real window's moves and size.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        ownerActivated(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
    }

    func applySettings() {
        let opacity = UserDefaults.standard.object(forKey: WindowPinService.Key.opacity) as? Double ?? 1
        panel?.alphaValue = opacity
        let border = UserDefaults.standard.object(forKey: WindowPinService.Key.showBorder) as? Bool ?? true
        panel?.contentView?.layer?.borderWidth = border ? 2 : 0
        panel?.contentView?.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }

    private func startStream(size: CGSize) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { close(); return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            let fps = UserDefaults.standard.object(forKey: WindowPinService.Key.frameRate) as? Double ?? 30
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, fps)))
            config.showsCursor = false
            config.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            close()
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let object = surface as AnyObject
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.imageLayer.contents = object
            CATransaction.commit()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    private func follow() {
        guard let frame = WindowPinService.bounds(of: windowID) else { close(); return }
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
    }

    /// The real window is in front while its app is active; the copy only
    /// shows while you are somewhere else.
    func ownerActivated(_ active: Bool) {
        if active { panel?.orderOut(nil) } else { follow(); panel?.orderFrontRegardless() }
    }

    private func activateOriginal() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            for window in list where AXWindowResolver.windowID(for: window) == windowID {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }

    func close() {
        frameTimer?.invalidate()
        frameTimer = nil
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        panel?.orderOut(nil)
        panel = nil
        onClose?()
        onClose = nil
    }
}

private final class PinMirrorView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private var closeButton: NSButton?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard closeButton == nil else { return }
        let button = NSButton(image: NSImage(systemSymbolName: "pin.slash.fill", accessibilityDescription: "Unpin")!,
                              target: self, action: #selector(closeTapped))
        button.bezelStyle = .circular
        button.frame = NSRect(x: bounds.maxX - 36, y: bounds.maxY - 36, width: 28, height: 28)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(button)
        closeButton = button
    }

    override func mouseExited(with event: NSEvent) {
        closeButton?.removeFromSuperview()
        closeButton = nil
    }

    @objc private func closeTapped() { onClose?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct WindowPinSettings: View {
    @AppStorage("windowPinEnabled") private var enabled = false
    @AppStorage(WindowPinService.Key.opacity) private var opacity = 1.0
    @AppStorage(WindowPinService.Key.frameRate) private var fps = 30.0
    @AppStorage(WindowPinService.Key.showBorder) private var border = true
    @AppStorage(WindowPinService.Key.focusEnabled) private var focus = false
    @AppStorage(WindowPinService.Key.focusDim) private var dim = 0.45

    private func changed() { WindowPinService.shared.settingsChanged() }

    var body: some View {
        Form {
            Section {
                Toggle("Turn on Window Pin and Focus mode", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in WindowPinService.shared.syncWithPreferences() }
                Text("Pin keeps a live copy of the front window floating over everything while you use other apps; click the copy to jump back to the real window. Needs Screen Recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pin") {
                PocketShortcutRow(title: "Pin or unpin the front window", defaultsKey: WindowPinService.Key.pinShortcut,
                                  fallback: WindowPinService.defaultPinShortcut) { changed() }
                HStack {
                    Text("Opacity")
                    Slider(value: $opacity, in: 0.3...1)
                    Text("\(Int(opacity * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                .onChange(of: opacity) { _, _ in changed() }
                Picker("Frame rate", selection: $fps) {
                    Text("10 fps (lightest)").tag(10.0)
                    Text("30 fps").tag(30.0)
                    Text("60 fps (smoothest)").tag(60.0)
                }
                Toggle("Outline pinned windows", isOn: $border)
                    .onChange(of: border) { _, _ in changed() }
                Button("Unpin All") { WindowPinService.shared.unpinAll() }
            }
            .disabled(!enabled)
            Section("Focus mode") {
                Toggle("Dim everything behind the front window", isOn: $focus)
                    .onChange(of: focus) { _, on in
                        UserDefaults.standard.set(!on, forKey: WindowPinService.Key.focusEnabled)
                        WindowPinService.shared.toggleFocus()
                    }
                HStack {
                    Text("Dim")
                    Slider(value: $dim, in: 0.1...0.9)
                    Text("\(Int(dim * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                .onChange(of: dim) { _, _ in changed() }
                PocketShortcutRow(title: "Turn Focus mode on or off", defaultsKey: WindowPinService.Key.focusShortcut,
                                  fallback: WindowPinService.defaultFocusShortcut) { changed() }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}
