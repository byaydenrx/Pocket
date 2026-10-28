// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Encore (MIT, © 2026 Byaydenrx).

import AppKit

/// Finds out whether the pointer is over Music's Dock icon, using the Dock's accessibility tree.
/// Needs Accessibility permission (System Settings › Privacy & Security › Accessibility).
@MainActor
final class DockNPDockWatcher {
    enum Edge { case bottom, left, right }

    private let systemWide = AXUIElementCreateSystemWide()
    private var dockPID: pid_t = 0
    private var dockApp: AXUIElement?
    /// The Dock's icon strip in AX coordinates (top-left origin), refreshed every couple of seconds.
    private var listFrame: CGRect?
    private var listFrameRead = Date.distantPast
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var lastResult: NSRect?

    private(set) var edge: Edge = .bottom

    var trusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The Music icon's frame in screen coordinates while the pointer is on it, otherwise nil.
    func musicIconUnderPointer() -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        let ax = CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)
        if ax == lastMouse { return lastResult }
        lastMouse = ax

        refreshDock()
        guard let listFrame, listFrame.insetBy(dx: -2, dy: -2).contains(ax) else {
            lastResult = nil
            return nil
        }
        lastResult = hitTest(ax, screenHeight: primary.frame.height)
        return lastResult
    }

    private func hitTest(_ point: CGPoint, screenHeight: CGFloat) -> NSRect? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        // The hit is usually the dock item itself; walk up a little in case it's a child of one.
        for _ in 0..<3 {
            if (string(element, kAXSubroleAttribute) ?? "").hasSuffix("DockItem") {
                guard isMusic(element), let frame = frame(of: element) else { return nil }
                return NSRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
            }
            guard let parent = value(element, kAXParentAttribute) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    private func isMusic(_ item: AXUIElement) -> Bool {
        if let url = value(item, kAXURLAttribute) as? URL {
            return url.lastPathComponent == "Music.app"
        }
        return string(item, kAXTitleAttribute) == "Music"
    }

    private func refreshDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            dockApp = nil
            listFrame = nil
            return
        }
        if dock.processIdentifier != dockPID {
            dockPID = dock.processIdentifier
            let app = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(app, 0.25)
            dockApp = app
            listFrameRead = .distantPast
        }
        guard Date().timeIntervalSince(listFrameRead) > 2, let dockApp else { return }
        listFrameRead = Date()
        let children = value(dockApp, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard let list = children.first(where: { string($0, kAXRoleAttribute) == "AXList" }),
              let frame = frame(of: list) else {
            listFrame = nil
            return
        }
        listFrame = frame
        if frame.width >= frame.height {
            edge = .bottom
        } else {
            let screen = NSScreen.screens.first { $0.frame.minX <= frame.midX && frame.midX <= $0.frame.maxX }
            edge = frame.midX < (screen?.frame.midX ?? 0) ? .left : .right
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success ? v : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = value(element, kAXPositionAttribute), let sv = value(element, kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
