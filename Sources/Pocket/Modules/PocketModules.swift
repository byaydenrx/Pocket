// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// The features Pocket adds on top of the upstream catalog. Their strings are
/// plain English (Pocket ships in English only), kept here so a new module
/// touches as few shared files as possible. See docs/ADDING_FEATURES.md.
extension AppFeature {
    static let pocketModules: [AppFeature] = [.menuBarTimer, .downloads, .dockNowPlaying, .reminders, .storageAnalyzer, .taskManager, .menuBarManager, .windowPin, .menuBarCalendar, .networkTools, .screenRuler, .cleanOptimize, .display]

    var isPocketModule: Bool { Self.pocketModules.contains(self) }

    var pocketTitle: String {
        switch self {
        case .menuBarTimer: return "Menu Bar Timer"
        case .downloads: return "Downloads"
        case .dockNowPlaying: return "Dock Now Playing"
        case .reminders: return "Reminders"
        case .storageAnalyzer: return "Storage Analyzer"
        case .taskManager: return "Task Manager"
        case .menuBarManager: return "Menu Bar Manager"
        case .windowPin: return "Window Pin"
        case .menuBarCalendar: return "Menu Bar Calendar"
        case .networkTools: return "Network Tools"
        case .screenRuler: return "Screen Ruler"
        case .cleanOptimize: return "Clean & Optimize"
        case .display: return "Display"

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
        case .taskManager:
            return "See which apps use the most CPU and memory and quit them in one click. System processes are never listed."
        case .menuBarManager:
            return "Tidy the menu bar: hide icons behind an arrow, keep some always hidden, show them on click or hover."
        case .windowPin:
            return "Keep any window on top as a floating live copy, and dim everything but the front window with Focus mode."
        case .menuBarCalendar:
            return "The date in the menu bar with a month view, today's events and world clocks."
        case .networkTools:
            return "Your local and public IP, Wi-Fi details, ping, a speed test and which apps use the network."
        case .screenRuler:
            return "Measure anything on screen in points and pick any pixel's color as HEX."
        case .cleanOptimize:
            return "Clear caches, logs and developer junk, then run upkeep: rebuild Spotlight, flush DNS, reset Quick Look and more."
        case .display:
            return "Resolution (with HiDPI), refresh rate, brightness for every screen, main display and mirroring."

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
        case .taskManager: return .taskManager
        case .menuBarManager: return .menuBarManager
        case .windowPin: return .windowPin
        case .menuBarCalendar: return .menuBarCalendar
        case .networkTools: return .networkTools
        case .screenRuler: return .screenRuler
        case .cleanOptimize: return .cleanOptimize
        case .display: return .display
        default: return nil
        }
    }
}
