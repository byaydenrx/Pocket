// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx
// Ported from Tack (MIT, © 2026 Byaydenrx): convert, compress and upscale images.

import AppKit
import os
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum ImageToolInput {
    static let inputExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "avif", "tif", "tiff", "bmp"]

    static func isImage(_ url: URL) -> Bool {
        inputExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImageType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return inputExtensions.contains { ext in
            UTType(filenameExtension: ext).map { type.conforms(to: $0) } ?? false
        }
    }
}

enum ImageToolFormat: String, CaseIterable, Hashable {
    case jpg, png, webp, heic, avif

    var label: String { self == .webp ? "WebP" : rawValue.uppercased() }

    var typeIdentifier: String {
        switch self {
        case .jpg: "public.jpeg"
        case .png: "public.png"
        case .webp: "org.webmproject.webp"
        case .heic: "public.heic"
        case .avif: "public.avif"
        }
    }

    /// Quality used when converting into this format.
    var convertQuality: Double {
        switch self {
        case .jpg: 0.9
        case .webp: 0.9
        case .heic: 0.85
        case .avif: 0.8
        case .png: 1
        }
    }

    static func from(_ url: URL) -> ImageToolFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpg
        case "png": .png
        case "webp": .webp
        case "heic", "heif": .heic
        case "avif": .avif
        default: nil
        }
    }
}

enum ImageToolCompressLevel: String, CaseIterable, Hashable {
    case light, medium, strong

    var label: String { rawValue.capitalized }

    var quality: Double {
        switch self {
        case .light: 0.85
        case .medium: 0.7
        case .strong: 0.5
        }
    }

    var pngquantRange: String {
        switch self {
        case .light: "80-95"
        case .medium: "60-85"
        case .strong: "35-65"
        }
    }
}

enum ImageToolOperation: Hashable {
    case convert(ImageToolFormat)
    case compress(ImageToolCompressLevel)
    case upscale(Double)

    /// Parses "convert:jpg", "compress:medium" or "upscale:2" (used by the --process test mode).
    init?(spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "convert": guard let f = ImageToolFormat(rawValue: parts[1]) else { return nil }; self = .convert(f)
        case "compress": guard let l = ImageToolCompressLevel(rawValue: parts[1]) else { return nil }; self = .compress(l)
        case "upscale": guard let s = Double(parts[1]), s > 1 else { return nil }; self = .upscale(s)
        default: return nil
        }
    }

    var progressVerb: String {
        switch self {
        case .convert(let f): "Converting to \(f.label)"
        case .compress: "Compressing"
        case .upscale(let s): "Upscaling \(Int(s * 100))%"
        }
    }
}

struct ImageToolResult {
    var output: URL?
    var inBytes: Int
    var outBytes: Int
    var note: String?
}

struct ImageToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ImageToolBinaries {
    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let cwebp = find("cwebp")
    static let pngquant = find("pngquant")

    /// Runs a tool and returns its exit code; throws if it can't be launched.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            ImageToolLog.write("\(URL(fileURLWithPath: path).lastPathComponent) exited \(p.terminationStatus): \(msg.prefix(300))")
        }
        return p.terminationStatus
    }
}

enum ImageToolOps {
    static func process(_ op: ImageToolOperation, file: URL) throws -> ImageToolResult {
        let inBytes = fileSize(file)
        switch op {
        case .convert(let format):
            if ImageToolFormat.from(file) == format {
                return ImageToolResult(output: nil, inBytes: inBytes, outBytes: 0, note: "already \(format.label)")
            }
            let image = try loadOriented(file)
            let out = uniqueURL(in: outputDirectory(for: file), base: file.deletingPathExtension().lastPathComponent, ext: format.rawValue)
            try write(image, to: out, format: format, quality: format.convertQuality)
            return ImageToolResult(output: out, inBytes: inBytes, outBytes: fileSize(out))

        case .compress(let level):
            let format = ImageToolFormat.from(file) ?? .png
            let out = uniqueURL(in: outputDirectory(for: file), base: file.deletingPathExtension().lastPathComponent + "-min", ext: format.rawValue)
            if format == .png && ImageToolFormat.from(file) == .png, let pngquant = ImageToolBinaries.pngquant {
                let status = try ImageToolBinaries.run(pngquant, ["--quality=\(level.pngquantRange)", "--speed", "1", "--strip", "--force", "--output", out.path, file.path])
                if status != 0 {
                    try? FileManager.default.removeItem(at: out)
                    return ImageToolResult(output: nil, inBytes: inBytes, outBytes: 0, note: "can't shrink without visible loss")
                }
            } else {
                try write(try loadOriented(file), to: out, format: format, quality: level.quality)
            }
            let outBytes = fileSize(out)
            if outBytes >= inBytes {
                try? FileManager.default.removeItem(at: out)
                return ImageToolResult(output: nil, inBytes: inBytes, outBytes: 0, note: "already small")
            }
            return ImageToolResult(output: out, inBytes: inBytes, outBytes: outBytes)

        case .upscale(let scale):
            let format = ImageToolFormat.from(file) ?? .png
            let image = try upscaled(try loadOriented(file), by: scale)
            let out = uniqueURL(in: outputDirectory(for: file), base: file.deletingPathExtension().lastPathComponent + "@\(scaleLabel(scale))x", ext: format.rawValue)
            try write(image, to: out, format: format, quality: 0.92)
            return ImageToolResult(output: out, inBytes: inBytes, outBytes: fileSize(out))
        }
    }

    // MARK: Reading and writing

    /// Decodes the full image with its EXIF orientation applied.
    static func loadOriented(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageToolError("can't read \(url.lastPathComponent)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageToolError("can't decode \(url.lastPathComponent)")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL, format: ImageToolFormat, quality: Double) throws {
        if format == .webp {
            guard let cwebp = ImageToolBinaries.cwebp else { throw ImageToolError("WebP needs cwebp (brew install webp)") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try write(image, to: temp, format: .png, quality: 1)
            let status = try ImageToolBinaries.run(cwebp, ["-q", String(Int(quality * 100)), "-m", "6", "-mt", "-metadata", "icc", temp.path, "-o", url.path])
            if status != 0 { throw ImageToolError("WebP encoding failed") }
            return
        }
        let finalImage = format == .jpg ? flattened(image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw ImageToolError("can't write \(format.label)")
        }
        CGImageDestinationAddImage(dest, finalImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageToolError("failed writing \(url.lastPathComponent)") }
    }

    /// JPG has no transparency, so transparent pixels go on white instead of black.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func upscaled(_ image: CGImage, by scale: Double) throws -> CGImage {
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        let context = CIContext(options: [.workingColorSpace: space])
        guard let output = filter.outputImage,
              let result = context.createCGImage(output.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: space) else {
            throw ImageToolError("upscale failed")
        }
        return result
    }

    static func thumbnail(_ url: URL, size: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Files

    /// Next to the original, unless that's somewhere private (an app's storage, a temp folder) or read-only.
    static func outputDirectory(for file: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = file.deletingLastPathComponent().resolvingSymlinksInPath()
        let privatePrefixes = [home.appendingPathComponent("Library").path, "/private/var", "/var/folders", "/tmp", "/private/tmp"]
        if privatePrefixes.contains(where: { dir.path.hasPrefix($0) }) || !FileManager.default.isWritableFile(atPath: dir.path) {
            return home.appendingPathComponent("Downloads")
        }
        return dir
    }

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func scaleLabel(_ scale: Double) -> String {
        scale == scale.rounded() ? String(Int(scale)) : String(format: "%g", scale)
    }
}

enum ImageToolLog {
    private static let logger = Logger(subsystem: "com.byaydenrx.pocket", category: "image-tools")
    static func write(_ message: String) { logger.debug("\(message, privacy: .public)") }
}
