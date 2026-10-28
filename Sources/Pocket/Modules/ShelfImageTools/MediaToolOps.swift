// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What kind of files the shelf tools act on: decides which three actions show.
enum ShelfMediaKind: String {
    case image, video, audio, pdf

    static func of(_ url: URL) -> ShelfMediaKind? {
        if ImageToolInput.isImage(url) { return .image }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// The kind most of the files share, or nil when none is supported.
    static func dominant(in urls: [URL]) -> ShelfMediaKind? {
        let kinds = urls.compactMap(of)
        guard !kinds.isEmpty else { return nil }
        let counts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Video, audio and PDF jobs, all with system frameworks (no installs).
enum MediaToolOps {
    enum VideoFormat: String { case mp4, mov, gif }
    enum VideoQuality: String { case high, medium, low }
    enum AudioFormat: String { case m4a, wav, aiff, mp3 }

    // MARK: Video

    static func convertVideo(_ file: URL, to format: VideoFormat) async throws -> URL {
        if format == .gif { return try makeGIF(file) }
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent, ext: format.rawValue)
        try await export(file, to: out, preset: AVAssetExportPresetHighestQuality,
                         type: format == .mp4 ? .mp4 : .mov)
        return out
    }

    static func compressVideo(_ file: URL, _ quality: VideoQuality) async throws -> URL {
        let preset: String
        switch quality {
        case .high: preset = AVAssetExportPresetHEVC1920x1080
        case .medium: preset = AVAssetExportPreset1280x720
        case .low: preset = AVAssetExportPreset960x540
        }
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent + "-min", ext: "mp4")
        try await export(file, to: out, preset: preset, type: .mp4)
        return out
    }

    static func resizeVideo(_ file: URL, height: Int) async throws -> URL {
        let preset: String
        switch height {
        case 2160: preset = AVAssetExportPreset3840x2160
        case 1080: preset = AVAssetExportPreset1920x1080
        case 720: preset = AVAssetExportPreset1280x720
        default: preset = AVAssetExportPreset640x480
        }
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent + "-\(height)p", ext: "mp4")
        try await export(file, to: out, preset: preset, type: .mp4)
        return out
    }

    private static func export(_ file: URL, to out: URL, preset: String, type: AVFileType) async throws {
        let asset = AVURLAsset(url: file)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ImageToolError("can't export \(file.lastPathComponent)")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if session.status != .completed {
            try? FileManager.default.removeItem(at: out)
            throw ImageToolError(session.error?.localizedDescription ?? "export failed")
        }
    }

    /// A looping GIF, 12 frames a second, at most 600 px wide and 20 seconds.
    private static func makeGIF(_ file: URL) throws -> URL {
        let asset = AVURLAsset(url: file)
        let duration = min(CMTimeGetSeconds(asset.duration), 20)
        guard duration > 0 else { throw ImageToolError("can't read \(file.lastPathComponent)") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let fps = 12.0
        let count = max(1, Int(duration * fps))
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ImageToolError("can't write GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                CGImageDestinationAddImage(dest, image, frame)
            }
        }
        guard CGImageDestinationFinalize(dest) else { throw ImageToolError("GIF failed") }
        return out
    }

    // MARK: Audio

    static func convertAudio(_ file: URL, to format: AudioFormat) async throws -> URL {
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent, ext: format.rawValue)
        switch format {
        case .m4a:
            try await export(file, to: out, preset: AVAssetExportPresetAppleM4A, type: .m4a)
        case .mp3:
            guard let lame = ImageToolBinaries.find("lame") else { throw ImageToolError("MP3 needs lame (brew install lame)") }
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try writePCM(file, to: wav, type: .wav)
            if try ImageToolBinaries.run(lame, ["-V2", "--quiet", wav.path, out.path]) != 0 { throw ImageToolError("MP3 encoding failed") }
        case .wav: try writePCM(file, to: out, type: .wav)
        case .aiff: try writePCM(file, to: out, type: .aiff)
        }
        return out
    }

    static func compressAudio(_ file: URL, kbps: Int) throws -> URL {
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent + "-\(kbps)k", ext: "m4a")
        let input = try AVAudioFile(forReading: file)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: input.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: input.fileFormat.channelCount,
                                       AVEncoderBitRateKey: kbps * 1000]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try copyFrames(from: input, to: output, rate: 1)
        return out
    }

    /// Changes speed (and pitch, like a tape) by resampling.
    static func changeSpeed(_ file: URL, rate: Double) throws -> URL {
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent + "-\(ImageToolOps.scaleLabel(rate))x", ext: "m4a")
        let input = try AVAudioFile(forReading: file)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: input.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: input.fileFormat.channelCount,
                                       AVEncoderBitRateKey: 192_000]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try copyFrames(from: input, to: output, rate: rate)
        return out
    }

    private static func writePCM(_ file: URL, to out: URL, type: AVFileType) throws {
        let input = try AVAudioFile(forReading: file)
        var settings = input.fileFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = type == .aiff
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try copyFrames(from: input, to: output, rate: 1)
    }

    private static func copyFrames(from input: AVAudioFile, to output: AVAudioFile, rate: Double) throws {
        let format = input.processingFormat
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ImageToolError("audio buffer") }
        if rate == 1 {
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return
        }
        // Resample by picking frames at `rate` steps (linear interpolation).
        let outCapacity = AVAudioFrameCount(Double(chunk) / rate) + 2
        guard let resampled = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { throw ImageToolError("audio buffer") }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            let outFrames = Int(Double(n) / rate)
            for ch in 0..<Int(format.channelCount) {
                guard let src = buffer.floatChannelData?[ch], let dst = resampled.floatChannelData?[ch] else { continue }
                for i in 0..<outFrames {
                    let pos = Double(i) * rate
                    let j = Int(pos)
                    let f = Float(pos - Double(j))
                    let a = src[min(j, n - 1)], b = src[min(j + 1, n - 1)]
                    dst[i] = a + (b - a) * f
                }
            }
            resampled.frameLength = AVAudioFrameCount(outFrames)
            try output.write(from: resampled)
        }
    }

    // MARK: PDF

    static func mergePDFs(_ files: [URL]) throws -> URL {
        guard let first = files.first else { throw ImageToolError("no PDFs") }
        let merged = PDFDocument()
        for file in files {
            guard let doc = PDFDocument(url: file) else { continue }
            for i in 0..<doc.pageCount { if let page = doc.page(at: i) { merged.insert(page, at: merged.pageCount) } }
        }
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: first), base: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ImageToolError("can't write the merged PDF") }
        return out
    }

    static func compressPDF(_ file: URL) throws -> URL {
        guard let doc = PDFDocument(url: file) else { throw ImageToolError("can't read \(file.lastPathComponent)") }
        let out = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                         base: file.deletingPathExtension().lastPathComponent + "-min", ext: "pdf")
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.0, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: out, withOptions: options) else { throw ImageToolError("can't write PDF") }
        return out
    }

    static func pdfToImages(_ file: URL, format: ImageToolFormat) throws -> [URL] {
        guard let doc = PDFDocument(url: file) else { throw ImageToolError("can't read \(file.lastPathComponent)") }
        let folder = ImageToolOps.uniqueURL(in: ImageToolOps.outputDirectory(for: file),
                                            base: file.deletingPathExtension().lastPathComponent + " pages", ext: "")
            .deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let out = folder.appendingPathComponent("Page \(i + 1).\(format.rawValue)")
            try ImageToolOps.write(cg, to: out, format: format, quality: 0.9)
        }
        return [folder]
    }
}
