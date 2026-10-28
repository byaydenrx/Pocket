// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// Mole-style upkeep, beside the cleaner: one-click maintenance tasks. Tasks
/// that need administrator rights ask with the system password dialog.
@MainActor
final class CleanOptimizeService: ObservableObject {
    static let shared = CleanOptimizeService()

    struct Task: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let admin: Bool
        let command: String
    }

    enum State: Equatable { case running, done, failed }

    @Published private(set) var states: [String: State] = [:]

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    var tasks: [Task] {
        var list: [Task] = [
            Task(id: "dns", title: "Flush DNS Cache", detail: "Fixes sites that won't load after a network change.",
                 symbol: "network", admin: true, command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
            Task(id: "quicklook", title: "Reset Quick Look", detail: "Fixes missing or stale previews and thumbnails.",
                 symbol: "eye", admin: false, command: "/usr/bin/qlmanage -r >/dev/null; /usr/bin/qlmanage -r cache >/dev/null"),
            Task(id: "launchservices", title: "Rebuild “Open With” Menu", detail: "Removes duplicate and stale apps from Open With.",
                 symbol: "square.stack.3d.up", admin: false,
                 // macOS 27's lsregister has no -kill: compact the database,
                 // then re-register the app folders from scratch.
                 command: "\(Self.lsregister) -gc; \(Self.lsregister) -f -r /Applications /System/Applications \"$HOME/Applications\" 2>/dev/null; true"),
            Task(id: "fonts", title: "Clear Font Caches", detail: "Fixes garbled or missing fonts.",
                 symbol: "textformat", admin: false,
                 command: "/usr/bin/atsutil databases -removeUser >/dev/null; /usr/bin/atsutil server -shutdown >/dev/null; /usr/bin/atsutil server -ping >/dev/null"),
            Task(id: "memory", title: "Free Up Memory", detail: "Drops inactive memory the system can rebuild.",
                 symbol: "memorychip", admin: true, command: "/usr/sbin/purge"),
            Task(id: "spotlight", title: "Rebuild Spotlight Index", detail: "Fixes search that misses files. Takes a while in the background.",
                 symbol: "magnifyingglass", admin: true, command: "/usr/bin/mdutil -E / >/dev/null"),
            Task(id: "dock", title: "Restart Dock and Menu Bar", detail: "Fixes a stuck Dock, menu bar or Mission Control.",
                 symbol: "dock.rectangle", admin: false, command: "/usr/bin/killall Dock SystemUIServer"),
        ]
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:)) {
            // brew refuses to run without HOME and needs its own bin on PATH.
            let env = "HOME=\"\(NSHomeDirectory())\" PATH=\"\((brew as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin\""
            list.append(Task(id: "brew", title: "Clean Up Homebrew", detail: "Removes old versions and Homebrew's download cache.",
                             symbol: "shippingbox", admin: false, command: "\(env) \(brew) cleanup --prune=all -s >/dev/null 2>&1"))
        }
        return list
    }

    func syncWithPreferences() {}

    @Published private(set) var runningAll = false

    /// Runs every task: the ones that need administrator rights together,
    /// behind one password prompt, then the rest one after another.
    func runAll() {
        guard !runningAll else { return }
        runningAll = true
        let all = tasks
        for task in all { states[task.id] = .running }
        let admin = all.filter(\.admin)
        let user = all.filter { !$0.admin }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [String: Bool] = [:]
            if !admin.isEmpty {
                let ok = AdminShell.runSync(admin.map(\.command).joined(separator: "; "),
                                            prompt: "Pocket wants to run its maintenance tasks.")
                for task in admin { results[task.id] = ok }
            }
            for task in user {
                results[task.id] = Shell.run("/bin/sh", ["-c", task.command], timeout: 300).status == 0
            }
            DispatchQueue.main.async {
                for (id, ok) in results { self.states[id] = ok ? .done : .failed }
                self.runningAll = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    for id in results.keys where self.states[id] != .running { self.states[id] = nil }
                }
            }
        }
    }

    func run(_ task: Task) {
        guard states[task.id] != .running else { return }
        states[task.id] = .running
        let command = task.command
        let admin = task.admin
        let title = task.title
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            if admin {
                ok = AdminShell.runSync(command, prompt: "Pocket wants to \(title.lowercased()).")
            } else {
                ok = Shell.run("/bin/sh", ["-c", command], timeout: 300).status == 0
            }
            DispatchQueue.main.async {
                self.states[task.id] = ok ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self.states[task.id] != .running { self.states[task.id] = nil }
                }
            }
        }
    }
}

struct OptimizeList: View {
    @ObservedObject private var service = CleanOptimizeService.shared

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Tasks with a lock ask for your password once.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(service.runningAll ? "Running…" : "Run All") { service.runAll() }
                    .disabled(service.runningAll)
                    .controlSize(.small)
            }
            .padding(.bottom, 4)
            ForEach(service.tasks) { task in
                HStack(spacing: 10) {
                    Image(systemName: task.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(task.title)
                            if task.admin {
                                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                                    .help("Asks for your password")
                            }
                        }
                        Text(task.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch service.states[task.id] {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case nil: Button("Run") { service.run(task) }.controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .font(.callout)
    }
}

struct CleanOptimizeView: View {
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Clean").tag(0)
                Text("Optimize").tag(1)
                if AppFeature.storageAnalyzer.isAvailable { Text("Storage").tag(2) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case 0: CleanerView(compact: true)
            case 1: OptimizeList().panelCard()
            default:
                StorageAnalyzerSettings(compact: true)
                    .frame(height: 400)
            }
        }
    }
}

struct CleanOptimizeSection: View {
    var collapsible = true
    var body: some View {
        PanelSection(.cleanOptimize, title: PanelSectionID.cleanOptimize.title(L10n.shared.s), collapsible: collapsible) {
            CleanOptimizeView()
        }
    }
}

struct CleanOptimizeSettings: View {
    var body: some View {
        Form {
            Section { Text(AppFeature.cleanOptimize.pocketDescription).font(.callout) }
            Section("Optimize") { OptimizeList() }
            Section("Clean") {
                Text("Caches, logs, developer junk, app leftovers, the Trash and old device backups, with a preview before anything is removed.")
                    .font(.caption).foregroundStyle(.secondary)
                CleanerView()
            }
        }
        .formStyle(.grouped)
    }
}
