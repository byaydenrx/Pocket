// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Fetch (MIT, © 2026 Byaydenrx).

import AppKit
import os
import Combine
import UserNotifications

enum DLPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocket/Downloads")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// aria2's own session file: unfinished downloads, reloaded on the next launch.
    static let session = support.appendingPathComponent("session.aria2")
    /// Finished downloads, so the list survives quitting.
    static let history = support.appendingPathComponent("history.json")
}

private let dlLogger = Logger(subsystem: "com.byaydenrx.pocket", category: "downloads")

func dlLog(_ message: String) {
    dlLogger.debug("\(message, privacy: .public)")
}

/// Everything you can set, kept in UserDefaults.
final class DLSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "downloads.folder") } }
    @Published var connections: Int { didSet { defaults.set(connections, forKey: "downloads.connections") } }
    @Published var concurrent: Int { didSet { defaults.set(concurrent, forKey: "downloads.concurrent") } }
    /// aria2 speed syntax: "0" is unlimited, "500K", "2M".
    @Published var speedLimit: String { didSet { defaults.set(speedLimit, forKey: "downloads.speedLimit") } }
    @Published var seed: Bool { didSet { defaults.set(seed, forKey: "downloads.seed") } }
    @Published var cookies: URL? { didSet { defaults.set(cookies?.path, forKey: "downloads.cookies") } }
    /// Any aria2c flags, used for every download (and for aria2c itself, so it checks them).
    @Published var extra: String { didSet { defaults.set(extra, forKey: "downloads.extra") } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "downloads.notify") } }

    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    init() {
        let saved = defaults.string(forKey: "downloads.folder").map(URL.init(fileURLWithPath:))
        folder = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Self.downloads
        connections = defaults.object(forKey: "downloads.connections") as? Int ?? 16
        concurrent = defaults.object(forKey: "downloads.concurrent") as? Int ?? 3
        speedLimit = defaults.string(forKey: "downloads.speedLimit") ?? "0"
        seed = defaults.bool(forKey: "downloads.seed")
        cookies = defaults.string(forKey: "downloads.cookies").map(URL.init(fileURLWithPath:))
        extra = defaults.string(forKey: "downloads.extra") ?? ""
        notify = defaults.object(forKey: "downloads.notify") as? Bool ?? true
    }

    /// The flags aria2c starts with. Per-download choices (folder, connections) are also sent with each download.
    func daemonFlags(includeExtra: Bool = true) -> [String] {
        var flags = [
            "--dir=\(folder.path)", "--continue=true", "--file-allocation=none", "--auto-file-renaming=true",
            "--max-connection-per-server=\(connections)", "--split=\(connections)", "--min-split-size=1M",
            "--max-concurrent-downloads=\(concurrent)", "--max-overall-download-limit=\(speedLimit.isEmpty ? "0" : speedLimit)",
            "--input-file=\(DLPaths.session.path)", "--save-session=\(DLPaths.session.path)", "--save-session-interval=5",
        ]
        if !seed { flags.append("--seed-time=0") }
        if let cookies { flags.append("--load-cookies=\(cookies.path)") }
        if includeExtra { flags += DLCommand.tokenize(extra).filter { $0 != "aria2c" } }
        return flags
    }

    /// Options sent with every new download.
    func downloadOptions() -> [String: Any] {
        var options: [String: Any] = ["dir": folder.path, "max-connection-per-server": "\(connections)", "split": "\(connections)"]
        if !seed { options["seed-time"] = "0" }
        for job in DLCommand.parse("aria2c \(extra) https://x").jobs { options.merge(job.options) { _, new in new } }
        return options
    }
}

struct DLItem: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case active, waiting, paused, error, complete, metadata, seeding }

    var id: String
    var gid: String?
    var name: String
    var status: Status
    var total: Int64 = 0
    var done: Int64 = 0
    var speed: Int64 = 0
    var upload: Int64 = 0
    var connections = 0
    var path: String?
    var dir: String
    var uris: [String] = []
    var error: String?
    var added: Date

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var finished: Bool { status == .complete || status == .error }
}

/// The download list: polls aria2 twice a second and turns your clicks into RPC calls.
@MainActor
final class DLStore: ObservableObject {
    @Published var input = ""
    @Published private(set) var items: [DLItem] = []
    @Published var problem: String?
    @Published private(set) var ready = false
    @Published var showSettings = false
    /// Downloads moving right now; the service keeps aria2c alive while it is above zero.
    @Published private(set) var activeCount = 0

    let settings: DLSettings
    let aria = DLAria2()
    private var history: [DLItem] = []
    private var added: [String: Date] = [:]
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var launching = false

    init(settings: DLSettings) {
        self.settings = settings
        if let data = try? Data(contentsOf: DLPaths.history), let saved = try? JSONDecoder().decode([DLItem].self, from: data) {
            history = saved
        }
        items = history

        settings.$concurrent.dropFirst().removeDuplicates().sink { [weak self] value in
            self?.changeGlobal(["max-concurrent-downloads": "\(value)"])
        }.store(in: &bag)
        settings.$speedLimit.dropFirst().removeDuplicates().debounce(for: 0.6, scheduler: RunLoop.main).sink { [weak self] value in
            self?.changeGlobal(["max-overall-download-limit": value.isEmpty ? "0" : value])
        }.store(in: &bag)
        // Flags only aria2c itself can take (and cookies) need a restart; unfinished downloads carry over.
        settings.$extra.dropFirst().removeDuplicates().debounce(for: 1.2, scheduler: RunLoop.main).sink { [weak self] _ in
            self?.restart()
        }.store(in: &bag)
        settings.$cookies.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.restart()
        }.store(in: &bag)
    }

    func start() { Task { await launch() } }

    /// Starts aria2c (again). Unfinished downloads come back from the session file.
    func launch() async {
        guard !launching else { return }
        launching = true
        defer { launching = false }
        if !FileManager.default.fileExists(atPath: DLPaths.session.path) {
            FileManager.default.createFile(atPath: DLPaths.session.path, contents: Data())
        }
        if aria.isRunning {
            _ = try? await aria.call("aria2.saveSession")
            aria.stop()
            ready = false
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        cookiesDate = cookiesModified()
        do {
            try await aria.start(options: settings.daemonFlags())
            problem = nil
        } catch DLAria2.Failure.exited(let message) where !settings.extra.isEmpty {
            // Your extra flags were rejected; start without them so downloads still work.
            dlLog("aria2c rejected extra flags: \(message)")
            do {
                try await aria.start(options: settings.daemonFlags(includeExtra: false))
                problem = "aria2c didn't accept your extra options: \(message)"
            } catch {
                problem = error.localizedDescription
            }
        } catch {
            problem = error.localizedDescription
            dlLog("aria2c failed to start: \(error.localizedDescription)")
        }
        ready = aria.isRunning
        if ready { dlLog("aria2c running") }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
        }
    }

    func restart() { start() }

    /// aria2c reads cookies.txt only when it starts, so a re-exported file means a restart before the next download.
    private var cookiesDate: Date?

    private func cookiesModified() -> Date? {
        guard let path = settings.cookies?.path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func quit() {
        timer?.invalidate()
        timer = nil
        aria.shutdown()
        ready = false
        activeCount = 0
    }

    /// Whether the session file holds unfinished downloads to resume.
    static var hasUnfinishedSession: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: DLPaths.session.path))?[.size] as? Int ?? 0) > 0
    }

    // MARK: Adding

    /// Downloads whatever is in the field.
    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = DLCommand.parse(text)
        if parsed.jobs.isEmpty {
            problem = parsed.problems.first ?? "Paste a link, magnet, or .torrent file."
            return
        }
        input = ""
        problem = parsed.problems.isEmpty ? nil : parsed.problems.joined(separator: " · ")
        if !parsed.global.isEmpty { changeGlobal(parsed.global) }
        for job in parsed.jobs { add(job) }
    }

    func add(_ job: DLJob) {
        var options = settings.downloadOptions()
        options.merge(job.options) { _, new in new }
        // aria2 ignores load-cookies per download; send that file's cookies for this link as a header instead.
        if let file = options.removeValue(forKey: "load-cookies") as? String,
           case .uris(let uris) = job.source, let header = DLCookies.header(file: file, for: uris.first) {
            options["header"] = (options["header"] as? [String] ?? []) + [header]
        }
        Task {
            if cookiesModified() != cookiesDate { dlLog("cookies file changed; restarting aria2c"); await launch() }
            do {
                let gid: Any
                switch job.source {
                case .uris(let uris):
                    gid = try await aria.call("aria2.addUri", [uris, options])
                case .torrent(let url):
                    let data = try Data(contentsOf: url)
                    gid = try await aria.call("aria2.addTorrent", [data.base64EncodedString(), [], options])
                case .metalink(let url):
                    let data = try Data(contentsOf: url)
                    gid = try await aria.call("aria2.addMetalink", [data.base64EncodedString(), options])
                }
                for id in (gid as? [String]) ?? [gid as? String].compactMap({ $0 }) { added[id] = Date() }
                await poll()
            } catch {
                problem = error.localizedDescription
                dlLog("add failed: \(error.localizedDescription)")
            }
        }
    }

    /// Files and links dropped on the window. A cookies.txt becomes the cookies file.
    func drop(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            if url.isFileURL {
                if Self.isCookiesFile(url) { settings.cookies = url; continue }
                if DLCommand.isLocalFile(url.path) { add(DLCommand.job(forFile: url.path, options: [:])) }
            } else {
                lines.append(url.absoluteString)
            }
        }
        if !lines.isEmpty { add(text: lines.joined(separator: "\n")) }
    }

    func add(text: String) {
        input = text
        submit()
    }

    static func isCookiesFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "txt",
              let head = try? String(contentsOf: url, encoding: .utf8).prefix(4000) else { return false }
        if head.contains("Netscape HTTP Cookie File") { return true }
        return head.split(separator: "\n").contains { !$0.hasPrefix("#") && $0.split(separator: "\t", omittingEmptySubsequences: false).count == 7 }
    }

    // MARK: Actions

    func pause(_ item: DLItem) { send("aria2.forcePause", item) }
    func resume(_ item: DLItem) { send("aria2.unpause", item) }

    func pauseAll() { Task { _ = try? await aria.call("aria2.forcePauseAll"); await poll() } }
    func resumeAll() { Task { _ = try? await aria.call("aria2.unpauseAll"); await poll() } }

    func remove(_ item: DLItem, deleteFile: Bool = false) {
        // Cancelling an unfinished download throws away its partial file and aria2's .aria2 control file.
        let cancelling = !item.finished && item.status != .seeding
        if let gid = item.gid {
            Task {
                if !item.finished { _ = try? await aria.call("aria2.forceRemove", [gid]) }
                if let path = item.path, cancelling || deleteFile {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    trash(path + ".aria2", inside: item.dir)
                    trash(path, inside: item.dir)
                }
                _ = try? await aria.call("aria2.removeDownloadResult", [gid])
                await poll()
            }
        } else if deleteFile, let path = item.path {
            trash(path, inside: item.dir)
        }
        history.removeAll { $0.id == item.id }
        saveHistory()
        items.removeAll { $0.id == item.id }
    }

    func retry(_ item: DLItem) {
        guard !item.uris.isEmpty else { return }
        remove(item)
        add(DLJob(source: .uris(item.uris), options: ["dir": item.dir]))
    }

    func clearFinished() {
        for item in items where item.finished { remove(item) }
        Task { _ = try? await aria.call("aria2.purgeDownloadResult") }
    }

    func reveal(_ item: DLItem) {
        if let path = item.path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.dir))
        }
    }

    func open(_ item: DLItem) {
        guard let path = item.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func copyLink(_ item: DLItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.uris.joined(separator: "\n"), forType: .string)
    }

    /// Only ever trashes something inside a download folder, whatever name a torrent or server reported.
    private func trash(_ path: String, inside dir: String) {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        let folder = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard file.hasPrefix(folder + "/"), FileManager.default.fileExists(atPath: file) else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    private func send(_ method: String, _ item: DLItem) {
        guard let gid = item.gid else { return }
        Task {
            do { try await aria.call(method, [gid]) } catch { problem = error.localizedDescription }
            await poll()
        }
    }

    private func changeGlobal(_ options: [String: String]) {
        guard ready else { return }
        Task {
            do { try await aria.call("aria2.changeGlobalOption", [options]) } catch { problem = error.localizedDescription }
        }
    }

    // MARK: Polling

    private static let keys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "uploadSpeed",
                               "connections", "files", "bittorrent", "errorMessage", "dir", "followedBy", "seeder"]

    func poll() async {
        guard !launching else { return }
        guard ready else {
            if aria.process != nil, !aria.isRunning { ready = false; problem = "aria2c stopped. Restarting…"; start() }
            return
        }
        guard let results = try? await aria.multicall([
            ("aria2.tellActive", [Self.keys]),
            ("aria2.tellWaiting", [0, 1000, Self.keys]),
            ("aria2.tellStopped", [0, 1000, Self.keys]),
        ]) else {
            if !aria.isRunning, !launching { ready = false; problem = "aria2c stopped. Restarting…"; start() }
            return
        }
        var live: [DLItem] = []
        for result in results {
            guard case .success(let value) = result, let list = value as? [[String: Any]] else { continue }
            for raw in list { if let item = item(from: raw) { live.append(item) } }
        }

        // Finished downloads move into Pocket's own history; aria2 forgets them.
        var finishedNow: [String] = []
        for index in live.indices where live[index].status == .complete {
            var item = live[index]
            item.id = UUID().uuidString
            item.gid = nil
            item.speed = 0
            history.append(item)
            finishedNow.append(live[index].gid!)
            notifyDone(item)
        }
        if !finishedNow.isEmpty {
            saveHistory()
            live.removeAll { $0.status == .complete }
            Task { for gid in finishedNow { _ = try? await aria.call("aria2.removeDownloadResult", [gid]) } }
        }

        let all = (live + history).sorted { $0.added > $1.added }
        if all != items { items = all }
        let activeCount = live.filter { $0.status == .active || $0.status == .metadata }.count
        self.activeCount = activeCount
    }

    private func item(from raw: [String: Any]) -> DLItem? {
        guard let gid = raw["gid"] as? String, let statusText = raw["status"] as? String else { return nil }
        let files = raw["files"] as? [[String: Any]] ?? []
        let bt = raw["bittorrent"] as? [String: Any]
        let dir = raw["dir"] as? String ?? settings.folder.path
        let firstPath = (files.first?["path"] as? String) ?? ""
        let uris = files.flatMap { ($0["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String } }
        let uniqueURIs = Array(NSOrderedSet(array: uris)) as? [String] ?? uris
        // A magnet's metadata step is followed by the real torrent download; hide the finished step.
        if statusText == "complete", let followed = raw["followedBy"] as? [String], !followed.isEmpty { return nil }

        var name = (bt?["info"] as? [String: Any])?["name"] as? String ?? ""
        var path: String? = nil
        if !name.isEmpty {
            path = (dir as NSString).appendingPathComponent(name)
        } else if !firstPath.isEmpty, !firstPath.hasPrefix("[METADATA]") {
            name = (firstPath as NSString).lastPathComponent
            path = files.count == 1 ? firstPath : (dir as NSString).appendingPathComponent(((firstPath as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        }
        let total = Int64(raw["totalLength"] as? String ?? "") ?? 0
        let done = Int64(raw["completedLength"] as? String ?? "") ?? 0
        let metadata = firstPath.hasPrefix("[METADATA]")
        if name.isEmpty { name = metadata ? Self.magnetName(firstPath) : Self.linkName(uniqueURIs.first) }

        var status: DLItem.Status
        switch statusText {
        case "active": status = metadata ? .metadata : (bt != nil && total > 0 && done >= total ? .seeding : .active)
        case "waiting": status = .waiting
        case "paused": status = .paused
        case "complete": status = .complete
        default: status = .error
        }
        if statusText == "removed" { return nil }

        let date = added[gid] ?? Date()
        added[gid] = date
        return DLItem(id: gid, gid: gid, name: name, status: status, total: total, done: done,
                    speed: Int64(raw["downloadSpeed"] as? String ?? "") ?? 0,
                    upload: Int64(raw["uploadSpeed"] as? String ?? "") ?? 0,
                    connections: Int(raw["connections"] as? String ?? "") ?? 0,
                    path: path, dir: dir, uris: uniqueURIs,
                    error: status == .error ? (raw["errorMessage"] as? String ?? "Failed") : nil, added: date)
    }

    static func linkName(_ uri: String?) -> String {
        guard let uri, let url = URL(string: uri) else { return "Download" }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? "Download") : (last.removingPercentEncoding ?? last)
    }

    static func magnetName(_ path: String) -> String {
        if let magnet = URLComponents(string: String(path.dropFirst("[METADATA]".count))),
           let dn = magnet.queryItems?.first(where: { $0.name == "dn" })?.value { return dn }
        return "Torrent"
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: DLPaths.history, options: .atomic) }
    }

    // MARK: Notifications

    func requestNotifications() {
        guard settings.notify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyDone(_ item: DLItem) {
        dlLog("finished \(item.name)")
        guard settings.notify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Downloaded"
        content.body = item.name
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
}

/// Reads a Netscape cookies.txt for one-off `--load-cookies` flags pasted after a link.
enum DLCookies {
    static func header(file: String, for link: String?) -> String? {
        guard let link, let url = URL(string: link), let host = url.host?.lowercased(),
              let text = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) else { return nil }
        let now = Date().timeIntervalSince1970
        var pairs: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("#HttpOnly_") { line.removeFirst("#HttpOnly_".count) } else if line.hasPrefix("#") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { continue }
            let domain = f[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == domain || host.hasSuffix("." + domain) else { continue }
            guard url.path.isEmpty || url.path.hasPrefix(f[2]) else { continue }
            if f[3].uppercased() == "TRUE", url.scheme != "https" { continue }
            if let expires = Double(f[4]), expires > 0, expires < now { continue }
            pairs.append("\(f[5])=\(f[6])")
        }
        return pairs.isEmpty ? nil : "Cookie: " + pairs.joined(separator: "; ")
    }
}
