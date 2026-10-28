// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit

/// One glass for every Pocket surface. Panels and cards draw `HUDBackdrop`
/// (the Dock card's look). Popovers would add the system's own frosted
/// balloon under it, which is what made the menu panel heavier than the Dock
/// card and the switcher; this takes that layer away so only Pocket's glass
/// shows. The popover still clips the content to its balloon and draws its
/// outline and shadow.
enum PocketGlassChrome {
    static func clearSystemMaterial(of popover: NSPopover) {
        guard LiquidGlassSupport.isSupported,
              UserDefaults.standard.bool(forKey: DefaultsKey.liquidGlassEnabled),
              let content = popover.contentViewController?.view,
              let frame = content.window?.contentView?.superview ?? content.superview
        else { return }
        hideMaterials(in: frame, keeping: content)
    }

    private static func hideMaterials(in view: NSView, keeping content: NSView) {
        for sub in view.subviews where sub !== content {
            if let effect = sub as? NSVisualEffectView, !effect.isDescendant(of: content) {
                effect.alphaValue = 0
            }
            if !sub.isDescendant(of: content) { hideMaterials(in: sub, keeping: content) }
        }
    }
}
