// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

/// A folder in a scan. Files are not kept one by one: each folder remembers
/// its total, its subfolders and only its largest files, so scanning a whole
/// drive stays within a few megabytes.
final class StorageNode: Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    var size: Int64
    var fileCount: Int
    var children: [StorageNode]
    weak var parent: StorageNode?

    init(url: URL, isDirectory: Bool, size: Int64 = 0, fileCount: Int = 0, children: [StorageNode] = []) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.children = children
    }

    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

struct StorageVolume: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    var id: URL { url }
    var used: Int64 { max(0, total - available) }
}

@MainActor
final class StorageAnalyzerService: ObservableObject {
    static let shared = StorageAnalyzerService()


    @Published private(set) var volumes: [StorageVolume] = []
    @Published private(set) var root: StorageNode?
    @Published var current: StorageNode?
    @Published private(set) var scanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var largestFiles: [StorageNode] = []

    private var scanID = UUID()
    /// The running walk's counter; flipping its flag stops the walk.
    private var activeCounter: ScanCounter?

    func syncWithPreferences() {
        if !AppFeature.storageAnalyzer.isAvailable { release() }
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return StorageVolume(url: url, name: values.volumeName ?? url.lastPathComponent, total: Int64(total),
                                 available: available, isInternal: values.volumeIsInternal ?? false)
        }
    }

    /// Frees a finished scan (the page calls this when it goes away).
    func release() {
        cancel()
        root = nil
        current = nil
        largestFiles = []
    }

    func cancel() {
        activeCounter?.cancelled = true
        activeCounter = nil
        scanID = UUID()
        scanning = false
    }

    func scan(_ url: URL) {
        cancel()
        let id = UUID()
        scanID = id
        scanning = true
        scannedFiles = 0
        root = nil
        current = nil
        largestFiles = []
        let counter = ScanCounter()
        let progress = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scanID == id else { return }
                self.scannedFiles = counter.value
            }
        }
        Task.detached(priority: .utility) {
            let node = StorageScanner.scan(url, counter: counter, isCancelled: { counter.cancelled })
            let largest = StorageScanner.largestFiles(in: node, limit: 60)
            await MainActor.run {
                progress.invalidate()
                guard self.scanID == id else { return }
                self.root = node
                self.current = node
                self.largestFiles = largest
                self.scannedFiles = counter.value
                self.scanning = false
            }
        }
        activeCounter = counter
    }

    func moveToTrash(_ node: StorageNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            return
        }
        // Take it out of the tree and the totals above it.
        var parent = node.parent
        parent?.children.removeAll { $0 === node }
        while let p = parent {
            p.size -= node.size
            p.fileCount -= node.fileCount
            parent = p.parent
        }
        largestFiles.removeAll { $0 === node || $0.url.path.hasPrefix(node.url.path + "/") }
        objectWillChange.send()
        refreshVolumes()
    }
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var stop = false
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stop }
        set { lock.lock(); stop = newValue; lock.unlock() }
    }
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
}

enum StorageScanner {
    /// How many of a folder's largest files a scan keeps.
    static let filesKeptPerFolder = 12

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                 .fileAllocatedSizeKey, .isPackageKey, .volumeIdentifierKey]

    /// Walks `url`, its top-level folders in parallel. Stays on one volume and
    /// never follows symbolic links.
    static func scan(_ url: URL, counter: ScanCounter, isCancelled: @escaping () -> Bool) -> StorageNode {
        let root = StorageNode(url: url, isDirectory: true)
        let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var results = [StorageNode?](repeating: nil, count: entries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            let node = walk(entries[index], volume: volume, counter: counter, isCancelled: isCancelled)
            lock.lock(); results[index] = node; lock.unlock()
        }
        let children = results.compactMap { $0 }
        finish(root, children: children)
        return root
    }

    private static func walk(_ url: URL, volume: NSObject?, counter: ScanCounter, isCancelled: () -> Bool) -> StorageNode? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return nil }
        if values.isDirectory != true {
            counter.add(1)
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return StorageNode(url: url, isDirectory: false, size: size, fileCount: 1)
        }
        if let volume, let other = values.volumeIdentifier as? NSObject, !other.isEqual(volume) { return nil }
        let node = StorageNode(url: url, isDirectory: true)
        guard !isCancelled(),
              let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        else { return node }
        var children: [StorageNode] = []
        children.reserveCapacity(entries.count)
        for entry in entries {
            if let child = walk(entry, volume: volume, counter: counter, isCancelled: isCancelled) { children.append(child) }
        }
        finish(node, children: children)
        return node
    }

    /// Totals a folder and trims its loose files to the largest few.
    private static func finish(_ node: StorageNode, children: [StorageNode]) {
        var size: Int64 = 0
        var count = 0
        var folders: [StorageNode] = []
        var files: [StorageNode] = []
        for child in children {
            size += child.size
            count += child.fileCount
            if child.isDirectory { folders.append(child) } else { files.append(child) }
        }
        files.sort { $0.size > $1.size }
        if files.count > StorageScanner.filesKeptPerFolder {
            let rest = files[StorageScanner.filesKeptPerFolder...]
            let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
            files = Array(files.prefix(StorageScanner.filesKeptPerFolder))
            // One stand-in row carries the size of everything trimmed away.
            let other = StorageNode(url: node.url.appendingPathComponent("\(rest.count) smaller files"),
                                    isDirectory: false, size: restSize, fileCount: rest.count)
            files.append(other)
        }
        node.children = (folders + files).sorted { $0.size > $1.size }
        for child in node.children { child.parent = node }
        node.size = size
        node.fileCount = count
    }

    static func largestFiles(in node: StorageNode, limit: Int) -> [StorageNode] {
        var found: [StorageNode] = []
        func visit(_ n: StorageNode) {
            for child in n.children {
                if child.isDirectory { visit(child) } else if child.fileCount == 1 { found.append(child) }
            }
        }
        visit(node)
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}
