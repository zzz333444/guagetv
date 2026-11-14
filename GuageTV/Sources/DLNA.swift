import Foundation
import Network
import SwiftUI

/// DLNA casting (v1.41): SSDP M-SEARCH discovery of
/// MediaRenderer devices on the LAN, then AVTransport SOAP
/// SetAVTransportURI + Play with the URL the player is
/// currently playing. The TV fetches the stream itself, so the
/// URL must be reachable from the TV's network — plain http(s)
/// source URLs work; URLs bound to this phone (local proxy /
/// Emby on localhost) do not.
enum DLNACaster {
    struct Device: Identifiable {
        var name: String
        var location: String
        var controlURL: String
        var id: String { controlURL }
    }

    /// One M-SEARCH round; collects renderer locations for
    /// `seconds`, then resolves each device description.
    static func discover(seconds: Double = 3.5) async -> [Device] {
        let locations = await ssdpSearch(seconds: seconds)
        var devices: [Device] = []
        for location in locations {
            if let device = await describe(location: location) {
                devices.append(device)
            }
        }
        return devices
    }

    private static func ssdpSearch(seconds: Double) async -> [String] {
        await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host("239.255.255.250")
            let port = NWEndpoint.Port(rawValue: 1900)!
            let connection = NWConnection(host: host, port: port, using: .udp)
            var locations: [String] = []
            var finished = false
            func finish() {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: locations)
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let request = """
                    M-SEARCH * HTTP/1.1\r
                    HOST: 239.255.255.250:1900\r
                    MAN: "ssdp:discover"\r
                    MX: 3\r
                    ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
                    \r

                    """
                    connection.send(content: Data(request.utf8), completion: .idempotent)
                    func receive() {
                        connection.receive(minimumIncompleteLength: 1,
                                           maximumLength: 65536) { data, _, _, _ in
                            if let data, let text = String(data: data, encoding: .utf8) {
                                for line in text.components(separatedBy: "\r\n")
                                where line.lowercased().hasPrefix("location:") {
                                    let value = line.dropFirst("location:".count)
                                        .trimmingCharacters(in: .whitespaces)
                                    if !value.isEmpty, !locations.contains(value) {
                                        locations.append(value)
                                    }
                                }
                            }
                            if !finished { receive() }
                        }
                    }
                    receive()
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        finish()
                    }
                } else if case .failed = state {
                    finish()
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func describe(location: String) async -> Device? {
        guard let url = URL(string: location),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let delegate = DescriptionDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(),
              let control = delegate.controlURL, !control.isEmpty else { return nil }
        let absolute = URL(string: control, relativeTo: url)?.absoluteString ?? control
        return Device(name: delegate.friendlyName.isEmpty ? (url.host ?? "DLNA 设备") : delegate.friendlyName,
                      location: location, controlURL: absolute)
    }

    static func cast(device: Device, mediaURL: String, title: String) async throws {
        let escapedURL = xmlEscape(mediaURL)
        let escapedTitle = xmlEscape(title.isEmpty ? "GuageTV" : title)
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(escapedTitle)</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/*:*">\(escapedURL)</res></item></DIDL-Lite>
        """
        try await soap(device: device, action: "SetAVTransportURI", body: """
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>\(escapedURL)</CurrentURI><CurrentURIMetaData>\(xmlEscape(didl))</CurrentURIMetaData></u:SetAVTransportURI>
        """)
        try await soap(device: device, action: "Play", body: """
        <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
        """)
    }

    private static func soap(device: Device, action: String, body: String) async throws {
        guard let url = URL(string: device.controlURL) else {
            throw messageError("设备地址不对")
        }
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw messageError("电视返回 HTTP \(http.statusCode)")
        }
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func messageError(_ text: String) -> NSError {
        NSError(domain: "DLNA", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private final class DescriptionDelegate: NSObject, XMLParserDelegate {
    var friendlyName = ""
    var controlURL: String?
    private var current = ""
    private var buffer = ""
    private var pendingServiceType = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        current = element
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "friendlyName" { friendlyName = text }
        if element == "serviceType" { pendingServiceType = text }
        if element == "controlURL",
           pendingServiceType.contains("AVTransport"), controlURL == nil {
            controlURL = text
        }
        buffer = ""
    }
}

/// Device picker presented from the player.
struct DLNACastView: View {
    let mediaURL: String
    let title: String
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [DLNACaster.Device] = []
    @State private var searching = true
    @State private var castingID: String?

    var body: some View {
        NavigationStack {
            Group {
                if searching {
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.text)
                        Text("正在搜索局域网里的电视…")
                            .font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if devices.isEmpty {
                    Text("没找到 DLNA 设备。确认电视开着、和手机连同一个 Wi-Fi，且电视的投屏/DLNA 功能已开。")
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(devices) { device in
                        Button {
                            cast(to: device)
                        } label: {
                            HStack {
                                Label(device.name, systemImage: "tv")
                                Spacer()
                                if castingID == device.id {
                                    ProgressView()
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.bg)
            .navigationTitle("DLNA 投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            devices = await DLNACaster.discover()
            searching = false
        }
    }

    private func cast(to device: DLNACaster.Device) {
        castingID = device.id
        Task {
            do {
                try await DLNACaster.cast(device: device, mediaURL: mediaURL, title: title)
                onResult("已投到 \(device.name)")
                dismiss()
            } catch {
                onResult("投屏失败：\(error.localizedDescription)")
                dismiss()
            }
        }
    }
}
