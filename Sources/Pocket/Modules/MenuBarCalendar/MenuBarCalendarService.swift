// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import EventKit
import SwiftUI

/// Date and time in the menu bar, your format, with a month, today's events
/// and world clocks in its popover. Ticks once a minute (once a second only
/// when the format shows seconds).
@MainActor
final class MenuBarCalendarService: NSObject, ObservableObject {
    static let shared = MenuBarCalendarService()

    enum Key {
        static let format = "menuBarCalendarFormat"
        static let clocks = "menuBarCalendarClocks"      // comma-separated time zone identifiers
        static let showIcon = "menuBarCalendarIcon"
    }

    static let formatPresets: [(name: String, format: String)] = [
        ("Tue 28 Oct  4:50", "EEE d MMM  H:mm"),
        ("Tue Oct 28  4:50 AM", "EEE MMM d  h:mm a"),
        ("Oct 28", "MMM d"),
        ("Tuesday", "EEEE"),
        ("28/10/26", "dd/MM/yy"),
        ("4:50:12 AM", "h:mm:ss a"),
        ("Icon only", ""),
    ]

    @Published private(set) var now = Date()
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var timer: Timer?
    private lazy var store = EKEventStore()
    private let formatter = DateFormatter()

    var format: String { UserDefaults.standard.string(forKey: Key.format) ?? "EEE d MMM  H:mm" }

    var clockZones: [TimeZone] {
        (UserDefaults.standard.string(forKey: Key.clocks) ?? "")
            .split(separator: ",").compactMap { TimeZone(identifier: String($0)) }
    }

    func syncWithPreferences() {
        let on = AppFeature.menuBarCalendar.isAvailable && UserDefaults.standard.bool(forKey: "menuBarCalendarEnabled")
        on ? start() : stop()
    }

    func settingsChanged() {
        guard statusItem != nil else { return }
        refreshTitle()
        scheduleTick()
    }

    private func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PocketMenuBarCalendar"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.hasFullSizeContent = PanelSurface.popoverHostsFullSizeContent
        let host = NSHostingController(rootView: CalendarPopoverView())
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        refreshTitle()
        scheduleTick()
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged), name: .NSCalendarDayChanged, object: nil)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        popover.contentViewController = nil
        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)
    }

    @objc private func dayChanged() { refreshTitle() }

    private func scheduleTick() {
        timer?.invalidate()
        let seconds = format.contains("s")
        let now = Date()
        let interval: TimeInterval = seconds ? 1 : 60
        let next = seconds ? now.addingTimeInterval(1 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1))
            : now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        let timer = Timer(fire: next, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        timer.tolerance = seconds ? 0.05 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshTitle() {
        now = Date()
        guard let button = statusItem?.button else { return }
        let format = self.format
        let showIcon = UserDefaults.standard.object(forKey: Key.showIcon) as? Bool ?? format.isEmpty
        if showIcon || format.isEmpty {
            let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = format.isEmpty ? .imageOnly : .imageLeading
        } else {
            button.image = nil
        }
        formatter.dateFormat = format
        let text = format.isEmpty ? "" : formatter.string(from: now)
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        now = Date()
        loadEvents()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        PocketGlassChrome.clearSystemMaterial(of: popover)
    }

    func requestCalendarAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.calendarAccess = EKEventStore.authorizationStatus(for: .event)
                self?.loadEvents()
            }
        }
    }

    func loadEvents(for day: Date = Date()) {
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        guard calendarAccess == .fullAccess else { events = []; return }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func setClocks(_ zones: [String]) {
        UserDefaults.standard.set(zones.joined(separator: ","), forKey: Key.clocks)
        objectWillChange.send()
    }
}

struct CalendarPopoverView: View {
    @ObservedObject private var service = MenuBarCalendarService.shared
    @State private var month = Date()
    @State private var selected = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Button("Today") { month = Date(); selected = Date(); service.loadEvents() }.buttonStyle(.borderless)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
            monthGrid
            Divider()
            eventsList
            if !service.clockZones.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(service.clockZones, id: \.identifier) { zone in
                        HStack {
                            Text(zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier)
                            Spacer()
                            Text(service.now.formatted(Date.FormatStyle(time: .shortened, timeZone: zone)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .panelGlassSurface()
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private var monthGrid: some View {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let symbols = Array(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1)...]
                            + calendar.veryShortStandaloneWeekdaySymbols[..<(calendar.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            ForEach(0..<(offset + days), id: \.self) { index in
                if index < offset {
                    Color.clear.frame(height: 24)
                } else {
                    let date = calendar.date(byAdding: .day, value: index - offset, to: start) ?? start
                    let isToday = calendar.isDateInToday(date)
                    let isSelected = calendar.isDate(date, inSameDayAs: selected)
                    Button {
                        selected = date
                        service.loadEvents(for: date)
                    } label: {
                        Text("\(index - offset + 1)")
                            .font(.system(size: 12, weight: isToday ? .bold : .regular).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(isToday ? Color.white : Color.primary)
                            .background(Circle().fill(isToday ? Color.accentColor : (isSelected ? Color.primary.opacity(0.12) : .clear)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var eventsList: some View {
        if service.calendarAccess != .fullAccess {
            Button("Show Calendar Events…") { service.requestCalendarAccess() }
                .buttonStyle(.link)
                .font(.callout)
        } else if service.events.isEmpty {
            Text(calendar.isDateInToday(selected) ? "Nothing on today." : "Nothing on \(selected.formatted(.dateTime.weekday(.wide).day().month())).")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(service.events.prefix(8), id: \.eventIdentifier) { event in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title ?? "").font(.callout).lineLimit(1)
                            Text(event.isAllDay ? "All day" : "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct MenuBarCalendarSettings: View {
    @AppStorage("menuBarCalendarEnabled") private var enabled = false
    @AppStorage(MenuBarCalendarService.Key.format) private var format = "EEE d MMM  H:mm"
    @AppStorage(MenuBarCalendarService.Key.showIcon) private var showIcon = false
    @ObservedObject private var service = MenuBarCalendarService.shared
    @State private var newZone = ""

    private func changed() { service.settingsChanged() }

    var body: some View {
        Form {
            Section {
                Toggle("Show the date in the menu bar", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("Click it for a month view, the day's events and your world clocks. You can hide the system clock in System Settings › Control Center › Clock Options.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Format") {
                Picker("Style", selection: $format) {
                    ForEach(MenuBarCalendarService.formatPresets, id: \.format) { Text($0.name).tag($0.format) }
                    if !MenuBarCalendarService.formatPresets.contains(where: { $0.format == format }) {
                        Text("Custom").tag(format)
                    }
                }
                .onChange(of: format) { _, _ in changed() }
                TextField("Custom format (Unicode date pattern)", text: $format)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { changed() }
                Toggle("Show a calendar icon", isOn: $showIcon)
                    .onChange(of: showIcon) { _, _ in changed() }
            }
            .disabled(!enabled)
            Section("World clocks") {
                ForEach(service.clockZones, id: \.identifier) { zone in
                    HStack {
                        Text(zone.identifier)
                        Spacer()
                        Button { service.setClocks(service.clockZones.map(\.identifier).filter { $0 != zone.identifier }) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Picker("Add", selection: $newZone) {
                    Text("Choose a time zone…").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: newZone) { _, zone in
                    guard !zone.isEmpty else { return }
                    service.setClocks(service.clockZones.map(\.identifier) + [zone])
                    newZone = ""
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}
