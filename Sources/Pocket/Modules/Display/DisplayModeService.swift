// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import CoreGraphics
import SwiftUI

/// BetterDisplay-style controls built on public CoreGraphics: every screen's
/// resolutions (HiDPI ones included), refresh rates, main display and mirroring,
/// with brightness from Pocket's brightness engine (DDC for external monitors).
@MainActor
final class DisplayModeService: ObservableObject {
    static let shared = DisplayModeService()

    struct Mode: Identifiable, Hashable {
        let id: String
        let width: Int
        let height: Int
        let pixelWidth: Int
        let refresh: Double
        let isHiDPI: Bool
        let ioModeID: Int32
        var label: String { "\(width) × \(height)" }
    }

    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltIn: Bool
        let isMain: Bool
        let current: Mode?
        let modes: [Mode]
        let mirrorOf: CGDirectDisplayID
    }

    static let showLowResKey = "displayShowLowResolution"

    @Published private(set) var screens: [Screen] = []
    @Published var message: String?

    private var reconfigureRegistered = false

    func syncWithPreferences() {
        if AppFeature.display.isAvailable { registerCallback() }
        // Brightness sliders live here now; the engine follows this feature.
        BrightnessService.shared.syncWithPreferences()
    }

    private func registerCallback() {
        guard !reconfigureRegistered else { return }
        reconfigureRegistered = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayModeService.shared.refresh() }
        }, nil)
    }

    func refresh() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        })
        let showLow = UserDefaults.standard.bool(forKey: Self.showLowResKey)
        screens = ids.prefix(Int(count)).map { id in
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            var seen = Set<String>()
            let modes = all.compactMap { mode -> Mode? in
                guard mode.isUsableForDesktopGUI() else { return nil }
                let hidpi = mode.pixelWidth > mode.width
                if !hidpi, !showLow, all.contains(where: { $0.width == mode.width && $0.height == mode.height && $0.pixelWidth > $0.width }) { return nil }
                let key = "\(mode.width)x\(mode.height)@\(Int(mode.refreshRate.rounded()))\(hidpi ? "h" : "")"
                guard seen.insert(key).inserted else { return nil }
                return Mode(id: key, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                            refresh: mode.refreshRate, isHiDPI: hidpi, ioModeID: mode.ioDisplayModeID)
            }
            .sorted { ($0.width, $0.height, $0.refresh) > ($1.width, $1.height, $1.refresh) }
            let current = CGDisplayCopyDisplayMode(id).map { mode in
                Mode(id: "current", width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                     refresh: mode.refreshRate, isHiDPI: mode.pixelWidth > mode.width, ioModeID: mode.ioDisplayModeID)
            }
            return Screen(id: id, name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"),
                          isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                          current: current, modes: modes, mirrorOf: CGDisplayMirrorsDisplay(id))
        }
    }

    func apply(_ mode: Mode, to display: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let target = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode])?
            .first(where: { $0.ioDisplayModeID == mode.ioModeID && $0.width == mode.width && $0.height == mode.height }) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        message = result == .success ? nil : "That mode couldn't be applied."
        refresh()
    }

    /// Makes `display` the main one (menu bar and Dock) by moving it to the origin.
    func makeMain(_ display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for screen in screens {
            let b = CGDisplayBounds(screen.id)
            CGConfigureDisplayOrigin(config, screen.id, Int32(b.minX - bounds.minX), Int32(b.minY - bounds.minY))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
        refresh()
    }

    func setMirroring(_ display: CGDirectDisplayID, of main: CGDirectDisplayID?) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, display, main ?? kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .permanently)
        refresh()
    }
}

struct DisplayControlsView: View {
    @ObservedObject private var service = DisplayModeService.shared
    @ObservedObject private var brightness = BrightnessService.shared
    @AppStorage(DefaultsKey.brightnessControlEnabled) private var brightnessEnabled = false
    @AppStorage(DisplayModeService.showLowResKey) private var showLowRes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(service.screens) { screen in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: screen.isBuiltIn ? "laptopcomputer" : "display")
                        Text(screen.name).font(.callout.weight(.semibold))
                        if screen.isMain { Text("Main").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                        Spacer()
                        if let current = screen.current {
                            Text("\(current.label) · \(Int(current.refresh.rounded())) Hz")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if brightnessEnabled, let level = brightness.displays.first(where: { $0.id == screen.id }), level.method != nil {
                        HStack {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { level.brightness },
                                                  set: { brightness.setBrightness($0, for: screen.id, announces: false) }))
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                        }
                    }
                    Menu {
                        let groups = Dictionary(grouping: screen.modes) { "\($0.width)×\($0.height)\($0.isHiDPI ? "h" : "")" }
                        let keys = screen.modes.map { "\($0.width)×\($0.height)\($0.isHiDPI ? "h" : "")" }
                        ForEach(Array(NSOrderedSet(array: keys)) as? [String] ?? [], id: \.self) { key in
                            let options = groups[key] ?? []
                            if options.count == 1, let mode = options.first {
                                Button(title(mode, current: screen.current)) { service.apply(mode, to: screen.id) }
                            } else if let first = options.first {
                                Menu(title(first, current: screen.current, rate: false)) {
                                    ForEach(options) { mode in
                                        Button("\(Int(mode.refresh.rounded())) Hz") { service.apply(mode, to: screen.id) }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Resolution", systemImage: "rectangle.expand.vertical")
                    }
                    .fixedSize()
                    HStack {
                        if !screen.isMain {
                            Button("Make Main") { service.makeMain(screen.id) }
                        }
                        if !screen.isBuiltIn, service.screens.count > 1 {
                            let main = service.screens.first(where: \.isMain)?.id
                            Button(screen.mirrorOf != kCGNullDirectDisplay ? "Stop Mirroring" : "Mirror Main") {
                                service.setMirroring(screen.id, of: screen.mirrorOf != kCGNullDirectDisplay ? nil : main)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                if screen.id != service.screens.last?.id { Divider() }
            }
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Toggle("Brightness sliders", isOn: $brightnessEnabled)
                    .onChange(of: brightnessEnabled) { _, _ in BrightnessService.shared.syncWithPreferences() }
                Spacer()
                Toggle("Low-resolution modes", isOn: $showLowRes)
                    .onChange(of: showLowRes) { _, _ in service.refresh() }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .onAppear {
            service.refresh()
            if brightnessEnabled { BrightnessService.shared.refresh(force: true) }
        }
    }

    private func title(_ mode: DisplayModeService.Mode, current: DisplayModeService.Mode?, rate: Bool = true) -> String {
        var text = mode.label
        if mode.isHiDPI { text += " (HiDPI)" }
        if rate { text += " · \(Int(mode.refresh.rounded())) Hz" }
        if let current, current.width == mode.width, current.height == mode.height, current.isHiDPI == mode.isHiDPI { text = "✓ " + text }
        return text
    }
}

struct DisplaySection: View {
    var collapsible = true
    var body: some View {
        PanelSection(.display, title: PanelSectionID.display.title(L10n.shared.s), collapsible: collapsible) {
            DisplayControlsView()
        }
    }
}

struct DisplaySettings: View {
    var body: some View {
        Form {
            Section {
                Text(AppFeature.display.pocketDescription).font(.callout)
                Text("Brightness for external monitors goes over DDC; monitors without DDC are dimmed in software. Extra XDR brightness lives in Energy & Display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { DisplayControlsView() }
        }
        .formStyle(.grouped)
    }
}
