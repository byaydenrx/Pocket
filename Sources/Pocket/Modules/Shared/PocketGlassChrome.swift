// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// Pocket's one glass: the system's own Liquid Glass view (`NSGlassEffectView`),
/// with no tint, plate or forced appearance on top. It follows the Mac's
/// Liquid Glass setting (Clear or Tinted) and light or dark mode by itself,
/// so every Pocket surface looks like the rest of macOS and like each other.
/// Before macOS 26 it falls back to the HUD material.
struct PocketGlass: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
#endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    func updateNSView(_ view: NSView, context: Context) {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
#endif
        view.layer?.cornerRadius = cornerRadius
    }
}

/// Popovers are already system Liquid Glass on macOS 26; Pocket leaves that
/// glass alone (an earlier build hid it and painted its own, which made the
/// menu panel look different from everything else).
enum PocketGlassChrome {
    static func clearSystemMaterial(of popover: NSPopover) {}
}
