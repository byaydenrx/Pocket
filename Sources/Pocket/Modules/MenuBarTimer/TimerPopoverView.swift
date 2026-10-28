// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tick (MIT, © 2026 Byaydenrx).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TimerPopoverView: View {
    static let width: CGFloat = 300

    @ObservedObject var model: TimerModel
    @ObservedObject var sounds: TimerSoundLibrary

    init(model: TimerModel) {
        self.model = model
        self.sounds = model.sounds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isActive {
                TimerCountdownHeader(model: model)
                Divider().opacity(0.5)
            }
            entry
            chips
            Divider().opacity(0.5)
            TimerSoundRow(sounds: sounds)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // The popover is sized to exactly what's here (measured, since fittingSize guesses too tall).
        .background(GeometryReader { geo in Color.clear.preference(key: TimerHeightKey.self, value: geo.size.height) })
        .onPreferenceChange(TimerHeightKey.self) { height in MainActor.assumeIsolated { model.onHeight?(height) } }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelGlassSurface()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, TimerSoundLibrary.isAudio(url) else { return }
                    DispatchQueue.main.async {
                        do { try sounds.add(url) } catch { sounds.alert("Pocket can’t play “\(url.lastPathComponent)”.") }
                    }
                }
            }
            return true
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TimerTimeField(model: model)
                    .frame(height: 26)
                if model.parsed != nil {
                    Button(action: model.submit) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Start (Return)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(model.invalid ? Color.red.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(model.invalid ? Color.red : Color.secondary)
                .lineLimit(1)
                .padding(.leading, 2)
        }
    }

    private var hint: String {
        if let r = model.parsed {
            let ends = r.until ?? Date().addingTimeInterval(r.seconds)
            let name = r.label.isEmpty ? "" : " · \(r.label)"
            return "\(TimerFormat.length(r.seconds))\(name) · rings at \(TimerFormat.time(ends))"
        }
        if model.invalid { return "Try 5, 25m, 1h30, 1:30, 90s or 3pm" }
        if model.isActive { return "Type a new time to replace this one" }
        return model.last.map { "Return to start · ↑ for \($0.title)" } ?? "Return to start · words after the time name it"
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(TimerModel.presets, id: \.self) { seconds in
                    TimerChip(title: TimerFormat.length(seconds), fill: true) { model.start(seconds) }
                }
            }
            if !model.recents.isEmpty {
                // One clock for the whole row, so four labelled chips still fit.
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Recent timers")
                    ForEach(model.recents, id: \.self) { recent in
                        TimerChip(title: recent.title, shrinks: true) { model.start(recent.seconds, label: recent.label) }
                            .help(recent.title)
                            .contextMenu { Button("Remove") { model.forget(recent) } }
                    }
                }
            }
        }
    }
}

// MARK: - Countdown

private struct TimerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TimerCountdownHeader: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(face)
                    .font(.system(size: 42, weight: .light, design: .rounded).monospacedDigit())
                    .opacity(paused ? 0.5 : 1)
                    .contentTransition(.numericText(countsDown: true))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if !model.label.isEmpty {
                        Text(model.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.primary.opacity(paused ? 0.35 : 0.75))
                        .frame(width: geo.size.width * (model.phase == .ringing ? 1 : model.progress))
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                if model.phase == .ringing {
                    TimerControl(title: "Stop", icon: "bell.slash.fill", prominent: true) { model.dismiss() }
                    TimerControl(title: "5 more", icon: "plus") { model.add(300) }
                } else {
                    TimerControl(title: paused ? "Resume" : "Pause", icon: paused ? "play.fill" : "pause.fill") { model.togglePause() }
                    TimerControl(title: "+1m", icon: nil) { model.add(60) }
                    TimerControl(title: "+5m", icon: nil) { model.add(300) }
                    Spacer()
                    TimerControl(title: "Stop", icon: "stop.fill") { model.stop() }
                }
            }
        }
    }

    private var paused: Bool {
        if case .paused = model.phase { return true }
        return false
    }

    private var face: String { model.phase == .ringing ? "0:00" : TimerFormat.clock(model.remaining) }

    private var status: String {
        switch model.phase {
        case .running(let end): "rings at \(TimerFormat.time(end))"
        case .paused: "paused"
        case .ringing: "time's up"
        case .idle: ""
        }
    }
}

// MARK: - TimerSound

struct TimerSoundRow: View {
    @ObservedObject var sounds: TimerSoundLibrary

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if !sounds.user.isEmpty {
                    Section("Your Sounds") {
                        ForEach(sounds.user) { item(for: $0) }
                    }
                }
                if !sounds.tones.isEmpty {
                    Section("Alarm Tones") {
                        ForEach(sounds.tones) { item(for: $0) }
                    }
                }
                Section("Short Alerts") {
                    ForEach(sounds.system) { item(for: $0) }
                }
                Divider()
                Button("Choose Sound File…") { sounds.choose() }
                if sounds.current.isUser {
                    Button("Remove “\(sounds.current.name)”") { sounds.remove(sounds.current) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "music.note")
                    Text(sounds.current.name).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Alarm sound · drop any MP3 or WAV here or on the menu bar icon")

            Button(action: sounds.togglePreview) {
                Image(systemName: sounds.previewing ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(sounds.previewing ? "Stop" : "Play")

            Spacer(minLength: 4)
            Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(sounds.volume) }, set: { sounds.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 70)
        }
    }

    private func item(for sound: TimerSound) -> some View {
        Button {
            sounds.select(sound)
        } label: {
            if sound.url == sounds.selected { Label(sound.name, systemImage: "checkmark") } else { Text(sound.name) }
        }
    }
}

// MARK: - Pieces

final class TimerHoverState: ObservableObject {
    @Published var on = false
}

struct TimerChip: View {
    let title: String
    var icon: String?
    /// Preset chips share the row evenly.
    var fill = false
    /// TimerRecent chips: a size smaller, and long titles truncate instead of spilling out of the chip.
    var shrinks = false
    let action: () -> Void
    @StateObject private var hover = TimerHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                if shrinks {
                    Text(title).font(.system(size: 11, weight: .medium).monospacedDigit()).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(title).lineLimit(1).fixedSize()
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .padding(.horizontal, fill ? 0 : shrinks ? 6 : 7)
            .frame(minWidth: fill ? 0 : 32, maxWidth: fill ? .infinity : nil, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover.on ? 0.16 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(TimerPressStyle())
        .onHover { hover.on = $0 }
    }
}

struct TimerControl: View {
    let title: String
    let icon: String?
    var prominent = false
    let action: () -> Void
    @StateObject private var hover = TimerHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(prominent ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color.white.opacity(hover.on ? 1 : 0.9) : Color.primary.opacity(hover.on ? 0.16 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(TimerPressStyle())
        .onHover { hover.on = $0 }
    }
}

struct TimerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// An AppKit field so Tick can put the cursor in it the moment the popover opens.
struct TimerTimeField: NSViewRepresentable {
    @ObservedObject var model: TimerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 18, weight: .medium)
        field.placeholderAttributedString = NSAttributedString(string: "5m, 1:30, 25m focus, 3pm", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        model.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.input { field.stringValue = model.input }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: TimerModel
        init(model: TimerModel) { self.model = model }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            MainActor.assumeIsolated { model.input = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)):
                    model.submit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    model.onEscape?()
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    // ↑ fills in the last timer, so Return runs it again.
                    if let last = model.last {
                        model.input = last.label.isEmpty ? TimerFormat.length(last.seconds) : "\(TimerFormat.length(last.seconds)) \(last.label)"
                        textView.string = model.input
                        textView.moveToEndOfDocument(nil)
                    }
                    return true
                default:
                    return false
                }
            }
        }
    }
}

// MARK: - Alarm banner

/// The card that drops in under the menu bar when time is up. Clicking it anywhere stops the alarm.
struct TimerAlarmView: View {
    static let size = NSSize(width: 290, height: 68)
    @ObservedObject var model: TimerModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.label.isEmpty ? "Time's up" : model.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(model.label.isEmpty ? "\(TimerFormat.length(model.total)) timer" : "Time's up · \(TimerFormat.length(model.total))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            TimerControl(title: "+5m", icon: nil) { model.add(300) }
            TimerControl(title: "Stop", icon: nil, prominent: true) { model.dismiss() }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(TimerPanelBackground())
        .contentShape(Rectangle())
        .onTapGesture { model.dismiss() }
        .environment(\.colorScheme, .dark)
    }
}

/// The alarm card's backdrop: the same glass as every other Pocket surface.
struct TimerPanelBackground: View {
    var body: some View {
        HUDBackdrop(cornerRadius: 18, contrast: .high)
    }
}
