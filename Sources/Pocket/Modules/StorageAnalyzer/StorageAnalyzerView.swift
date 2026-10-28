// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import SwiftUI

struct StorageAnalyzerSettings: View {
    /// Inside the menu panel: tighter padding.
    var compact = false
    @ObservedObject private var service = StorageAnalyzerService.shared
    @State private var tab = Tab.folders
    @State private var pendingTrash: StorageNode?

    private enum Tab: String { case folders, largest }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            volumesRow
            Divider()
            if service.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning… \(service.scannedFiles.formatted()) files")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Stop") { service.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let current = service.current, let root = service.root {
                HStack {
                    breadcrumb(current, root: root)
                    Spacer()
                    Picker("", selection: $tab) {
                        Text("Folders").tag(Tab.folders)
                        Text("Largest Files").tag(Tab.largest)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let rows = tab == .folders ? current.children : service.largestFiles
                        let top = max(rows.first?.size ?? 1, 1)
                        ForEach(rows) { node in
                            StorageRow(node: node, fraction: Double(node.size) / Double(top),
                                       showsPath: tab == .largest,
                                       open: { if node.isDirectory { service.current = node } },
                                       trash: { pendingTrash = node })
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Pick a drive or folder to see what takes up space.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Scan Home Folder") { service.scan(FileManager.default.homeDirectoryForCurrentUser) }
                            .buttonStyle(.borderedProminent)
                        Button("Choose Folder…") { chooseFolder() }
                    }
                    Text("Folders you have not given Pocket access to (Full Disk Access) count as empty.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(compact ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { service.refreshVolumes() }
        .onDisappear { service.release() }
        .alert("Move “\(pendingTrash?.name ?? "")” to the Trash?", isPresented: Binding(
            get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let node = pendingTrash { service.moveToTrash(node) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("\(ByteCountFormatter.string(fromByteCount: pendingTrash?.size ?? 0, countStyle: .file)) · You can put it back from the Trash.")
        }
    }

    private var volumesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(service.volumes) { volume in
                    Button { service.scan(volume.url) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                Text(volume.name).lineLimit(1)
                            }
                            .font(.callout.weight(.medium))
                            ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                                .tint(Double(volume.used) / Double(max(volume.total, 1)) > 0.9 ? .red : .accentColor)
                            Text("\(ByteCountFormatter.string(fromByteCount: volume.available, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(width: compact ? 170 : 210, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("Scan \(volume.name)")
                }
            }
        }
    }

    private func breadcrumb(_ node: StorageNode, root: StorageNode) -> some View {
        var chain: [StorageNode] = []
        var cursor: StorageNode? = node
        while let c = cursor { chain.insert(c, at: 0); if c === root { break }; cursor = c.parent }
        return HStack(spacing: 4) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(item.name) { service.current = item }
                    .buttonStyle(.plain)
                    .foregroundStyle(item === node ? .primary : .secondary)
                    .lineLimit(1)
            }
            Text("· \(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { service.scan(url) }
    }
}

private struct StorageRow: View {
    let node: StorageNode
    let fraction: Double
    let showsPath: Bool
    let open: () -> Void
    let trash: () -> Void
    @State private var hovering = false

    /// The stand-in row for trimmed files is not a real item.
    private var isReal: Bool { node.isDirectory || node.fileCount == 1 }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: isReal ? NSWorkspace.shared.icon(forFile: node.url.path) : NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage())
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.name).lineLimit(1)
                    if showsPath {
                        Text(node.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, geo.size.width * fraction))
                }
                .frame(height: 4)
            }
            if hovering, isReal {
                Button { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
                Button(action: trash) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Move to Trash")
            }
            if node.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) { open() }
    }
}
