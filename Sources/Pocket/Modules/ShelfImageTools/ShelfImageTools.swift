// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tack (MIT, © 2026 Byaydenrx): the Convert / Compress / Upscale
// strip, now inside the shelf instead of tracking another app's window.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One of the three actions the strip shows for a kind of file.
struct ShelfToolAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let help: String
    let options: [ShelfToolOption]
}

struct ShelfToolOption: Identifiable {
    let id: String
    let label: String
    /// Runs on the files (already filtered to the strip's kind); returns what it made.
    let run: @Sendable ([URL]) async throws -> (outputs: [URL], summary: String)
}

/// The strip's state. One instance; the shelf hosts its view.
@MainActor
final class ShelfImageToolsModel: ObservableObject {
    static let shared = ShelfImageToolsModel()
    static let enabledKey = "shelfImageToolsEnabled"
    static let addResultsKey = "shelfImageToolsAddResults"

    /// Which action's options the second row shows.
    @Published var activeActionID: String?
    @Published var targeted: String?
    @Published private(set) var busyText: String?
    @Published private(set) var results: [URL] = []
    @Published private(set) var summary: String?
    /// The kind of the files being dragged right now, if any.
    @Published var dragKind: ShelfMediaKind?

    var hasResults: Bool { summary != nil }
    var isBusy: Bool { busyText != nil }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func clearResults() {
        results = []
        summary = nil
    }

    /// The shelf's files the buttons act on: the selected ones when any are
    /// selected, otherwise everything on the shelf.
    func shelfFiles(_ shelf: ShelfService) -> [URL] {
        func files(_ items: [ShelfService.Item]) -> [URL] {
            items.flatMap { item -> [URL] in
                switch item.payload {
                case .file(let url): return [url]
                case .batch(let inner): return files(inner)
                default: return []
                }
            }
        }
        let selected = shelf.items.filter { shelf.selection.contains($0.id) }
        return files(selected.isEmpty ? shelf.items : selected)
    }

    /// What the strip offers now: the dragged files' kind, else the shelf's.
    func kind(_ shelf: ShelfService) -> ShelfMediaKind {
        dragKind ?? ShelfMediaKind.dominant(in: shelfFiles(shelf)) ?? .image
    }

    func actions(for kind: ShelfMediaKind) -> [ShelfToolAction] {
        func each(_ files: [URL], _ op: @escaping @Sendable (URL) async throws -> [URL]) async -> (outputs: [URL], summary: String) {
            var outs: [URL] = []
            var failures: [String] = []
            for file in files {
                do { outs += try await op(file) } catch { failures.append(error.localizedDescription) }
            }
            let bytes = outs.reduce(Int64(0)) { $0 + Int64(ImageToolOps.fileSize($1)) }
            let made = outs.isEmpty ? (failures.first ?? "Nothing to do")
                : "\(outs.count) made · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            return (outs, failures.isEmpty || outs.isEmpty ? made : made + " · \(failures.count) failed")
        }
        func imageOption(_ id: String, _ label: String, _ op: ImageToolOperation) -> ShelfToolOption {
            ShelfToolOption(id: id, label: label) { files in
                var outputs: [URL] = []
                var inBytes = 0, outBytes = 0
                var notes: [String] = []
                for file in files {
                    do {
                        let r = try ImageToolOps.process(op, file: file)
                        if let out = r.output { outputs.append(out); inBytes += r.inBytes; outBytes += r.outBytes }
                        if let note = r.note { notes.append(note) }
                    } catch { notes.append(error.localizedDescription) }
                }
                return (outputs, ShelfImageToolsModel.summarize(op, count: outputs.count, inBytes: inBytes,
                                                               outBytes: outBytes, notes: notes))
            }
        }
        switch kind {
        case .image:
            return [
                ShelfToolAction(id: "image.convert", title: "Convert", symbol: "arrow.triangle.2.circlepath",
                                help: "Convert images to another format",
                                options: ImageToolFormat.allCases.filter { $0 != .webp || ImageToolBinaries.cwebp != nil }
                                    .map { imageOption("image.convert.\($0.rawValue)", $0.label, .convert($0)) }),
                ShelfToolAction(id: "image.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                                help: "Make images smaller",
                                options: ImageToolCompressLevel.allCases.map {
                                    imageOption("image.compress.\($0.rawValue)", $0.label, .compress($0))
                                }),
                ShelfToolAction(id: "image.upscale", title: "Upscale", symbol: "arrow.up.left.and.arrow.down.right",
                                help: "Enlarge images",
                                options: [1.5, 2, 3, 4].map {
                                    imageOption("image.upscale.\($0)", "\(Int($0 * 100))%", .upscale($0))
                                }),
            ]
        case .video:
            return [
                ShelfToolAction(id: "video.convert", title: "Convert", symbol: "arrow.triangle.2.circlepath",
                                help: "Convert videos to MP4, MOV or an animated GIF",
                                options: [MediaToolOps.VideoFormat.mp4, .mov, .gif].map { format in
                                    ShelfToolOption(id: "video.convert.\(format.rawValue)", label: format.rawValue.uppercased()) { files in
                                        await each(files) { [try await MediaToolOps.convertVideo($0, to: format)] }
                                    }
                                }),
                ShelfToolAction(id: "video.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                                help: "Make videos smaller",
                                options: [("High", MediaToolOps.VideoQuality.high), ("Medium", .medium), ("Small", .low)].map { item in
                                    ShelfToolOption(id: "video.compress.\(item.1.rawValue)", label: item.0) { files in
                                        await each(files) { [try await MediaToolOps.compressVideo($0, item.1)] }
                                    }
                                }),
                ShelfToolAction(id: "video.resize", title: "Resize", symbol: "aspectratio",
                                help: "Change the video's resolution",
                                options: [2160, 1080, 720, 480].map { height in
                                    ShelfToolOption(id: "video.resize.\(height)", label: height == 2160 ? "4K" : "\(height)p") { files in
                                        await each(files) { [try await MediaToolOps.resizeVideo($0, height: height)] }
                                    }
                                }),
            ]
        case .audio:
            let formats: [MediaToolOps.AudioFormat] = ImageToolBinaries.find("lame") == nil ? [.m4a, .wav, .aiff] : [.m4a, .mp3, .wav, .aiff]
            return [
                ShelfToolAction(id: "audio.convert", title: "Convert", symbol: "arrow.triangle.2.circlepath",
                                help: "Convert audio to another format",
                                options: formats.map { format in
                                    ShelfToolOption(id: "audio.convert.\(format.rawValue)", label: format.rawValue.uppercased()) { files in
                                        await each(files) { [try await MediaToolOps.convertAudio($0, to: format)] }
                                    }
                                }),
                ShelfToolAction(id: "audio.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                                help: "Smaller AAC files",
                                options: [256, 160, 96, 64].map { kbps in
                                    ShelfToolOption(id: "audio.compress.\(kbps)", label: "\(kbps)k") { files in
                                        await each(files) { [try MediaToolOps.compressAudio($0, kbps: kbps)] }
                                    }
                                }),
                ShelfToolAction(id: "audio.speed", title: "Speed", symbol: "gauge.with.dots.needle.67percent",
                                help: "Speed up or slow down",
                                options: [0.75, 1.25, 1.5, 2].map { rate in
                                    ShelfToolOption(id: "audio.speed.\(rate)", label: "\(ImageToolOps.scaleLabel(rate))×") { files in
                                        await each(files) { [try MediaToolOps.changeSpeed($0, rate: rate)] }
                                    }
                                }),
            ]
        case .pdf:
            return [
                ShelfToolAction(id: "pdf.merge", title: "Merge", symbol: "doc.on.doc",
                                help: "Join the PDFs into one, in shelf order",
                                options: [ShelfToolOption(id: "pdf.merge.all", label: "Merge All") { files in
                                    let out = try MediaToolOps.mergePDFs(files)
                                    return ([out], "\(files.count) PDFs merged")
                                }]),
                ShelfToolAction(id: "pdf.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                                help: "Shrink the images inside the PDF",
                                options: [ShelfToolOption(id: "pdf.compress.screen", label: "For Screen") { files in
                                    await each(files) { [try MediaToolOps.compressPDF($0)] }
                                }]),
                ShelfToolAction(id: "pdf.images", title: "To Images", symbol: "photo.on.rectangle",
                                help: "Save every page as an image",
                                options: [ImageToolFormat.png, .jpg, .heic].map { format in
                                    ShelfToolOption(id: "pdf.images.\(format.rawValue)", label: format.label) { files in
                                        await each(files) { try MediaToolOps.pdfToImages($0, format: format) }
                                    }
                                }),
            ]
        }
    }

    func run(_ option: ShelfToolOption, kind: ShelfMediaKind, on files: [URL]) {
        let matching = files.filter { ShelfMediaKind.of($0) == kind }
        targeted = nil
        guard !matching.isEmpty else {
            results = []
            summary = "No \(kind.rawValue) files there"
            return
        }
        busyText = "Working on \(matching.count == 1 ? matching[0].lastPathComponent : "\(matching.count) files")…"
        Task.detached(priority: .userInitiated) {
            let result: (outputs: [URL], summary: String)
            do { result = try await option.run(matching) } catch { result = ([], error.localizedDescription) }
            await MainActor.run {
                self.busyText = nil
                self.results = result.outputs
                self.summary = result.summary
                let addBack = UserDefaults.standard.object(forKey: Self.addResultsKey) as? Bool ?? true
                let files = result.outputs.filter { !$0.hasDirectoryPath }
                if addBack, !files.isEmpty { ShelfService.shared.addFiles(files) }
            }
        }
    }

    nonisolated static func summarize(_ op: ImageToolOperation, count: Int, inBytes: Int, outBytes: Int, notes: [String]) -> String {
        guard count > 0 else { return notes.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Nothing to do" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        let sizes = "\(f.string(fromByteCount: Int64(inBytes))) → \(f.string(fromByteCount: Int64(outBytes)))"
        let what: String
        switch op {
        case .convert(let format): what = "\(count == 1 ? "" : "\(count) ")→ \(format.label)"
        case .compress:
            let saved = inBytes > 0 ? Int((1 - Double(outBytes) / Double(inBytes)) * 100) : 0
            what = "\(saved)% smaller"
        case .upscale(let s): what = "\(Int(s * 100))%"
        }
        let skipped = notes.isEmpty ? "" : " · \(notes.count) skipped"
        return "\(what) · \(sizes)\(skipped)"
    }
}

/// The strip inside the shelf card: always the same height, so the shelf
/// window is sized for it once and hovering or dragging never moves anything.
struct ShelfImageToolsStrip: View {
    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var model = ShelfImageToolsModel.shared

    static let height: CGFloat = 86

    var body: some View {
        let kind = model.kind(shelf)
        let actions = model.actions(for: kind)
        let active = actions.first { $0.id == model.activeActionID } ?? actions[0]
        Group {
            if let busy = model.busyText {
                statusPanel {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            } else if model.hasResults {
                statusPanel {
                    Image(systemName: model.results.isEmpty ? "info.circle" : "checkmark.circle.fill")
                        .foregroundStyle(model.results.isEmpty ? Color.secondary : Color.green)
                    Text(model.summary ?? "").font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if !model.results.isEmpty {
                        roundButton("magnifyingglass", help: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(model.results)
                        }
                    }
                    roundButton("xmark", help: "Done") { model.clearResults() }
                }
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in box(action, isActive: action.id == active.id, kind: kind) }
                    }
                    .frame(height: 44)
                    HStack(spacing: 6) {
                        ForEach(active.options) { option in chip(option, kind: kind) }
                    }
                    .frame(height: 30)
                }
            }
        }
        .frame(height: Self.height)
        .animation(.snappy(duration: 0.15), value: model.activeActionID)
        .animation(.snappy(duration: 0.15), value: model.targeted)
        .onChange(of: kind) { _, _ in model.activeActionID = nil }
    }

    private func box(_ action: ShelfToolAction, isActive: Bool, kind: ShelfMediaKind) -> some View {
        let isTarget = model.targeted == action.id
        return HStack(spacing: 5) {
            Image(systemName: action.symbol).font(.system(size: 11, weight: .semibold))
            Text(action.title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isActive || isTarget ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTarget ? Color.accentColor.opacity(0.28) : Color.primary.opacity(isActive ? 0.12 : 0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.activeActionID = action.id }
        .onHover { if $0 { model.activeActionID = action.id } }
        .onDrop(of: [.fileURL], delegate: ShelfToolDrop(id: action.id, model: model, kind: kind,
                                                        onEnter: { model.activeActionID = action.id },
                                                        option: action.options[0]))
        .help(action.help)
    }

    private func chip(_ option: ShelfToolOption, kind: ShelfMediaKind) -> some View {
        let isTarget = model.targeted == option.id
        return Text(option.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isTarget ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(isTarget ? Color.accentColor : Color.primary.opacity(0.08))
            )
            .contentShape(Capsule())
            .onTapGesture { model.run(option, kind: kind, on: model.shelfFiles(shelf)) }
            .onDrop(of: [.fileURL], delegate: ShelfToolDrop(id: option.id, model: model, kind: kind, onEnter: {},
                                                            option: option))
    }

    private func statusPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .pocketGlassCircle()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Dragging over a box shows its options; dropping on a box runs its first
/// option, on an option runs that one, on just the dropped files.
private struct ShelfToolDrop: DropDelegate {
    let id: String
    let model: ShelfImageToolsModel
    let kind: ShelfMediaKind
    let onEnter: () -> Void
    let option: ShelfToolOption

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            model.targeted = id
            if let kind = ShelfMediaKind.dominant(in: ShelfDragFiles.current()) { model.dragKind = kind }
            onEnter()
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if model.targeted == id { model.targeted = nil }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        let option = self.option, model = self.model
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let kind = ShelfMediaKind.dominant(in: urls) ?? self.kind
                model.dragKind = nil
                model.run(option, kind: kind, on: urls)
            }
        }
        return true
    }
}

/// Settings for the strip, shown on the Shelf page.
struct ShelfImageToolsSettings: View {
    @AppStorage(ShelfImageToolsModel.enabledKey) private var enabled = true
    @AppStorage(ShelfImageToolsModel.addResultsKey) private var addResults = true

    var body: some View {
        Section("Image tools") {
            Toggle("Show file tools in the shelf (three actions that match the file type)", isOn: $enabled)
            Toggle("Put results back on the shelf", isOn: $addResults)
                .disabled(!enabled)
            Text("Images: Convert, Compress, Upscale. Videos: Convert (MP4, MOV, GIF), Compress, Resize. Audio: Convert, Compress, Speed. PDFs: Merge, Compress, To Images. Results are saved next to the original (or in Downloads). Drop a file straight onto an action or option to process just that file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label(ImageToolBinaries.cwebp == nil ? "WebP output: needs cwebp" : "WebP output: ready",
                      systemImage: ImageToolBinaries.cwebp == nil ? "minus.circle" : "checkmark.circle")
                Label(ImageToolBinaries.pngquant == nil ? "Best PNG compression: needs pngquant" : "PNG compression: pngquant",
                      systemImage: ImageToolBinaries.pngquant == nil ? "minus.circle" : "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Optional. Install with Homebrew: brew install webp pngquant")
        }
    }
}

/// The files in the drag going on right now, read from the drag pasteboard.
enum ShelfDragFiles {
    static func current() -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
