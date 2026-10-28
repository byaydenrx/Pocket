// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Encore (MIT, © 2026 Byaydenrx).

import AppKit
import os

enum DockNPLog {
    private static let logger = Logger(subsystem: "com.byaydenrx.pocket", category: "dock-now-playing")
    static func write(_ message: String) { logger.debug("\(message, privacy: .public)") }
}

struct DockNPNowPlaying: Equatable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    var position: Double
    var playing: Bool
}

/// Talks to Music with AppleScript on its own queue, so a slow reply never stalls the panel.
/// Every call checks Music is already running first: a `tell` would otherwise launch it.
final class DockNPMusicBridge: @unchecked Sendable {
    static let bundleID = "com.apple.Music"
    private let queue = DispatchQueue(label: "com.byaydenrx.pocket.dock-now-playing")
    private var scripts: [String: NSAppleScript] = [:]

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static let stateSource = """
    tell application id "com.apple.Music"
        set playerState to player state as text
        if playerState is "stopped" then return {playerState}
        set trackID to ""
        set trackName to ""
        set trackArtist to ""
        set trackLength to 0
        set trackPosition to 0
        try
            set t to current track
            set trackID to persistent ID of t
            set trackName to name of t
            set trackArtist to artist of t
            set trackLength to duration of t
        end try
        try
            set trackPosition to player position
        end try
        return {playerState, trackID, trackName, trackArtist, trackLength, trackPosition}
    end tell
    """

    private static let artworkSource = """
    tell application id "com.apple.Music" to get raw data of artwork 1 of current track
    """

    /// Reads the current track; nil when Music isn't running, is stopped, or has nothing loaded.
    /// `ok` is false when the read itself failed, so the caller can keep what it already shows.
    func fetch(_ done: @escaping @MainActor (_ playing: DockNPNowPlaying?, _ ok: Bool) -> Void) {
        queue.async { [self] in
            guard DockNPMusicBridge.isRunning else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(nil, true) } }
                return
            }
            let reply = run(DockNPMusicBridge.stateSource)
            let result = parse(reply)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result, reply != nil) } }
        }
    }

    func artwork(_ done: @escaping @MainActor (NSImage?) -> Void) {
        queue.async { [self] in
            var image: NSImage?
            if DockNPMusicBridge.isRunning, let data = run(DockNPMusicBridge.artworkSource)?.data, !data.isEmpty {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(image) } }
        }
    }

    /// Sends a Music command such as `playpause`, `next track`, `back track` or `set player position to 42`.
    func send(_ command: String, then done: (@MainActor () -> Void)? = nil) {
        queue.async { [self] in
            if DockNPMusicBridge.isRunning { _ = run("tell application id \"com.apple.Music\" to \(command)") }
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
        }
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scripts[source] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            if !made.compileAndReturnError(&error) {
                DockNPLog.write("compile failed: \(error ?? [:])")
                return nil
            }
            // Seeks are one-off scripts (`set player position to 71.5`); don't let them pile up.
            if scripts.count > 16 { scripts.removeAll() }
            scripts[source] = made
            script = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1728 is "can't get artwork 1" for tracks without art; not worth logging.
            let number = error[NSAppleScript.errorNumber] as? Int
            if number != -1728 { DockNPLog.write("script error: \(error)") }
            // -609: the connection to Music went stale (it quit or restarted); recompile next time.
            if number == -609 { scripts.removeAll() }
            return nil
        }
        return result
    }

    private func parse(_ d: NSAppleEventDescriptor?) -> DockNPNowPlaying? {
        guard let d, d.numberOfItems >= 6 else { return nil }
        func string(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func number(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let title = string(3)
        guard !title.isEmpty else { return nil }
        let id = string(2).isEmpty ? "\(title)|\(string(4))" : string(2)
        return DockNPNowPlaying(id: id, title: title, artist: string(4), duration: number(5),
                          position: number(6), playing: string(1) == "playing")
    }
}
