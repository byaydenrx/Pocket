// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Fetch (MIT, © 2026 Byaydenrx).

import Foundation

/// Runs aria2c in the background as an RPC server and talks to it over JSON-RPC on localhost.
final class DLAria2 {
    enum Failure: LocalizedError {
        case notInstalled
        case exited(String)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Downloads needs aria2c, which isn't installed. Install it with: brew install aria2"
            case .exited(let message): return message.isEmpty ? "aria2c stopped unexpectedly." : message
            case .rpc(let message): return message
            }
        }
    }

    /// Homebrew's aria2 page: the install command, and what aria2 is.
    static let installHelp = URL(string: "https://formulae.brew.sh/formula/aria2")!

    /// The aria2c binary: Homebrew on Apple silicon or Intel, MacPorts, or anything on PATH.
    static func binary() -> URL? {
        var candidates = ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c", "/opt/local/bin/aria2c"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/aria2c")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private(set) var process: Process?
    private var port = 0
    private let secret = UUID().uuidString
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    var isRunning: Bool { process?.isRunning == true }

    /// Starts aria2c with `options` (aria2c command-line flags) and waits until its RPC server answers.
    func start(options: [String]) async throws {
        stop()
        guard let binary = Self.binary() else { throw Failure.notInstalled }
        port = Self.freePort()
        // Other accounts on this Mac can read a process's arguments, so the secret goes in a private config file.
        let conf = try writeConfig()
        defer { try? FileManager.default.removeItem(at: conf) }
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "--conf-path=\(conf.path)", "--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--console-log-level=error", "--summary-interval=0", "--show-console-readout=false",
        ] + options
        let errors = Pipe()
        p.standardOutput = errors
        p.standardError = errors
        try p.run()
        process = p

        // aria2c rejects bad flags right away; otherwise its RPC server is up within a few hundred ms.
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !p.isRunning {
                let output = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                process = nil
                throw Failure.exited(Self.cleanError(output))
            }
            if (try? await call("aria2.getVersion")) != nil { return }
        }
        throw Failure.exited("aria2c didn't start.")
    }

    /// A config file only you can read: your own aria2.conf (which `--conf-path` would otherwise skip) plus the RPC secret.
    /// aria2c reads it once at startup, and it's deleted as soon as the RPC server answers.
    private func writeConfig() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".config")
        let own = [home.appendingPathComponent(".aria2/aria2.conf"), xdg.appendingPathComponent("aria2/aria2.conf")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        var text = own.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        text += "\nrpc-secret=\(secret)\n"
        let url = DLPaths.support.appendingPathComponent("rpc-\(UUID().uuidString).conf")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure.exited("Couldn't write aria2c's settings file.")
        }
        return url
    }

    /// Saves unfinished downloads to the session file and stops aria2c.
    func shutdown() {
        guard isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        Task {
            _ = try? await self.call("aria2.saveSession")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
        stop()
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    @discardableResult
    func call(_ method: String, _ params: [Any] = []) async throws -> Any {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method,
                                   "params": ["token:\(secret)"] + params]
        return try await post(body)
    }

    /// Several calls in one request; each result is either the value or an error message.
    func multicall(_ calls: [(String, [Any])]) async throws -> [Result<Any, Failure>] {
        let list = calls.map { ["methodName": $0.0, "params": ["token:\(secret)"] + $0.1] as [String: Any] }
        let body: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "system.multicall", "params": [list]]
        let results = try await post(body) as? [Any] ?? []
        return results.map { item in
            if let wrapped = item as? [Any], let value = wrapped.first { return .success(value) }
            let message = (item as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure(.rpc(message))
        }
    }

    private func post(_ body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = reply["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "aria2c error")
        }
        return reply["result"] ?? NSNull()
    }

    /// aria2c prints a banner and "Exception caught" lines around the actual complaint; keep the complaint.
    static func cleanError(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let useful = lines.filter {
            !$0.hasPrefix("Usage:") && !$0.contains("Exception caught") && !$0.hasPrefix("See -h")
                && !$0.hasPrefix("[") && !$0.hasPrefix("->")
        }
        return (useful.isEmpty ? lines : useful).prefix(3).joined(separator: " ")
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port > 0 ? port : Int.random(in: 46800...46999)
    }
}
