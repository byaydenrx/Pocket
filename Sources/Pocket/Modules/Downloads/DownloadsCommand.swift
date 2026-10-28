// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Fetch (MIT, © 2026 Byaydenrx).

import Foundation

/// One download to hand to aria2: links (mirrors of the same file), or a .torrent / .metalink file.
struct DLJob {
    enum Source { case uris([String]), torrent(URL), metalink(URL) }
    var source: Source
    var options: [String: Any] = [:]
}

/// Reads what you paste the way aria2c reads its command line: links, magnets, .torrent/.metalink paths and
/// any aria2c flags (`-x 8`, `--out=name.zip`, `--header "Cookie: …"`). A leading `aria2c` is ignored, each line
/// is its own download, and several links on one line are mirrors of one file unless `-Z` is given.
enum DLCommand {
    struct Parsed {
        var jobs: [DLJob] = []
        /// Flags that change aria2 as a whole (`-j`, `--max-overall-download-limit`), applied with changeGlobalOption.
        var global: [String: String] = [:]
        var problems: [String] = []
    }

    static let shortFlags: [Character: String] = [
        "t": "timeout", "m": "max-tries", "l": "log", "d": "dir", "o": "out", "s": "split", "D": "daemon",
        "V": "check-integrity", "c": "continue", "n": "no-netrc", "i": "input-file", "j": "max-concurrent-downloads",
        "Z": "force-sequential", "P": "parameterized-uri", "q": "quiet", "R": "remote-time",
        "x": "max-connection-per-server", "k": "min-split-size", "p": "ftp-pasv", "U": "user-agent", "S": "show-files",
        "u": "max-upload-limit", "T": "torrent-file", "O": "index-out", "M": "metalink-file",
    ]

    /// Flags whose value is optional (`--continue` alone means `--continue=true`), from `aria2c --help=#all`.
    static let optionalValue: Set<String> = [
        "help", "daemon", "allow-overwrite", "realtime-chunk-checksum", "check-integrity", "continue", "no-netrc",
        "deferred-input", "optimize-concurrent-downloads", "force-sequential", "auto-file-renaming", "parameterized-uri",
        "allow-piece-length-change", "no-conf", "quiet", "async-dns", "remote-time", "enable-rpc", "rpc-listen-all",
        "rpc-allow-origin-all", "rpc-secure", "rpc-save-upload-metadata", "dry-run", "reuse-uri", "disable-ipv6",
        "human-readable", "remove-control-file", "always-resume", "conditional-get", "enable-async-dns6",
        "show-console-readout", "truncate-console-readout", "pause", "hash-check-only", "enable-mmap", "force-save",
        "save-not-found", "enable-color", "pause-metadata", "stderr", "keep-unfinished-download-result", "ftp-pasv",
        "ftp-reuse-connection", "enable-http-keep-alive", "enable-http-pipelining", "check-certificate", "use-head",
        "http-auth-challenge", "http-no-cache", "http-accept-gzip", "content-disposition-default-utf8",
        "no-want-digest-header", "show-files", "enable-peer-exchange", "enable-dht", "enable-dht6", "bt-require-crypto",
        "bt-seed-unverified", "bt-hash-check-seed", "bt-save-metadata", "bt-metadata-only", "bt-enable-lpd",
        "bt-remove-unselected-file", "bt-detach-seed-only", "bt-force-encryption", "bt-enable-hook-after-hash-check",
        "bt-load-saved-metadata", "metalink-enable-unique-protocol", "version",
    ]

    /// Options aria2 only accepts for itself as a whole (aria2.changeGlobalOption), not per download.
    static let globalOnly: Set<String> = [
        "bt-max-open-files", "download-result", "keep-unfinished-download-result", "log", "log-level",
        "max-concurrent-downloads", "max-download-result", "max-overall-download-limit", "max-overall-upload-limit",
        "optimize-concurrent-downloads", "save-cookies", "save-session", "server-stat-of",
    ]

    /// Options that may be given more than once; aria2's RPC takes them as a list.
    static let repeatable: Set<String> = ["header", "index-out"]

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var shared: [String: Any] = [:]
        var lineJobs: [(targets: [String], options: [String: Any], sequential: Bool)] = []

        let joined = text.replacingOccurrences(of: "\\\n", with: " ")
        for line in joined.split(whereSeparator: \.isNewline) {
            var tokens = tokenize(String(line))
            if tokens.first == "aria2c" || tokens.first?.hasSuffix("/aria2c") == true { tokens.removeFirst() }
            var targets: [String] = []
            var options: [String: Any] = [:]
            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                i += 1
                var key: String?
                var value: String?
                if token.hasPrefix("--"), token.count > 2 {
                    let body = token.dropFirst(2)
                    if let eq = body.firstIndex(of: "=") {
                        key = String(body[..<eq]); value = String(body[body.index(after: eq)...])
                    } else {
                        key = String(body)
                    }
                } else if token.hasPrefix("-"), token.count >= 2, !token.hasPrefix("--"), let flag = shortFlags[token.dropFirst().first!] {
                    key = flag
                    let rest = token.dropFirst(2)
                    if !rest.isEmpty { value = rest.hasPrefix("=") ? String(rest.dropFirst()) : String(rest) }
                } else if token.hasPrefix("-"), token.count >= 2 {
                    parsed.problems.append("Unknown flag \(token)")
                    continue
                } else {
                    targets.append(expand(token))
                    continue
                }
                guard let name = key else { continue }
                if value == nil {
                    if optionalValue.contains(name) {
                        // `--continue false` is allowed too; anything else after a yes/no flag is a link.
                        if i < tokens.count, ["true", "false"].contains(tokens[i]) { value = tokens[i]; i += 1 } else { value = "true" }
                    } else if i < tokens.count {
                        value = tokens[i]; i += 1
                    } else {
                        parsed.problems.append("--\(name) needs a value")
                        continue
                    }
                }
                set(name, value!, in: &options)
            }

            // Flags that aren't per-download options for the RPC.
            if let file = options.removeValue(forKey: "torrent-file") as? String { targets.append(expand(file)) }
            if let file = options.removeValue(forKey: "metalink-file") as? String { targets.append(expand(file)) }
            if let file = options.removeValue(forKey: "input-file") as? String {
                let (jobs, problems) = readInputFile(expand(file))
                parsed.jobs += jobs
                parsed.problems += problems
            }
            let sequential = (options.removeValue(forKey: "force-sequential") as? String) == "true"
            for key in options.keys where globalOnly.contains(key) {
                parsed.global[key] = options.removeValue(forKey: key) as? String
            }
            if let dir = options["dir"] as? String { options["dir"] = expand(dir) }

            if targets.isEmpty { shared.merge(options) { _, new in new } } else { lineJobs.append((targets, options, sequential)) }
        }

        for line in lineJobs {
            let options = shared.merging(line.options) { _, new in new }
            let files = line.targets.filter(isLocalFile)
            let links = line.targets.filter { !isLocalFile($0) }
            for file in files { parsed.jobs.append(job(forFile: file, options: options)) }
            // A magnet or several mirrors make one download; -Z, or a magnet among links, makes one each.
            let magnets = links.filter { $0.lowercased().hasPrefix("magnet:") }
            let others = links.filter { !$0.lowercased().hasPrefix("magnet:") }
            for magnet in magnets { parsed.jobs.append(DLJob(source: .uris([magnet]), options: options)) }
            if line.sequential {
                for link in others { parsed.jobs.append(DLJob(source: .uris([link]), options: options)) }
            } else if !others.isEmpty {
                parsed.jobs.append(DLJob(source: .uris(others), options: options))
            }
        }
        for target in lineJobs.flatMap(\.targets) where !isLocalFile(target) && !looksLikeLink(target) {
            parsed.problems.append("“\(target)” isn't a link or file")
        }
        parsed.jobs.removeAll { job in
            if case .uris(let uris) = job.source { return uris.allSatisfy { !looksLikeLink($0) } }
            return false
        }
        return parsed
    }

    /// aria2's input-file format: a line of tab-separated mirrors, then indented `key=value` option lines.
    static func readInputFile(_ path: String) -> ([DLJob], [String]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ([], ["Can't read \(path)"]) }
        var jobs: [DLJob] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || raw.hasPrefix("#") { continue }
            if raw.first == " " || raw.first == "\t", !jobs.isEmpty {
                let pair = raw.trimmingCharacters(in: .whitespaces)
                if let eq = pair.firstIndex(of: "=") {
                    set(String(pair[..<eq]), String(pair[pair.index(after: eq)...]), in: &jobs[jobs.count - 1].options)
                }
            } else {
                let targets = raw.split(separator: "\t").map { expand(String($0)) }
                if let file = targets.first, targets.count == 1, isLocalFile(file) {
                    jobs.append(job(forFile: file, options: [:]))
                } else {
                    jobs.append(DLJob(source: .uris(targets)))
                }
            }
        }
        return (jobs, [])
    }

    static func job(forFile path: String, options: [String: Any]) -> DLJob {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        return DLJob(source: ext == "metalink" || ext == "meta4" ? .metalink(url) : .torrent(url), options: options)
    }

    static func looksLikeLink(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["http://", "https://", "ftp://", "sftp://", "magnet:"].contains { lower.hasPrefix($0) }
    }

    static func isLocalFile(_ s: String) -> Bool {
        guard !looksLikeLink(s) else { return false }
        let ext = (s as NSString).pathExtension.lowercased()
        return ["torrent", "metalink", "meta4"].contains(ext) && FileManager.default.fileExists(atPath: s)
    }

    private static func set(_ key: String, _ value: String, in options: inout [String: Any]) {
        if repeatable.contains(key) {
            options[key] = (options[key] as? [String] ?? []) + [value]
        } else {
            options[key] = value
        }
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    /// Splits like a shell: spaces separate, quotes group, backslash escapes.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape { current.append(ch); escape = false; inToken = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inToken = true; continue }
            if ch.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch)
            inToken = true
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
