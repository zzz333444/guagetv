import Foundation
import SwiftUI

/// Danmaku (bullet comments): a small store + canvas renderer.
/// Data comes from a local file (bilibili-style XML or a JSON
/// array) or from a user-configured API template in Settings —
/// the engine renders scrolling (mode 1), top (5) and bottom (4)
/// comments synced to the active engine's clock.
struct DanmakuItem: Identifiable {
    let id: Int
    let time: Double
    let text: String
    let color: Color
    /// 1 = scrolling, 4 = bottom, 5 = top (bilibili modes).
    let mode: Int
}

final class DanmakuStore: ObservableObject {
    @Published var items: [DanmakuItem] = []

    func clear() {
        if !items.isEmpty { items = [] }
    }

    func load(data: Data) {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .gb18030_2000) ?? ""
        let parsed: [DanmakuItem]
        if text.contains("<d p=") || text.contains("<d p =") {
            parsed = Self.parseXML(text)
        } else {
            parsed = Self.parseJSON(text)
        }
        items = parsed.sorted { $0.time < $1.time }
    }

    // Bilibili XML: <d p="time,mode,size,color,timestamp,...">text</d>
    private static func parseXML(_ text: String) -> [DanmakuItem] {
        let delegate = DanmakuXMLDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    // JSON: [{"time":1.2,"text":"…","color":"#ffffff","mode":1}]
    // or the array-of-arrays shape some APIs return:
    // [[time, mode, colorInt, author, text], …]
    private static func parseJSON(_ text: String) -> [DanmakuItem] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [DanmakuItem] = []
        func add(time: Double, text: String, color: Color, mode: Int) {
            guard time >= 0, !text.isEmpty else { return }
            out.append(DanmakuItem(id: out.count, time: time, text: text,
                                   color: color, mode: mode))
        }
        if let array = root as? [[String: Any]] {
            for obj in array {
                let time = (obj["time"] as? NSNumber)?.doubleValue
                    ?? (obj["t"] as? NSNumber)?.doubleValue ?? -1
                let body = obj["text"] as? String ?? obj["content"] as? String ?? ""
                let mode = (obj["mode"] as? NSNumber)?.intValue ?? 1
                var color = Color.white
                if let hex = obj["color"] as? String {
                    color = colorFromHex(hex) ?? .white
                }
                add(time: time, text: body, color: color, mode: mode)
            }
        } else if let array = root as? [[Any]] {
            for row in array where row.count >= 5 {
                let time = (row[0] as? NSNumber)?.doubleValue ?? -1
                let mode = (row[1] as? NSNumber)?.intValue ?? 1
                let colorInt = (row[2] as? NSNumber)?.intValue ?? 0xFFFFFF
                let body = row[4] as? String ?? ""
                add(time: time, text: body, color: colorFromInt(colorInt), mode: mode)
            }
        } else if let obj = root as? [String: Any],
                  let list = (obj["data"] as? [[String: Any]]) ?? (obj["danmuku"] as? [[String: Any]]) {
            for entry in list {
                let time = (entry["time"] as? NSNumber)?.doubleValue ?? -1
                let body = entry["text"] as? String ?? ""
                add(time: time, text: body, color: .white, mode: 1)
            }
        }
        return out
    }

    static func colorFromInt(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = Int(s, radix: 16) else { return nil }
        return colorFromInt(value)
    }
}

private final class DanmakuXMLDelegate: NSObject, XMLParserDelegate {
    var items: [DanmakuItem] = []
    private var currentP: String?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "d" {
            currentP = attributeDict["p"]
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentP != nil { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", let p = currentP else { return }
        let fields = p.split(separator: ",")
        if fields.count >= 4,
           let time = Double(fields[0]),
           let mode = Int(fields[1]),
           let colorInt = Int(fields[3]) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                items.append(DanmakuItem(id: items.count, time: time, text: text,
                                         color: DanmakuStore.colorFromInt(colorInt),
                                         mode: mode))
            }
        }
        currentP = nil
    }
}

/// Canvas renderer: reads the ACTIVE controller's clock, so it
/// freezes when playback pauses and follows seeks for free.
struct DanmakuView: View {
    @ObservedObject var store: DanmakuStore
    @ObservedObject var mpv: MPVController
    @ObservedObject var native: NativeController
    let isMPV: Bool
    @AppStorage("danmaku.opacity") private var opacity = 0.9
    @AppStorage("danmaku.speed") private var speedFactor = 1.0

    private static let travel: Double = 9   // seconds to cross the screen
    private static let fontSize: CGFloat = 15
    private static let laneHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                draw(context: context, size: size)
            }
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let now = isMPV ? mpv.currentTime : native.currentTime
        guard now > 0, size.width > 40 else { return }
        var ctx = context
        ctx.opacity = opacity
        let travel = Self.travel / max(speedFactor, 0.2)
        let laneCount = max(3, Int((size.height * 0.45) / Self.laneHeight))
        for item in store.items {
            let age = now - item.time
            if item.mode == 1 {
                guard age >= 0, age < travel else { continue }
                let textWidth = estimateWidth(item.text)
                let progress = age / travel
                let x = size.width - progress * (size.width + textWidth)
                let lane = item.id % laneCount
                let y = 6 + CGFloat(lane) * Self.laneHeight
                drawText(item.text, color: item.color,
                         at: CGPoint(x: x, y: y), in: &ctx)
            } else if item.mode == 5, age >= 0, age < 4 {
                let x = (size.width - estimateWidth(item.text)) / 2
                drawText(item.text, color: item.color,
                         at: CGPoint(x: x, y: 6), in: &ctx)
            } else if item.mode == 4, age >= 0, age < 4 {
                let x = (size.width - estimateWidth(item.text)) / 2
                drawText(item.text, color: item.color,
                         at: CGPoint(x: x, y: size.height - 110), in: &ctx)
            }
        }
    }

    private func estimateWidth(_ text: String) -> CGFloat {
        var width: CGFloat = 0
        for scalar in text.unicodeScalars {
            width += scalar.value > 0x2E7F ? Self.fontSize : Self.fontSize * 0.55
        }
        return width
    }

    private func drawText(_ text: String, color: Color, at point: CGPoint,
                          in ctx: inout GraphicsContext) {
        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: Self.fontSize, weight: .semibold))
                .foregroundColor(color))
        ctx.draw(resolved, at: point, anchor: .topLeading)
    }
}
