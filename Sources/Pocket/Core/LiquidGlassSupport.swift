// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Detection and settings gate for Liquid Glass visuals on macOS 26 and later.
enum LiquidGlassSupport {
    /// Whether the host operating system supports native Liquid Glass.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Select the preference for the surface that owns the mixer.
    static func isEnabled(inNotch: Bool, windows: Bool, island: Bool) -> Bool {
        guard isSupported else { return false }
        return inNotch ? island : windows
    }
}

// MARK: - Glass style (Pocket)

/// How see-through Pocket's Liquid Glass surfaces are. `clear` matches the
/// system's Clear Liquid Glass look; `tinted` is the frostier regular glass.
enum GlassStyle: String, CaseIterable, Identifiable {
    case clear, tinted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .tinted: return "Tinted"
        }
    }

    static func sanitized(_ raw: String?) -> GlassStyle {
        raw.flatMap(GlassStyle.init(rawValue:)) ?? .clear
    }
}

extension LiquidGlassSupport {
    /// One knob for every glass surface: the switcher, shelf, Dock previews,
    /// the menu panel and the radial menu all read these two values.
    static let styleKey = "glassStyle"
    /// 0...0.8 of a dark (or light) plate laid over the glass, for readability.
    static let tintKey = "glassTintOpacity"
    /// Enough plate that text always reads, while the glass still shows.
    static let defaultTint = 0.35

    /// Every surface uses this one plate, so the panel, switcher, shelf,
    /// cards and popovers all read the same. `fallback` is ignored on purpose:
    /// surfaces used to pick their own and ended up looking different.
    static func plateOpacity(styleRaw: String?, tint: Double, fallback: Double) -> Double {
        min(max(tint, 0.12), 0.85)
    }
}

#if compiler(>=6.2)
import SwiftUI

@available(macOS 26.0, *)
extension LiquidGlassSupport {
    static func glass(styleRaw: String?) -> Glass {
        GlassStyle.sanitized(styleRaw) == .clear ? .clear : .regular
    }
}
#endif
