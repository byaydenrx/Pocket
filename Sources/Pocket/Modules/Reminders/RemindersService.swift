// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import EventKit
import SwiftUI

/// One reminder as the panel shows it.
struct PocketReminder: Identifiable, Equatable {
    let id: String
    var title: String
    var notes: String?
    var due: Date?
    var hasTime: Bool
    var listID: String
    var listTitle: String
    var listColor: NSColor
    var priority: Int
    var completed: Bool

    var isOverdue: Bool {
        guard let due, !completed else { return false }
        return hasTime ? due < Date() : due < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let due else { return false }
        return Calendar.current.isDateInToday(due)
    }
}

/// Reads and writes Apple Reminders through EventKit. Nothing is loaded until
/// the feature is on; while on it refreshes only when Reminders changes
/// (EKEventStoreChanged), never on a timer.
@MainActor
final class RemindersService: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = RemindersService()

    enum Filter: String, CaseIterable, Identifiable {
        case today, scheduled, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .scheduled: return "Scheduled"
            case .all: return "All"
            }
        }
    }

    static let filterKey = "remindersFilter"
    static let listKey = "remindersList"
    static let menuBarKey = "remindersMenuBarItem"
    static let showCountKey = "remindersMenuBarCount"

    @Published private(set) var reminders: [PocketReminder] = []
    @Published private(set) var lists: [(id: String, title: String, color: NSColor)] = []
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var filter: Filter = Filter(rawValue: UserDefaults.standard.string(forKey: RemindersService.filterKey) ?? "") ?? .today {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey); refresh() }
    }
    /// nil shows every list.
    @Published var listID: String? = UserDefaults.standard.string(forKey: RemindersService.listKey) {
        didSet { UserDefaults.standard.set(listID, forKey: Self.listKey); refresh() }
    }

    private var store: EKEventStore?
    private var changeObserver: NSObjectProtocol?
    private var running = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    var hasAccess: Bool { access == .fullAccess }

    var dueCount: Int { reminders.filter { $0.isOverdue || $0.isDueToday }.count }

    func syncWithPreferences() {
        let enabled = AppFeature.reminders.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.remindersEnabled)
        enabled ? start() : stop()
        syncMenuBarItem()
    }

    private func start() {
        guard !running else { return }
        running = true
        let store = EKEventStore()
        self.store = store
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        access = EKEventStore.authorizationStatus(for: .reminder)
        if access == .notDetermined { requestAccess() } else { refresh() }
    }

    private func stop() {
        guard running else { return }
        running = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        store = nil
        reminders = []
        lists = []
    }

    func requestAccess() {
        guard let store else { return }
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = EKEventStore.authorizationStatus(for: .reminder)
                self.refresh()
            }
        }
    }

    func refresh() {
        guard running, let store, hasAccess else { updateStatusItem(); return }
        let calendars = store.calendars(for: .reminder)
        lists = calendars.map { ($0.calendarIdentifier, $0.title, $0.color ?? .systemBlue) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var chosen = calendars
        if let listID, let list = calendars.first(where: { $0.calendarIdentifier == listID }) { chosen = [list] }
        let predicate: NSPredicate
        switch filter {
        case .today:
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: chosen)
        case .scheduled:
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: .distantFuture, calendars: chosen)
        case .all:
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: chosen)
        }
        let filter = self.filter
        store.fetchReminders(matching: predicate) { [weak self] found in
            let items = (found ?? []).compactMap { reminder -> PocketReminder? in
                let components = reminder.dueDateComponents
                let due = components.flatMap { Calendar.current.date(from: $0) }
                if filter == .scheduled, due == nil { return nil }
                return PocketReminder(id: reminder.calendarItemIdentifier,
                                      title: reminder.title ?? "",
                                      notes: reminder.notes,
                                      due: due,
                                      hasTime: components?.hour != nil,
                                      listID: reminder.calendar.calendarIdentifier,
                                      listTitle: reminder.calendar.title,
                                      listColor: reminder.calendar.color ?? .systemBlue,
                                      priority: reminder.priority,
                                      completed: reminder.isCompleted)
            }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
            }
            DispatchQueue.main.async {
                self?.reminders = items
                self?.updateStatusItem()
            }
        }
    }

    func toggle(_ item: PocketReminder) {
        guard let store, let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        try? store.save(reminder, commit: true)
        if let index = reminders.firstIndex(of: item) {
            // Leave the checked row in place for a moment so the click reads.
            reminders[index].completed = reminder.isCompleted
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
        }
    }

    /// Adds a reminder. A date or time in the text ("call mom tomorrow 5pm")
    /// becomes its due date and is taken out of the title.
    func add(_ text: String) {
        guard let store, hasAccess else { return }
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let reminder = EKReminder(eventStore: store)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let date = match.date, let range = Range(match.range, in: title) {
            let words = String(title[range]).lowercased()
            let hasTime = words.contains(":") || words.contains("am") || words.contains("pm") || words.contains("noon")
                || words.range(of: #"\bat\b"#, options: .regularExpression) != nil
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            var parts: Set<Calendar.Component> = [.year, .month, .day]
            if hasTime { parts.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: date)
            if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        reminder.title = title.isEmpty ? text : title
        let listID = self.listID
        reminder.calendar = listID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewReminders()
        try? store.save(reminder, commit: true)
        refresh()
    }

    func openInReminders(_ item: PocketReminder? = nil) {
        if let item, let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(item.id)") {
            NSWorkspace.shared.open(url)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: Menu bar item

    private func syncMenuBarItem() {
        let wanted = running && UserDefaults.standard.bool(forKey: Self.menuBarKey)
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "PocketReminders"
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.imagePosition = .imageLeading
            statusItem = item
            popover.behavior = .transient
            popover.delegate = self
            let host = NSHostingController(rootView: RemindersPopover())
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            updateStatusItem()
        } else if !wanted, let statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            popover.contentViewController = nil
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Reminders")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        image?.isTemplate = true
        button.image = image
        let count = dueCount
        let showCount = UserDefaults.standard.object(forKey: Self.showCountKey) as? Bool ?? true
        button.title = showCount && count > 0 ? " \(count)" : ""
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
