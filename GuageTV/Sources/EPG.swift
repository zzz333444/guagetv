import Foundation

/// One programme in an EPG (electronic programme guide).
struct EPGProgramme: Identifiable {
    var title: String
    var start: Date
    var end: Date
    var id: String { title + "|" + String(start.timeIntervalSince1970) }

    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

/// XMLTV programme guides, as referenced by a config live's `epg`
/// field. Two shapes are supported:
///  - a plain XMLTV URL covering every channel at once;
///  - a per-channel template containing {name} / {date} placeholders
///    (FongMi convention), fetched on demand — its response may be
///    XMLTV or the simple {"list":[{title,start,end}]} JSON shape.
enum EPGService {

    /// Plain-mode fetch: returns programmes keyed BOTH by channel id
    /// and by display name, so a channel matches by tvg-id or name.
    static func fetchAll(epgURL: String, ua: String?) async -> [String: [EPGProgramme]] {
        guard let url = URL(string: epgURL),
              let data = try? await NetFetch.data(from: url, ua: ua ?? NetFetch.okhttpUA)
        else { return [:] }
        let parsed = XMLTVParser.parse(data: data)
        var out = parsed.programmes
        for (id, name) in parsed.channelNames where out[name] == nil {
            if let programmes = out[id] { out[name] = programmes }
        }
        return out
    }

    /// Template-mode fetch for one channel.
    static func fetchChannel(template: String, channelName: String, ua: String?) async -> [EPGProgramme] {
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let encoded = channelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelName
        let urlText = template
            .replacingOccurrences(of: "{name}", with: encoded)
            .replacingOccurrences(of: "{date}", with: today.string(from: Date()))
        guard let url = URL(string: urlText),
              let data = try? await NetFetch.data(from: url, ua: ua ?? NetFetch.okhttpUA)
        else { return [] }
        let xml = XMLTVParser.parse(data: data)
        if !xml.programmes.isEmpty {
            return xml.programmes.values.flatMap { $0 }.sorted { $0.start < $1.start }
        }
        return parseJSONList(data)
    }

    /// {"list":[{"title":…,"start":"19:30","end":"20:00"}]} — times
    /// are wall-clock on the requested date (today).
    private static func parseJSONList(_ data: Data) -> [EPGProgramme] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["list"] as? [[String: Any]] else { return [] }
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func time(_ raw: Any?) -> Date? {
            guard let text = raw as? String else { return nil }
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return cal.date(byAdding: DateComponents(hour: parts[0], minute: parts[1]), to: day)
        }
        return list.compactMap { item in
            guard let title = item["title"] as? String,
                  let start = time(item["start"]), let end = time(item["end"])
            else { return nil }
            return EPGProgramme(title: title, start: start, end: end)
        }.sorted { $0.start < $1.start }
    }
}

/// Minimal XMLTV reader (Foundation XMLParser): channel id →
/// display name, channel id → programmes for the current day.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private(set) var channelNames: [String: String] = [:]
    private(set) var programmes: [String: [EPGProgramme]] = [:]

    private var currentChannelId: String?
    private var inChannel = false
    private var currentProgramme: (channel: String, start: Date, end: Date)?
    private var currentElement = ""
    private var textBuffer = ""

    static func parse(data: Data) -> XMLTVParser {
        let parser = XMLTVParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        textBuffer = ""
        switch elementName {
        case "channel":
            inChannel = true
            currentChannelId = attributeDict["id"]
        case "programme":
            if let channel = attributeDict["channel"],
               let start = Self.parseDate(attributeDict["start"]),
               let stop = Self.parseDate(attributeDict["stop"]) {
                currentProgramme = (channel, start, stop)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "display-name", inChannel, let id = currentChannelId, !text.isEmpty {
            channelNames[id] = text
        }
        if elementName == "title", let programme = currentProgramme, !text.isEmpty {
            programmes[programme.channel, default: []].append(
                EPGProgramme(title: text, start: programme.start, end: programme.end))
        }
        if elementName == "channel" { inChannel = false; currentChannelId = nil }
        if elementName == "programme" { currentProgramme = nil }
        textBuffer = ""
    }

    /// XMLTV timestamps: "20251111193000 +0800" (offset optional).
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let withZone = DateFormatter()
        withZone.dateFormat = "yyyyMMddHHmmss Z"
        if let date = withZone.date(from: raw) { return date }
        let plain = DateFormatter()
        plain.dateFormat = "yyyyMMddHHmmss"
        return plain.date(from: raw)
    }
}
