// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tack (MIT, © 2026 Byaydenrx): the Convert / Compress / Upscale
// strip, now inside the shelf instead of tracking another app's window.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShelfToolAction: String, CaseIterable, Identifiable {
    case convert, compress, upscale
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct ShelfToolOption: Identifiable {
    let id: String
    let label: String
    let operation: ImageToolOperation
}

/// What the strip is doing. One instance; the shelf hosts its view.
@MainActor
final class ShelfImageToolsModel: ObservableObject {
    static let shared = ShelfImageToolsModel()
    static let enabledKey = "shelfImageToolsEnabled"
    static let addResultsKey = "shelfImageToolsAddResults"

    @Published var expanded: ShelfToolAction?
    @Published var targeted: String?
    @Published private(set) var busyText: String?
    @Published private(set) var results: [URL] = []
    @Published private(set) var summary: String?

    var hasResults: Bool { summary != nil }
    var isBusy: Bool { busyText != nil }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func options(for action: ShelfToolAction) -> [ShelfToolOption] {
        switch action {
        case .convert:
            return ImageToolFormat.allCases
                .filter { $0 != .webp || ImageToolBinaries.cwebp != nil }
                .map { ShelfToolOption(id: "opt.convert.\($0.rawValue)", label: $0.label, operation: .convert($0)) }
        case .compress:
            return ImageToolCompressLevel.allCases.map {
                ShelfToolOption(id: "opt.compress.\($0.rawValue)", label: $0.label, operation: .compress($0))
            }
        case .upscale:
            return [1.5, 2, 3, 4].map {
                ShelfToolOption(id: "opt.upscale.\($0)", label: "\(Int($0 * 100))%", operation: .upscale($0))
            }
        }
    }

    func defaultOperation(for action: ShelfToolAction) -> ImageToolOperation {
        switch action {
        case .convert: return .convert(.jpg)
        case .compress: return .compress(.medium)
        case .upscale: return .upscale(2)
        }
    }

    func clearResults() {
        results = []
        summary = nil
    }

    /// The shelf's images the buttons act on: the selected ones when any are
    /// selected, otherwise every image on the shelf.
    func shelfImages(_ shelf: ShelfService) -> [URL] {
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
        let pool = files(selected.isEmpty ? shelf.items : selected)
        return pool.filter(ImageToolInput.isImage)
    }

    func run(_ operation: ImageToolOperation, on files: [URL]) {
        let images = files.filter(ImageToolInput.isImage)
        expanded = nil
        targeted = nil
        guard !images.isEmpty else {
            results = []
            summary = "No images there"
            return
        }
        busyText = "\(operation.progressVerb) \(images.count == 1 ? images[0].lastPathComponent : "\(images.count) images")…"
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var inBytes = 0, outBytes = 0
            var notes: [String] = []
            for file in images {
                do {
                    let r = try ImageToolOps.process(operation, file: file)
                    if let out = r.output {
                        outputs.append(out)
                        inBytes += r.inBytes
                        outBytes += r.outBytes
                    }
                    if let note = r.note { notes.append(images.count == 1 ? note : "\(file.lastPathComponent) \(note)") }
                } catch {
                    notes.append(error.localizedDescription)
                    ImageToolLog.write("\(operation) \(file.lastPathComponent) failed: \(error.localizedDescription)")
                }
            }
            let summary = Self.summarize(operation, count: outputs.count, inBytes: inBytes, outBytes: outBytes, notes: notes)
            let finished = outputs
            await MainActor.run {
                self.busyText = nil
                self.results = finished
                self.summary = summary
                let addBack = UserDefaults.standard.object(forKey: Self.addResultsKey) as? Bool ?? true
                if addBack, !finished.isEmpty { ShelfService.shared.addFiles(finished) }
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

/// The strip inside the shelf card.
struct ShelfImageToolsStrip: View {
    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var model = ShelfImageToolsModel.shared

    var body: some View {
        VStack(spacing: 6) {
            if let busy = model.busyText {
                busyRow(busy)
            } else if model.hasResults {
                resultsRow
            } else {
                HStack(spacing: 8) {
                    ForEach(ShelfToolAction.allCases) { box($0) }
                }
                .frame(height: 50)
                if let action = model.expanded {
                    optionsRow(action)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: model.expanded)
        .animation(.snappy(duration: 0.18), value: model.targeted)
        .animation(.snappy(duration: 0.18), value: model.summary)
    }

    private func box(_ action: ShelfToolAction) -> some View {
        let id = "box.\(action.rawValue)"
        let isOpen = model.expanded == action
        let isTarget = model.targeted == id
        return VStack(spacing: 4) {
            Image(systemName: action.symbol).font(.system(size: 13, weight: .medium))
            Text(action.title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isOpen || isTarget ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dashedBox(highlighted: isOpen || isTarget))
        .contentShape(Rectangle())
        .onTapGesture { model.expanded = isOpen ? nil : action }
        .onDrop(of: [.fileURL], delegate: ShelfToolDrop(id: id, model: model,
                                                        onEnter: { model.expanded = action },
                                                        operation: model.defaultOperation(for: action)))
        .help(action == .convert ? "Convert images to another format" : action == .compress ? "Make images smaller" : "Enlarge images")
    }

    private func optionsRow(_ action: ShelfToolAction) -> some View {
        HStack(spacing: 6) {
            ForEach(model.options(for: action)) { option in
                let isTarget = model.targeted == option.id
                Text(option.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isTarget ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isTarget ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isTarget ? 0 : 0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(option.operation, on: model.shelfImages(shelf)) }
                    .onDrop(of: [.fileURL], delegate: ShelfToolDrop(id: option.id, model: model, onEnter: {},
                                                                    operation: option.operation))
            }
        }
        .frame(height: 32)
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(dashedBox(highlighted: true))
    }

    private var resultsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.results.isEmpty ? "info.circle" : "checkmark.circle.fill")
                .foregroundStyle(model.results.isEmpty ? Color.secondary : Color.green)
            Text(model.summary ?? "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            if !model.results.isEmpty {
                circleButton("magnifyingglass", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.results)
                }
            }
            circleButton("xmark", help: "Done") { model.clearResults() }
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(dashedBox(highlighted: false))
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func dashedBox(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlighted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1.1, dash: highlighted ? [] : [5, 4]))
            )
    }
}

/// Hovering a box mid-drag opens its options; dropping on a box or an option
/// runs it on the dropped images.
private struct ShelfToolDrop: DropDelegate {
    let id: String
    let model: ShelfImageToolsModel
    let onEnter: () -> Void
    let operation: ImageToolOperation

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            model.targeted = id
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
        let operation = self.operation
        let model = self.model
        group.notify(queue: .main) {
            MainActor.assumeIsolated { model.run(operation, on: urls) }
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
            Toggle("Show Convert, Compress and Upscale when images are on the shelf", isOn: $enabled)
            Toggle("Put results back on the shelf", isOn: $addResults)
                .disabled(!enabled)
            Text("Results are saved next to the original, or in Downloads when the original sits somewhere private. Drop an image straight onto a button or option to process just that one.")
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
