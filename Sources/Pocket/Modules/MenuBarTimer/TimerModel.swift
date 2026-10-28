// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tick (MIT, © 2026 Byaydenrx).

import AppKit
import Foundation
import os

/// The timer keeps its own small settings domain so its keys never collide
/// with the rest of Pocket's.
enum TimerStore {
    static let defaults = UserDefaults(suiteName: "com.byaydenrx.pocket.timer") ?? .standard
}

enum TimerLog {
    private static let logger = Logger(subsystem: "com.byaydenrx.pocket", category: "timer")
    static func write(_ message: String) { logger.debug("\(message, privacy: .public)") }
}

// MARK: - Reading what was typed

struct TimerRequest: Equatable {
    var seconds: Double
    var label: String
    /// Set for "3pm" / "at 15:30" style input, so the preview can say "until 3:00 PM".
    var until: Date?
}

enum TimerParser {
    /// Reads "5", "25m", "1h30", "1h 30m", "90s", "2.5", "1:30", "1:02:00", "3pm", "3:30pm", "at 15:30",
    /// with anything after the time as the label ("5 tea", "25m focus").
    static func parse(_ text: String, now: Date = Date()) -> TimerRequest? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func label(after length: Int) -> String {
            String(original.dropFirst(length)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-·,:")))
        }

        // Clock times: "3pm", "3:30 pm", "at 7", "at 15:30".
        if let m = match(#"^(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, s) ?? match(#"^at\s*(\d{1,2})(?::(\d{2}))?\b"#, s) {
            var hour = Int(m.groups[0]!)!
            let minute = m.groups[1].flatMap { Int($0) } ?? 0
            let meridiem = m.groups.count > 2 ? m.groups[2] : nil
            guard minute < 60 else { return nil }
            if let meridiem {
                guard (1...12).contains(hour) else { return nil }
                if meridiem.hasPrefix("p"), hour != 12 { hour += 12 }
                if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
            }
            guard hour < 24 else { return nil }
            let calendar = Calendar.current
            guard var target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            // "at 7" without am/pm means the next 7 o'clock, morning or evening.
            if meridiem == nil, hour < 12, target <= now, let evening = calendar.date(byAdding: .hour, value: 12, to: target), evening > now {
                target = evening
            }
            if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target)! }
            return TimerRequest(seconds: target.timeIntervalSince(now).rounded(), label: label(after: m.length), until: target)
        }

        // "1:30" is minutes and seconds, "1:02:00" hours, minutes and seconds.
        if let m = match(#"^(\d+):(\d{1,2})(?::(\d{1,2}))?(?!\d)"#, s) {
            let parts = m.groups.compactMap { $0 }.map { Double($0)! }
            let seconds = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]
            guard seconds > 0 else { return nil }
            return TimerRequest(seconds: seconds, label: label(after: m.length))
        }

        // Numbers with optional units. A bare first number is minutes; a bare number after hours is minutes,
        // after minutes it's seconds ("1h 30", "5m 30").
        var total = 0.0
        var consumed = 0
        var lastUnit: Double?
        var rest = Substring(s)
        while let m = match(#"^\s*(\d+(?:\.\d+)?|\.\d+)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)?(?![a-z])"#, String(rest)) {
            let value = Double(m.groups[0]!)!
            let unit: Double
            if let u = m.groups[1]?.first {
                unit = u == "h" ? 3600 : u == "m" ? 60 : 1
            } else if lastUnit == nil || lastUnit == 3600 {
                unit = 60
            } else if lastUnit == 60 {
                unit = 1
            } else {
                // A bare number right after seconds isn't part of the time: it starts the label.
                break
            }
            total += value * unit
            lastUnit = unit
            consumed += m.length
            rest = rest.dropFirst(m.length)
            if m.groups[1] == nil { break }
        }
        guard consumed > 0, total >= 1 else { return nil }
        return TimerRequest(seconds: total.rounded(), label: label(after: consumed))
    }

    private struct Match { var length: Int; var groups: [String?] }

    private static func match(_ pattern: String, _ s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let r = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let groups = (1..<r.numberOfRanges).map { i -> String? in
            Range(r.range(at: i), in: s).map { String(s[$0]) }
        }
        return Match(length: r.range.length, groups: groups)
    }
}

enum TimerFormat {
    /// Countdown face: "4:59", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Short length: "25m", "1h 30m", "1m 30s", "45s".
    static func length(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 && h == 0 { parts.append("\(s)s") }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - The timer

struct TimerRecent: Codable, Equatable, Hashable {
    var seconds: Double
    var label: String
    var title: String { label.isEmpty ? TimerFormat.length(seconds) : "\(TimerFormat.length(seconds)) \(label)" }
}

enum TimerPhase: Equatable {
    case idle
    case running(end: Date)
    case paused(remaining: Double)
    case ringing
}

@MainActor
final class TimerModel: ObservableObject {
    static let presets: [Double] = [1, 5, 10, 15, 25, 45, 60].map { $0 * 60 }

    @Published private(set) var phase: TimerPhase = .idle
    @Published private(set) var total: Double = 0
    @Published private(set) var label = ""
    @Published private(set) var recents: [TimerRecent] = []
    /// Moves once a second while a timer runs, so the face redraws.
    @Published private(set) var now = Date()
    @Published var input = "" { didSet { if input != oldValue { invalid = false } } }
    @Published var invalid = false

    let sounds = TimerSoundLibrary()
    /// The menu bar redraws on every change.
    var onChange: (() -> Void)?
    var onStarted: (() -> Void)?
    var onRing: (() -> Void)?
    var onRingStopped: (() -> Void)?
    var onEscape: (() -> Void)?
    /// The popover's content height, reported by the view whenever it changes.
    var onHeight: ((CGFloat) -> Void)?
    weak var field: NSTextField?

    private var ticker: Timer?
    private var endTimer: Timer?
    private var activity: NSObjectProtocol?
    private var silenceTimer: Timer?

    init() {
        recents = (TimerStore.defaults.data(forKey: "recents")).flatMap { try? JSONDecoder().decode([TimerRecent].self, from: $0) } ?? []
        label = TimerStore.defaults.string(forKey: "label") ?? ""
        total = TimerStore.defaults.double(forKey: "total")
        let end = TimerStore.defaults.double(forKey: "end")
        let paused = TimerStore.defaults.double(forKey: "paused")
        if end > 0 {
            let date = Date(timeIntervalSince1970: end)
            // A timer that ran out while Tick was closed only rings if that was a moment ago.
            if date > Date() { phase = .running(end: date) } else if Date().timeIntervalSince(date) < 60 { phase = .running(end: Date()) }
        } else if paused > 0 {
            phase = .paused(remaining: paused)
        }
        if case .running = phase { schedule() }
    }

    var parsed: TimerRequest? { TimerParser.parse(input) }

    var remaining: Double {
        switch phase {
        case .idle, .ringing: 0
        case .running(let end): max(0, end.timeIntervalSince(now))
        case .paused(let r): r
        }
    }

    var progress: Double { total > 0 ? min(max(1 - remaining / total, 0), 1) : 0 }

    var endDate: Date? {
        if case .running(let end) = phase { return end }
        return nil
    }

    var isActive: Bool { phase != .idle }

    // MARK: Actions

    func submit() {
        guard let request = parsed else {
            invalid = !input.trimmingCharacters(in: .whitespaces).isEmpty
            NSSound.beep()
            return
        }
        start(request.seconds, label: request.label)
    }

    private var isTransitioning = false

    func start(_ seconds: Double, label: String = "") {
        isTransitioning = true
        defer { isTransitioning = false }
        stopRinging()
        total = seconds
        self.label = label
        now = Date()
        phase = .running(end: now.addingTimeInterval(seconds))
        input = ""
        remember(TimerRecent(seconds: seconds, label: label))
        schedule()
        save()
        TimerLog.write("start \(TimerFormat.length(seconds)) \(label)")
        onStarted?()
    }

    /// The last timer again (⌥-click the menu bar item, or ↑ in the field).
    var last: TimerRecent? {
        TimerStore.defaults.data(forKey: "last").flatMap { try? JSONDecoder().decode(TimerRecent.self, from: $0) }
    }

    func again() {
        guard let last else { return }
        start(last.seconds, label: last.label)
    }

    func togglePause() {
        switch phase {
        case .running:
            phase = .paused(remaining: remaining)
            unschedule()
        case .paused(let r):
            now = Date()
            phase = .running(end: now.addingTimeInterval(r))
            schedule()
        default: return
        }
        save()
    }

    func add(_ seconds: Double) {
        switch phase {
        case .running(let end):
            phase = .running(end: end.addingTimeInterval(seconds))
            total += seconds
            schedule()
        case .paused(let r):
            phase = .paused(remaining: r + seconds)
            total += seconds
        case .ringing, .idle:
            start(seconds, label: label)
            return
        }
        save()
    }

    func stop() {
        if case .ringing = phase {} else if pomodoroActive, !isTransitioning { pomodoroActive = false; pomodoroOnBreak = false }
        stopRinging()
        phase = .idle
        unschedule()
        save()
    }

    /// Silences the alarm; the timer is done. In a Pomodoro run the next
    /// phase (break or focus) starts right away.
    func dismiss() {
        let wasPomodoro = pomodoroActive
        stop()
        if wasPomodoro { pomodoroNext() }
    }

    // MARK: Pomodoro

    enum PomodoroKey {
        static let focus = "pomodoroFocusMinutes"
        static let shortBreak = "pomodoroBreakMinutes"
        static let longBreak = "pomodoroLongBreakMinutes"
        static let rounds = "pomodoroRounds"
        static let keepAwake = "pomodoroKeepAwake"
    }

    @Published private(set) var pomodoroActive = false
    @Published private(set) var pomodoroOnBreak = false
    /// Focus sessions finished in this run.
    @Published private(set) var pomodoroCompleted = 0

    private func minutes(_ key: String, _ fallback: Double) -> Double {
        let value = TimerStore.defaults.double(forKey: key)
        return (value > 0 ? value : fallback) * 60
    }

    func startPomodoro() {
        pomodoroActive = true
        pomodoroOnBreak = false
        pomodoroCompleted = 0
        startFocus()
    }

    func endPomodoro() {
        pomodoroActive = false
        pomodoroOnBreak = false
        stop()
        setKeepAwake(false)
    }

    private func startFocus() {
        pomodoroOnBreak = false
        start(minutes(PomodoroKey.focus, 25), label: "Focus \(pomodoroCompleted + 1)")
        pomodoroActive = true
        setKeepAwake(true)
    }

    private func pomodoroNext() {
        if pomodoroOnBreak {
            startFocus()
            return
        }
        pomodoroCompleted += 1
        let rounds = Int(TimerStore.defaults.double(forKey: PomodoroKey.rounds).rounded())
        let long = pomodoroCompleted % max(rounds > 0 ? rounds : 4, 1) == 0
        pomodoroOnBreak = true
        setKeepAwake(false)
        start(long ? minutes(PomodoroKey.longBreak, 15) : minutes(PomodoroKey.shortBreak, 5),
              label: long ? "Long Break" : "Break")
        pomodoroActive = true
    }

    private func setKeepAwake(_ on: Bool) {
        guard TimerStore.defaults.bool(forKey: PomodoroKey.keepAwake), AppFeature.keepAwake.isAvailable else { return }
        let manager = KeepAwakeManager.shared
        if on != manager.isActive { manager.toggle() }
    }

    // MARK: Ticking

    private func schedule() {
        unschedule()
        ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        if let end = endDate {
            endTimer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            endTimer?.tolerance = 0
            RunLoop.main.add(endTimer!, forMode: .common)
        }
        // Keeps App Nap from stretching the timers while Tick sits in the background.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Timer running")
        }
        tick()
    }

    private func unschedule() {
        ticker?.invalidate()
        ticker = nil
        endTimer?.invalidate()
        endTimer = nil
        if let activity, phase != .ringing {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        onChange?()
    }

    private func tick() {
        guard case .running(let end) = phase else { return }
        let date = Date()
        if date >= end {
            now = date
            ring()
            return
        }
        // Redraw only when the shown second changes.
        if Int(end.timeIntervalSince(date).rounded(.up)) != Int(end.timeIntervalSince(now).rounded(.up)) {
            now = date
            onChange?()
        }
    }

    private func ring() {
        phase = .ringing
        unschedule()
        save()
        sounds.startAlarm()
        TimerLog.write("ring \(label)")
        // TimerSound stops on its own after three minutes; the bell stays in the menu bar until dismissed.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sounds.stopAlarm() }
        }
        onRing?()
        onChange?()
    }

    private func stopRinging() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard phase == .ringing else { return }
        sounds.stopAlarm()
        TimerLog.write("alarm stopped")
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        onRingStopped?()
    }

    // MARK: Saving

    private func remember(_ recent: TimerRecent) {
        if let data = try? JSONEncoder().encode(recent) { TimerStore.defaults.set(data, forKey: "last") }
        // Plain presets are already one click away, so they don't fill up the recent row.
        if recent.label.isEmpty && Self.presets.contains(recent.seconds) { return }
        recents.removeAll { $0 == recent }
        recents.insert(recent, at: 0)
        recents = Array(recents.prefix(4))
        TimerStore.defaults.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    func forget(_ recent: TimerRecent) {
        recents.removeAll { $0 == recent }
        TimerStore.defaults.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    private func save() {
        TimerStore.defaults.set(label, forKey: "label")
        TimerStore.defaults.set(total, forKey: "total")
        TimerStore.defaults.set(endDate?.timeIntervalSince1970 ?? 0, forKey: "end")
        if case .paused(let r) = phase { TimerStore.defaults.set(r, forKey: "paused") } else { TimerStore.defaults.set(0.0, forKey: "paused") }
        onChange?()
    }
}
