// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Encore (MIT, © 2026 Byaydenrx).

import AppKit
import SwiftUI

@MainActor
final class DockNPPlayerModel: ObservableObject {
    @Published var now: DockNPNowPlaying?
    @Published var artwork: NSImage?
    @Published var position: Double = 0
    /// 0…1 while the timeline is being dragged.
    @Published var scrub: Double?
    /// Dropped with ⌘ held: the card stays where it was left, like picture-in-picture.
    @Published var pinned = false
    @Published var hovering = false
    /// Called while the card is dragged by its background: the gesture's translation, and whether the mouse came up.
    var onDrag: (@MainActor (CGSize, Bool) -> Void)?
    var onClose: (@MainActor () -> Void)?

    let music = DockNPMusicBridge()
    private var artworkID: String?
    private var basePosition = 0.0
    private var baseDate = Date()
    /// Bumped by every command, so reads that were already queued before it are dropped.
    private var commands = 0
    /// Right after play/pause Music can still report the old state for a moment; trust the button until then.
    private var expectedPlaying: Bool?
    private var expectedUntil = Date.distantPast

    func refresh(_ done: (() -> Void)? = nil) {
        let issued = commands
        music.fetch { [weak self] playing, ok in
            guard let self else { return }
            if ok, issued == commands { apply(playing) }
            done?()
        }
    }

    func apply(_ read: DockNPNowPlaying?) {
        guard var playing = read else {
            now = nil
            return
        }
        if let expectedPlaying, Date() < expectedUntil, playing.id == now?.id, playing.playing != expectedPlaying {
            playing.playing = expectedPlaying
            playing.position = position
        }
        // While paused, a read a fraction of a second behind the timeline would only make it jump back.
        if !playing.playing, playing.id == now?.id, now?.playing == false, abs(playing.position - position) < 1.5 {
            playing.position = position
        }
        now = playing
        basePosition = playing.position
        baseDate = Date()
        if scrub == nil { position = playing.position }
        if playing.id != artworkID {
            artworkID = playing.id
            artwork = nil
            music.artwork { [weak self] image in
                guard let self, artworkID == playing.id else { return }
                artwork = image
            }
        }
    }

    /// Moves the timeline along between reads from Music.
    func tick() {
        guard let now, now.playing, scrub == nil else { return }
        position = min(basePosition + Date().timeIntervalSince(baseDate), max(now.duration, 0))
    }

    func playPause() {
        guard let current = now else { return }
        tick()
        now?.playing = !current.playing
        expectedPlaying = !current.playing
        expectedUntil = Date().addingTimeInterval(1.5)
        basePosition = position
        baseDate = Date()
        command("playpause")
    }

    func next() { command("next track") }
    func back() { command("back track") }

    private func command(_ script: String) {
        commands += 1
        music.send(script) { [weak self] in self?.refresh() }
    }

    func seek(to fraction: Double) {
        guard let duration = now?.duration, duration > 0 else { return }
        let t = fraction * duration
        position = t
        basePosition = t
        baseDate = Date()
        command("set player position to \(t)")
    }
}

// MARK: - View

struct DockNPEncoreView: View {
    static let size = NSSize(width: 280, height: 92)

    @ObservedObject var model: DockNPPlayerModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.now?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.now?.artist ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    control("backward.fill", size: 12, action: model.back)
                    control(model.now?.playing == true ? "pause.fill" : "play.fill", size: 17, action: model.playPause)
                    control("forward.fill", size: 12, action: model.next)
                }
            }
            DockNPTimelineBar(model: model)
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DockNPPanelBackground())
        // Buttons and the timeline keep their own gestures; anywhere else drags the card.
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { model.onDrag?($0.translation, false) }
            .onEnded { model.onDrag?($0.translation, true) })
        .environment(\.colorScheme, .dark)
    }

    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            if model.pinned && model.hovering {
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(DockNPPressStyle())
                .padding(3)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.pinned && model.hovering)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(DockNPPressStyle())
    }
}

private struct DockNPPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct DockNPTimelineBar: View {
    @ObservedObject var model: DockNPPlayerModel

    var body: some View {
        let duration = model.now?.duration ?? 0
        let fraction = model.scrub ?? (duration > 0 ? min(max(model.position / duration, 0), 1) : 0)
        let dragging = model.scrub != nil
        HStack(spacing: 8) {
            time(duration > 0 ? fraction * duration : nil, alignment: .leading)
            GeometryReader { geo in
                let height: CGFloat = dragging ? 6 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(dragging ? 0.95 : 0.7))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        model.scrub = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        model.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
                        model.scrub = nil
                    })
                .animation(.snappy(duration: 0.15), value: dragging)
            }
            .frame(height: 14)
            time(duration > 0 ? (fraction - 1) * duration : nil, alignment: .trailing)
        }
    }

    private func time(_ seconds: Double?, alignment: Alignment) -> some View {
        Text(seconds.map(Self.format) ?? "--:--")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(minWidth: 30, alignment: alignment)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(abs(seconds).rounded(.down))
        let text = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        return seconds < 0 && total > 0 ? "-" + text : text
    }
}

/// The card's backdrop: the same glass as every other Pocket surface.
struct DockNPPanelBackground: View {
    var body: some View {
        HUDBackdrop(cornerRadius: 16, contrast: .high)
    }
}

// MARK: - Panel

final class DockNPFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DockNPEncorePanel: NSPanel {
    init(model: DockNPPlayerModel) {
        super.init(contentRect: NSRect(origin: .zero, size: DockNPEncoreView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = DockNPFirstClickHostingView(rootView: DockNPEncoreView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: DockNPEncoreView.size)
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
}
