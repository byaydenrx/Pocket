// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Fetch (MIT, © 2026 Byaydenrx).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which row the pointer is over (SwiftUI's @State isn't available without Xcode's macros).
final class DLHoverState: ObservableObject {
    @Published var id: String?
}

struct DLRootView: View {
    @ObservedObject var store: DLStore
    @ObservedObject var settings: DLSettings
    @ObservedObject var hover: DLHoverState

    var body: some View {
        VStack(spacing: 0) {
            DLInputBar(store: store)
            DLOptionsRow(store: store, settings: settings)
            Divider().opacity(0.5)
            if store.items.isEmpty {
                DLEmptyState(ready: store.ready)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            DLRow(item: item, store: store, hover: hover)
                            Divider().opacity(0.25).padding(.leading, 18)
                        }
                    }
                }
            }
            DLFooter(store: store)
        }
        .ignoresSafeArea(.container, edges: .top) // the link field sits in the title bar
        .frame(minWidth: 480, minHeight: 300)
        .background(HUDBackdrop(cornerRadius: 0, contrast: .high).ignoresSafeArea())
        .onDrop(of: [.fileURL, .url], isTargeted: nil) { providers in
            Self.load(providers) { store.drop($0) }
            return true
        }
    }

    static func load(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

// MARK: Top

struct DLInputBar: View {
    @ObservedObject var store: DLStore
    /// Room for a window's traffic lights; 12 inside the menu panel.
    var leadingInset: CGFloat = 88
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).font(.system(size: 12, weight: .medium))
                TextField("Paste a link, magnet, or aria2c command", text: $store.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { store.submit() }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(focused ? 0.22 : 0.08)))

            Button { store.submit() } label: {
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18)
            }
            .pocketProminentButton()
            .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.ready)
            .help("Download (Return)")
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct DLOptionsRow: View {
    @ObservedObject var store: DLStore
    @ObservedObject var settings: DLSettings

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach([1, 2, 4, 8, 12, 16], id: \.self) { n in
                    Button { settings.connections = n } label: {
                        if n == settings.connections { Label("\(n)", systemImage: "checkmark") } else { Text("\(n)") }
                    }
                }
                Divider()
                Menu("Other") {
                    ForEach(1...16, id: \.self) { n in Button("\(n)") { settings.connections = n } }
                }
            } label: {
                Label("\(settings.connections) connection\(settings.connections == 1 ? "" : "s")", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .help("Connections per download (aria2c -x / -s)")

            Menu {
                Button("Choose Folder…") { chooseFolder() }
                Divider()
                Button("Downloads") { settings.folder = DLSettings.downloads }
                Button("Desktop") { settings.folder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.open(settings.folder) }
            } label: {
                Label(settings.folder.lastPathComponent, systemImage: "folder")
            }
            .help(settings.folder.path)

            if settings.cookies != nil {
                Label("Cookies", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .help("Using \(settings.cookies!.path)")
            }

            Spacer()

            Button { store.showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("More options")
                .popover(isPresented: $store.showSettings, arrowEdge: .bottom) {
                    DLSettingsView(settings: settings)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 9)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.folder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { settings.folder = url }
    }
}

// MARK: DLSettings

struct DLSettingsView: View {
    @ObservedObject var settings: DLSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    Text("At once").foregroundStyle(.secondary)
                    Stepper("\(settings.concurrent) download\(settings.concurrent == 1 ? "" : "s")", value: $settings.concurrent, in: 1...20)
                }
                GridRow {
                    Text("Speed limit").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("0", text: $settings.speedLimit).frame(width: 70)
                        Text("0 = none · e.g. 500K, 2M").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Text("Cookies").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let cookies = settings.cookies {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(cookies.lastPathComponent).lineLimit(1).truncationMode(.middle).help(cookies.path)
                            Button("Change…") { chooseCookies() }
                            Button { settings.cookies = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop using cookies")
                        } else {
                            Button("Choose cookies.txt…") { chooseCookies() }
                            Text("or drop it on the window").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Torrents").foregroundStyle(.secondary)
                    Toggle("Keep seeding after download", isOn: $settings.seed)
                }
                GridRow {
                    Text("Notify").foregroundStyle(.secondary)
                    Toggle("When a download finishes", isOn: $settings.notify)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("aria2c options for every download").foregroundStyle(.secondary)
                TextField("e.g. --max-tries=10 --user-agent=Mozilla/5.0", text: $settings.extra, axis: .vertical)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("You can also add flags after a link: link -x 8 -o name.zip").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Link("All options", destination: URL(string: "https://aria2.github.io/manual/en/html/aria2c.html#options")!)
                        .font(.system(size: 11))
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 420)
    }

    private func chooseCookies() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.message = "Choose a cookies.txt file (Netscape format, as exported by a browser extension)"
        panel.prompt = "Use Cookies"
        if let cookies = settings.cookies { panel.directoryURL = cookies.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { settings.cookies = url }
    }
}

// MARK: List

struct DLRow: View {
    let item: DLItem
    @ObservedObject var store: DLStore
    @ObservedObject var hover: DLHoverState

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(item.status == .complete ? 1 : 0.75)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsBar { DLProgressBar(value: item.progress, color: barColor) }
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(item.status == .error ? Color.red.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.error ?? "")
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                switch item.status {
                case .active, .waiting, .metadata:
                    DLRowButton(symbol: "pause.fill", help: "Pause") { store.pause(item) }
                case .paused:
                    DLRowButton(symbol: "play.fill", help: "Resume") { store.resume(item) }
                case .error:
                    DLRowButton(symbol: "arrow.clockwise", help: "Try Again") { store.retry(item) }
                case .complete, .seeding:
                    DLRowButton(symbol: "magnifyingglass", help: "Show in Finder") { store.reveal(item) }
                }
                DLRowButton(symbol: "xmark", help: item.finished || item.status == .seeding ? "Remove from List" : "Cancel Download") {
                    store.remove(item)
                }
            }
            .opacity(hover.id == item.id ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(hover.id == item.id ? Color.white.opacity(0.035) : .clear)
        .onHover { inside in
            if inside { hover.id = item.id } else if hover.id == item.id { hover.id = nil }
        }
        .onTapGesture(count: 2) { if item.status == .complete { store.open(item) } else { store.reveal(item) } }
        .contextMenu {
            if item.status == .complete { Button("Open") { store.open(item) } }
            Button("Show in Finder") { store.reveal(item) }
            if !item.uris.isEmpty { Button("Copy Link") { store.copyLink(item) } }
            Divider()
            if item.status == .paused { Button("Resume") { store.resume(item) } }
            if [.active, .waiting, .metadata].contains(item.status) { Button("Pause") { store.pause(item) } }
            if item.status == .error { Button("Try Again") { store.retry(item) } }
            Button(item.finished || item.status == .seeding ? "Remove from List" : "Cancel Download") { store.remove(item) }
            if item.status == .complete || item.status == .seeding {
                Button("Move File to Trash") { store.remove(item, deleteFile: true) }
            }
        }
    }

    private var showsBar: Bool { item.status != .complete && item.status != .error }

    private var barColor: Color {
        switch item.status {
        case .paused, .waiting: return .white.opacity(0.3)
        case .seeding: return .green.opacity(0.8)
        default: return .white.opacity(0.9)
        }
    }

    private var icon: NSImage {
        if item.status == .complete, let path = item.path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private var detail: String {
        let size = DLFormat.bytes(item.total)
        switch item.status {
        case .complete: return size
        case .error: return item.error ?? "Failed"
        case .metadata: return "Getting torrent info…"
        case .waiting: return "Waiting · \(progressText)"
        case .paused: return "Paused · \(progressText)"
        case .seeding: return "Seeding · ↑ \(DLFormat.bytes(item.upload))/s"
        case .active:
            var parts = [progressText, "\(DLFormat.bytes(item.speed))/s"]
            if item.speed > 0, item.total > item.done { parts.append(DLFormat.eta(Double(item.total - item.done) / Double(item.speed))) }
            if item.connections > 0 { parts.append("\(item.connections) conn") }
            return parts.joined(separator: " · ")
        }
    }

    private var progressText: String {
        item.total > 0 ? "\(Int(item.progress * 100))% of \(DLFormat.bytes(item.total))" : (item.done > 0 ? DLFormat.bytes(item.done) : "Starting…")
    }
}

struct DLRowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct DLProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(value > 0 ? 3 : 0, geo.size.width * min(1, value)))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.45), value: value)
    }
}

struct DLEmptyState: View {
    let ready: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(ready ? "Paste a link to download" : "Starting aria2c…").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text("Links, magnets, .torrent and .metalink files — or drop them here")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DLFooter: View {
    @ObservedObject var store: DLStore

    var body: some View {
        let active = store.items.filter { $0.status == .active || $0.status == .metadata }
        let paused = store.items.filter { $0.status == .paused }
        let speed = store.items.reduce(Int64(0)) { $0 + $1.speed }
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                if let problem = store.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(problem).lineLimit(2).foregroundStyle(.primary.opacity(0.85)).help(problem)
                    if problem == DLAria2.Failure.notInstalled.errorDescription {
                        Link("How to Install", destination: DLAria2.installHelp)
                    }
                    Button { store.problem = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                } else if !active.isEmpty {
                    Text("\(active.count) downloading · ↓ \(DLFormat.bytes(speed))/s")
                } else {
                    Text(store.items.isEmpty ? " " : "\(store.items.filter { $0.status == .complete }.count) downloaded")
                }
                Spacer()
                if !active.isEmpty { Button("Pause All") { store.pauseAll() }.buttonStyle(.borderless) }
                if !paused.isEmpty { Button("Resume All") { store.resumeAll() }.buttonStyle(.borderless) }
                if store.items.contains(where: \.finished) { Button("Clear") { store.clearFinished() }.buttonStyle(.borderless).help("Clear finished downloads from the list") }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 30)
        }
    }
}

enum DLFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func eta(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s left" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s left" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m left" }
        return "\(s / 86400)d left"
    }
}


/// Downloads as a menu panel tab: the link field, options and the list, no window.
struct DownloadsSection: View {
    var collapsible = true
    @ObservedObject private var store = DownloadsService.shared.store
    @ObservedObject private var settings = DownloadsService.shared.settings
    @StateObject private var hover = DLHoverState()

    var body: some View {
        PanelSection(.downloads, title: PanelSectionID.downloads.title(L10n.shared.s), collapsible: collapsible) {
            VStack(spacing: 0) {
                DLInputBar(store: store, leadingInset: 0)
                    .padding(.trailing, -12)
                DLOptionsRow(store: store, settings: settings)
                    .padding(.horizontal, -16)
                if store.items.isEmpty {
                    Text(store.ready ? "Paste a link above, or drop a link or .torrent here." : "Starting aria2…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.items) { item in
                                DLRow(item: item, store: store, hover: hover)
                                Divider().opacity(0.25)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                DLFooter(store: store)
                    .padding(.horizontal, -16)
            }
            .onDrop(of: [.fileURL, .url], isTargeted: nil) { providers in
                DLRootView.load(providers) { store.drop($0) }
                return true
            }
            .onAppear { DownloadsService.shared.panelAppeared() }
            .onDisappear { DownloadsService.shared.panelDisappeared() }
        }
    }
}
