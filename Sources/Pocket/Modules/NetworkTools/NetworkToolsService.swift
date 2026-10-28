// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Byaydenrx

import AppKit
import CoreWLAN
import SwiftUI

/// Everyday network checks in one place. Nothing runs until you open it, and
/// the public IP is only looked up when you ask for it.
@MainActor
final class NetworkToolsService: ObservableObject {
    static let shared = NetworkToolsService()

    struct Interface: Identifiable { let id: String; let name: String; let address: String; let isIPv6: Bool }

    @Published private(set) var interfaces: [Interface] = []
    @Published private(set) var publicIP: String?
    @Published private(set) var lookingUpPublicIP = false
    @Published private(set) var wifi: [(String, String)] = []
    @Published var pingHost = "1.1.1.1"
    @Published private(set) var pingOutput: String?
    @Published private(set) var pinging = false

    func syncWithPreferences() {}

    func refresh() {
        interfaces = Self.localAddresses()
        wifi = Self.wifiDetails()
    }

    func lookUpPublicIP() {
        lookingUpPublicIP = true
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.publicIP = text?.isEmpty == false ? text : "Unavailable"
                self.lookingUpPublicIP = false
            }
        }.resume()
    }

    func ping() {
        let host = pingHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !pinging,
              host.range(of: #"^[A-Za-z0-9.\-:]+$"#, options: .regularExpression) != nil else { NSSound.beep(); return }
        pinging = true
        pingOutput = "Pinging \(host)…"
        Task.detached {
            let result = Shell.run("/sbin/ping", ["-c", "4", "-t", "6", host], timeout: 12)
            let lines = result.output.split(separator: "\n")
            let summary = lines.filter { $0.contains("packet loss") || $0.contains("round-trip") }.joined(separator: "\n")
            await MainActor.run {
                self.pingOutput = summary.isEmpty ? (result.status == 0 ? result.output : "No reply from \(host).") : summary
                self.pinging = false
            }
        }
    }

    static func localAddresses() -> [Interface] {
        var result: [Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("fe80") { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            result.append(Interface(id: name + address, name: name, address: address, isIPv6: family == UInt8(AF_INET6)))
        }
        return result.sorted { ($0.isIPv6 ? 1 : 0, $0.name) < ($1.isIPv6 ? 1 : 0, $1.name) }
    }

    static func wifiDetails() -> [(String, String)] {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return [] }
        var rows: [(String, String)] = []
        if let ssid = interface.ssid() { rows.append(("Network", ssid)) }
        rows.append(("Signal", "\(interface.rssiValue()) dBm"))
        rows.append(("Noise", "\(interface.noiseMeasurement()) dBm"))
        if let channel = interface.wlanChannel() {
            let band: String
            switch channel.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default: band = ""
            }
            rows.append(("Channel", "\(channel.channelNumber) \(band)"))
        }
        rows.append(("Speed", "\(Int(interface.transmitRate())) Mb/s"))
        if let bssid = interface.bssid() { rows.append(("Router", bssid)) }
        return rows
    }
}

struct NetworkToolsView: View {
    @ObservedObject private var service = NetworkToolsService.shared
    @ObservedObject private var speed = SpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Addresses") {
                ForEach(service.interfaces) { iface in
                    row(iface.name, iface.address, copy: true)
                }
                HStack {
                    Text("Public").foregroundStyle(.secondary)
                    Spacer()
                    if let ip = service.publicIP {
                        Text(ip).monospaced().textSelection(.enabled)
                    } else {
                        Button(service.lookingUpPublicIP ? "Looking up…" : "Show") { service.lookUpPublicIP() }
                            .buttonStyle(.link)
                            .disabled(service.lookingUpPublicIP)
                    }
                }
            }
            if !service.wifi.isEmpty {
                group("Wi-Fi") {
                    ForEach(service.wifi, id: \.0) { item in row(item.0, item.1, copy: false) }
                }
            }
            group("Ping") {
                HStack {
                    TextField("Host", text: $service.pingHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { service.ping() }
                    Button(service.pinging ? "…" : "Ping") { service.ping() }.disabled(service.pinging)
                }
                if let output = service.pingOutput {
                    Text(output).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            group("Speed test") {
                HStack {
                    if let down = speed.downloadMbps { Label(String(format: "%.0f Mb/s", down), systemImage: "arrow.down") }
                    if let up = speed.uploadMbps { Label(String(format: "%.0f Mb/s", up), systemImage: "arrow.up") }
                    if let ping = speed.latencyMs { Label(String(format: "%.0f ms", ping), systemImage: "timer") }
                    Spacer()
                    Button("Run") { speed.start() }
                }
                .font(.callout.monospacedDigit())
            }
        }
        .font(.callout)
        .onAppear { service.refresh() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ label: String, _ value: String, copy: Bool) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}

struct NetworkToolsSection: View {
    var collapsible = true
    var body: some View {
        PanelSection(.networkTools, title: PanelSectionID.networkTools.title(L10n.shared.s), collapsible: collapsible) {
            NetworkToolsView()
        }
    }
}

struct NetworkToolsSettings: View {
    var body: some View {
        Form {
            Section { Text(AppFeature.networkTools.pocketDescription).font(.callout) }
            Section { NetworkToolsView() }
        }
        .formStyle(.grouped)
    }
}
