// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import SwiftUI

/// The reminders list shared by the panel section and the menu bar popover.
struct RemindersList: View {
    @ObservedObject private var service = RemindersService.shared
    @State private var newText = ""
    var maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !service.hasAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pocket needs access to Reminders to show them here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(service.access == .notDetermined ? "Allow Access" : "Open Privacy Settings") {
                        if service.access == .notDetermined {
                            service.requestAccess()
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: $service.filter) {
                        ForEach(RemindersService.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Menu {
                        Button("All Lists") { service.listID = nil }
                        Divider()
                        ForEach(service.lists, id: \.id) { list in
                            Button(list.title) { service.listID = list.id }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(service.lists.first { $0.id == service.listID }?.title ?? "All Lists")
                }

                if service.reminders.isEmpty {
                    Text(service.filter == .today ? "Nothing due today." : "No reminders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(service.reminders.prefix(maxRows)) { item in
                            RemindersRow(item: item)
                        }
                    }
                    if service.reminders.count > maxRows {
                        Button("\(service.reminders.count - maxRows) more in Reminders…") { service.openInReminders() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                    TextField("New reminder, e.g. Call Sam tomorrow 5pm", text: $newText)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            service.add(newText)
                            newText = ""
                        }
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
    }
}

struct RemindersRow: View {
    let item: PocketReminder
    @ObservedObject private var service = RemindersService.shared
    @State private var hovering = false

    private var dueText: String? {
        guard let due = item.due else { return nil }
        let calendar = Calendar.current
        let time = item.hasTime ? due.formatted(date: .omitted, time: .shortened) : nil
        let day: String
        if calendar.isDateInToday(due) { day = "Today" }
        else if calendar.isDateInTomorrow(due) { day = "Tomorrow" }
        else if calendar.isDateInYesterday(due) { day = "Yesterday" }
        else { day = due.formatted(.dateTime.month(.abbreviated).day()) }
        return [day, time].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { service.toggle(item) } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color(nsColor: item.listColor))
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.priority > 0 && item.priority <= 4 ? "!!! " : item.priority == 5 ? "!! " : item.priority > 5 ? "! " : "") + item.title)
                    .lineLimit(2)
                    .strikethrough(item.completed)
                    .foregroundStyle(item.completed ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let dueText {
                        Text(dueText).foregroundStyle(item.isOverdue ? Color.red : Color.secondary)
                    }
                    if service.listID == nil {
                        Text(item.listTitle).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in Reminders") { service.openInReminders(item) }
            Button(item.completed ? "Mark as Not Completed" : "Mark as Completed") { service.toggle(item) }
        }
    }
}

/// Reminders tab in the menu panel.
struct RemindersSection: View {
    var collapsible = true

    var body: some View {
        PanelSection(.reminders, title: PanelSectionID.reminders.title(L10n.shared.s), collapsible: collapsible) {
            RemindersList()
        }
    }
}

/// The popover behind the optional Reminders menu bar item.
struct RemindersPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reminders").font(.headline)
                Spacer()
                Button { RemindersService.shared.openInReminders() } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Open Reminders")
            }
            RemindersList(maxRows: 14)
        }
        .padding(14)
        .frame(width: 320)
        .panelGlassSurface()
    }
}

struct RemindersSettings: View {
    @AppStorage(DefaultsKey.remindersEnabled) private var enabled = false
    @AppStorage(RemindersService.menuBarKey) private var menuBarItem = false
    @AppStorage(RemindersService.showCountKey) private var showCount = true
    @ObservedObject private var service = RemindersService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Reminders in the menu panel", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text(AppFeature.reminders.pocketDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Also show a Reminders icon in the menu bar", isOn: $menuBarItem)
                    .onChange(of: menuBarItem) { _, _ in service.syncWithPreferences() }
                Toggle("Show how many are due today or overdue", isOn: $showCount)
                    .onChange(of: showCount) { _, _ in service.refresh() }
                    .disabled(!menuBarItem)
            }
            .disabled(!enabled)
            Section("Adding") {
                Text("Type a date or time with the title and it becomes the due date: “Pay rent friday”, “Call Sam tomorrow 5pm”. New reminders go to the list you are viewing, or your default list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
