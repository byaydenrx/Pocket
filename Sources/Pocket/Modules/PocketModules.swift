// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// The features Pocket adds on top of the upstream catalog. Their strings are
/// plain English (Pocket ships in English only), kept here so a new module
/// touches as few shared files as possible. See docs/ADDING_FEATURES.md.
extension AppFeature {
    static let pocketModules: [AppFeature] = [.menuBarTimer, .downloads, .dockNowPlaying, .reminders, .storageAnalyzer]

    var isPocketModule: Bool { Self.pocketModules.contains(self) }

    var pocketTitle: String {
        switch self {
        case .menuBarTimer: return "Menu Bar Timer"
        case .downloads: return "Downloads"
        case .dockNowPlaying: return "Dock Now Playing"
        case .reminders: return "Reminders"
        case .storageAnalyzer: return "Storage Analyzer"
        default: return rawValue
        }
    }

    var pocketDescription: String {
        switch self {
        case .menuBarTimer:
            return "A countdown in the menu bar. Type 5, 25m focus, 1h30 or 3pm and press Return."
        case .downloads:
            return "Fast downloads through aria2: links, torrents and magnets, with connections, cookies and every aria2c option."
        case .dockNowPlaying:
            return "Hover the Music icon in the Dock to see what is playing, scrub and skip. Drag the card with ⌘ to pin it."
        case .reminders:
            return "Your Reminders lists in the menu panel: check off, add and see what is due."
        case .storageAnalyzer:
            return "See what takes up space on each drive, folder by folder, and move what you don't need to the Trash."
        default: return ""
        }
    }
}

extension SettingsPage {
    var pocketFeature: AppFeature? {
        switch self {
        case .menuBarTimer: return .menuBarTimer
        case .downloads: return .downloads
        case .dockNowPlaying: return .dockNowPlaying
        case .reminders: return .reminders
        case .storageAnalyzer: return .storageAnalyzer
        default: return nil
        }
    }
}
