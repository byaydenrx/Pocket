// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import Darwin
import SwiftUI

/// One app (with its helper processes) or a lone background process.
struct TaskEntry: Identifiable, Equatable {
    let id: String
    var name: String
    var pids: [pid_t]
    var cpu: Double        // percent of one core, summed over the group
    var memory: UInt64     // resident bytes, summed
    var bundleURL: URL?
    var isApp: Bool

    static func == (a: TaskEntry, b: TaskEntry) -> Bool {
        a.id == b.id && a.pids == b.pids && Int(a.cpu * 10) == Int(b.cpu * 10) && a.memory / 1_000_000 == b.memory / 1_000_000
    }
}

/// A light task manager: what is using the Mac right now, limited to things
/// that are safe to end. Samples only while its view is on screen.
@MainActor
final class TaskManagerService: ObservableObject {
    static let shared = TaskManagerService()

    enum Sort: String, CaseIterable, Identifiable { case cpu, memory; var id: String { rawValue } }

    @Published private(set) var entries: [TaskEntry] = []
    @Published var sort: Sort = .cpu { didSet { publish() } }

    private var viewers = 0
    private var timer: Timer?
    private var lastCPU: [pid_t: (time: UInt64, at: TimeInterval)] = [:]
    private var raw: [TaskEntry] = []
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func syncWithPreferences() {
        if !AppFeature.taskManager.isAvailable { stopSampling(); viewers = 0 }
    }

    func beginViewing() {
        viewers += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stopSampling() }
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
        lastCPU = [:]
        entries = []
    }

    // MARK: Ending things

    func quit(_ entry: TaskEntry) {
        if let app = NSRunningApplication(processIdentifier: entry.pids[0]), entry.isApp {
            app.terminate()
        } else {
            for pid in entry.pids { Darwin.kill(pid, SIGTERM) }
        }
        scheduleResample()
    }

    func forceQuit(_ entry: TaskEntry) {
        if let app = NSRunningApplication(processIdentifier: entry.pids[0]), entry.isApp {
            app.forceTerminate()
        }
        for pid in entry.pids { Darwin.kill(pid, SIGKILL) }
        scheduleResample()
    }

    private func scheduleResample() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.sample() }
    }

    // MARK: Sampling

    private func sample() {
        let previous = lastCPU
        Task.detached(priority: .utility) {
            let (list, cpuState) = Self.collect(previous: previous)
            await MainActor.run {
                self.lastCPU = cpuState
                self.raw = list
                self.publish()
            }
        }
    }

    private func publish() {
        let sorted = raw.sorted { sort == .cpu ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : $0.memory > $1.memory }
        let top = Array(sorted.prefix(30))
        if top != entries { entries = top }
    }

    /// Processes Pocket never lists: anything macOS needs to keep running.
    nonisolated private static let protectedNames: Set<String> = [
        "WindowServer", "loginwindow", "launchd", "kernel_task", "Dock", "Finder", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "cfprefsd", "distnoted", "Spotlight",
        "WallpaperAgent", "TextInputMenuAgent", "universalaccessd", "talagent", "sharingd", "UserEventAgent",
        "corespotlightd", "mds", "mds_stores", "mdworker", "mdworker_shared", "secd", "trustd", "nsurlsessiond",
    ]

    nonisolated private static let protectedPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/",
                                                        "/private/var/", "/Library/Developer/CommandLineTools/"]

    nonisolated private static func collect(previous: [pid_t: (time: UInt64, at: TimeInterval)])
        -> ([TaskEntry], [pid_t: (time: UInt64, at: TimeInterval)]) {
        let me = getuid()
        let ownPID = getpid()
        let now = ProcessInfo.processInfo.systemUptime
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return ([], [:]) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var cpuState: [pid_t: (time: UInt64, at: TimeInterval)] = [:]
        var groups: [String: TaskEntry] = [:]
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN) * 4)
        defer { pathBuffer.deallocate() }

        for pid in pids.prefix(Int(count)) where pid > 0 && pid != ownPID {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == me else { continue }
            guard proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN) * 4) > 0 else { continue }
            let path = String(cString: pathBuffer)
            if protectedPrefixes.contains(where: path.hasPrefix) { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if protectedNames.contains(name) || path.contains("/Pocket.app/") { continue }

            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            let cpuTime = UInt64(Double(task.pti_total_user + task.pti_total_system) * timebase)
            cpuState[pid] = (cpuTime, now)
            var cpu = 0.0
            if let last = previous[pid], now > last.at, cpuTime >= last.time {
                cpu = Double(cpuTime - last.time) / ((now - last.at) * 1_000_000_000) * 100
            }

            // Group helpers under the outermost .app they live in.
            var bundle: URL?
            if let range = path.range(of: ".app/") {
                bundle = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
            }
            let key = bundle?.path ?? "pid:\(pid)"
            if var entry = groups[key] {
                entry.pids.append(pid)
                entry.cpu += cpu
                entry.memory += task.pti_resident_size
                groups[key] = entry
            } else {
                let appName = bundle.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? name
                groups[key] = TaskEntry(id: key, name: appName, pids: [pid], cpu: cpu, memory: task.pti_resident_size,
                                        bundleURL: bundle, isApp: bundle != nil)
            }
        }
        // The main app process first, so Quit goes to the app, not a helper.
        let list = groups.values.map { entry -> TaskEntry in
            var e = entry
            if let bundle = e.bundleURL,
               let main = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: bundle)?.bundleIdentifier ?? "-").first,
               let index = e.pids.firstIndex(of: main.processIdentifier) {
                e.pids.swapAt(0, index)
            } else if e.isApp {
                e.isApp = false
            }
            return e
        }
        return (list, cpuState)
    }
}

// MARK: - Views

struct TaskManagerList: View {
    @ObservedObject private var service = TaskManagerService.shared
    @State private var confirmForce: TaskEntry?
    var maxRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $service.sort) {
                Text("CPU").tag(TaskManagerService.Sort.cpu)
                Text("Memory").tag(TaskManagerService.Sort.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if service.entries.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 1) {
                    ForEach(service.entries.prefix(maxRows)) { entry in
                        TaskRow(entry: entry, onForce: { confirmForce = entry })
                    }
                }
            }
            Text("Only your own apps and helpers are listed; macOS's own processes never are.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { service.beginViewing() }
        .onDisappear { service.endViewing() }
        .alert("Force quit “\(confirmForce?.name ?? "")”?", isPresented: Binding(
            get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } })) {
            Button("Force Quit", role: .destructive) {
                if let entry = confirmForce { service.forceQuit(entry) }
                confirmForce = nil
            }
            Button("Cancel", role: .cancel) { confirmForce = nil }
        } message: {
            Text("Unsaved changes in it will be lost.")
        }
    }
}

private struct TaskRow: View {
    let entry: TaskEntry
    let onForce: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let bundle = entry.bundleURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.path)).resizable()
                } else {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).lineLimit(1)
                if entry.pids.count > 1 {
                    Text("\(entry.pids.count) processes").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.0f%%", entry.cpu))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(entry.cpu > 50 ? Color.orange : Color.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.memory), countStyle: .memory))
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.secondary)
            Button { TaskManagerService.shared.quit(entry) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20).pocketGlassCircle()
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Quit \(entry.name)")
        }
        .font(.system(size: 11.5).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Quit") { TaskManagerService.shared.quit(entry) }
            Button("Force Quit…", action: onForce)
            if let bundle = entry.bundleURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
            }
        }
    }
}

struct TaskManagerSection: View {
    var collapsible = true
    var body: some View {
        PanelSection(.taskManager, title: PanelSectionID.taskManager.title(L10n.shared.s), collapsible: collapsible) {
            TaskManagerList()
        }
    }
}

struct TaskManagerSettings: View {
    var body: some View {
        Form {
            Section {
                Text(AppFeature.taskManager.pocketDescription).font(.callout)
            }
            Section("Now") {
                TaskManagerList(maxRows: 30)
            }
        }
        .formStyle(.grouped)
    }
}
