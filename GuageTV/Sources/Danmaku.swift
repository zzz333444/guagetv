import Foundation
import SwiftUI

/// Decode user-supplied text files (danmaku / subtitles): UTF-8
/// first, then GB18030 for the many Chinese files still saved in
/// GBK. (String.Encoding has no named GB18030 member in the SDK,
/// hence the CoreFoundation conversion.)
func guageDecodeText(_ data: Data) -> String {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    return String(data: data, encoding: gb) ?? ""
}

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
        let text = guageDecodeText(data)
        var parsed: [DanmakuItem]
        if text.contains("<d p=") || text.contains("<d p =") {
            parsed = Self.parseXML(text)
        } else {
            parsed = Self.parseJSON(text)
        }
        // 屏蔽词 (v1.42): keywords from Settings → 播放 → 弹幕；
        // a danmaku containing any of them never reaches the
        // screen.
        let raw = UserDefaults.standard.string(forKey: "danmaku.blockWords") ?? ""
        let words = raw.split(whereSeparator: { ",，、 ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !words.isEmpty {
            parsed = parsed.filter { item in
                !words.contains { item.text.contains($0) }
            }
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
    // or Forward format 1: [{"p":"time,mode,size,color,…","m":"text"}]
    // or Forward format 2: [[time, "0", "#fff", "", "text"], …]
    // Numbers may arrive as strings (JS round trip); colors as
    // "#fff" / "#ffffff" or ints.
    private static func parseJSON(_ text: String) -> [DanmakuItem] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [DanmakuItem] = []
        func add(time: Double, text: String, color: Color, mode: Int) {
            guard time >= 0, !text.isEmpty else { return }
            out.append(DanmakuItem(id: out.count, time: time, text: text,
                                   color: color, mode: mode))
        }
        func addDict(_ obj: [String: Any]) {
            // Forward format 1: p = "time,mode,size,color,…", m = text.
            if let p = obj["p"] as? String, let body = obj["m"] as? String {
                let fields = p.split(separator: ",")
                if fields.count >= 4,
                   let time = Double(fields[0]),
                   let mode = Int(fields[1]),
                   let colorInt = Int(fields[3]) {
                    add(time: time, text: body, color: colorFromInt(colorInt), mode: mode)
                }
                return
            }
            guard let time = anyDouble(obj["time"] ?? obj["t"]) else { return }
            let body = obj["text"] as? String ?? obj["content"] as? String
                ?? obj["m"] as? String ?? ""
            let mode = anyInt(obj["mode"]) ?? 1
            var color = Color.white
            if let hex = obj["color"] as? String {
                color = colorFromHex(hex) ?? .white
            } else if let n = obj["color"] as? NSNumber {
                color = colorFromInt(n.intValue)
            }
            add(time: time, text: body, color: color, mode: mode)
        }
        if let array = root as? [[String: Any]] {
            for obj in array { addDict(obj) }
        } else if let array = root as? [[Any]] {
            for row in array where row.count >= 5 {
                guard let time = anyDouble(row[0]) else { continue }
                // Forward format 2 position "0" = scrolling.
                let mode = (anyInt(row[1]) ?? 1) == 0 ? 1 : (anyInt(row[1]) ?? 1)
                let body = row[4] as? String ?? ""
                add(time: time, text: body, color: anyColor(row[2]), mode: mode)
            }
        } else if let obj = root as? [String: Any] {
            // Guide 弹幕章: {comments:[{p,m}]}, {danmuku:
            // [[time, pos, color, "", text]]} — the array-of-
            // arrays shape must be handled here too, not only
            // as a root array (v2.28: previously dropped).
            for key in ["data", "danmuku", "danmu", "comments"] {
                if let list = obj[key] as? [[String: Any]] {
                    for entry in list { addDict(entry) }
                    return out
                }
                if let rows = obj[key] as? [[Any]] {
                    for row in rows where row.count >= 5 {
                        guard let time = anyDouble(row[0]) else { continue }
                        let mode = (anyInt(row[1]) ?? 1) == 0 ? 1 : (anyInt(row[1]) ?? 1)
                        let body = row[4] as? String ?? ""
                        add(time: time, text: body, color: anyColor(row[2]), mode: mode)
                    }
                    return out
                }
            }
        }
        return out
    }

    /// NSNumber or a numeric string (JS values round-trip either way).
    private static func anyDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func anyInt(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func anyColor(_ v: Any?) -> Color {
        if let n = v as? NSNumber { return colorFromInt(n.intValue) }
        if let s = v as? String, let c = colorFromHex(s) { return c }
        return .white
    }

    static func colorFromInt(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        // 3-digit shorthand ("#fff" → "ffffff").
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
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
    /// v2.10: appearance keys shared with DanmakuSettingsView —
    /// read live here, so a change applies to the danmaku already
    /// on screen without reopening the player.
    @AppStorage("danmaku.fontSize") private var fontSize = 15.0
    @AppStorage("danmaku.area") private var areaFraction = 0.45
    @AppStorage("danmaku.outline") private var outline = true
    /// v2.28 (R3 加料): time offset in seconds — positive
    /// delays danmaku (a comment stamped t shows at t +
    /// offset). Read live here so it applies to module danmu
    /// exactly like file/API danmu (blockWords already filter
    /// in DanmakuStore.load, area already bounds the lanes).
    @AppStorage("danmaku.offset") private var offset = 0.0

    private static let travel: Double = 9   // seconds to cross the screen
    private var laneHeight: CGFloat { CGFloat(fontSize) + 9 }

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                draw(context: context, size: size)
            }
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let now = (isMPV ? mpv.currentTime : native.currentTime) - offset
        guard now > 0, size.width > 40 else { return }
        var ctx = context
        ctx.opacity = opacity
        let travel = Self.travel / max(speedFactor, 0.2)
        let laneCount = max(3, Int((size.height * CGFloat(areaFraction)) / laneHeight))
        for item in store.items {
            let age = now - item.time
            if item.mode == 1 {
                guard age >= 0, age < travel else { continue }
                let textWidth = estimateWidth(item.text)
                let progress = age / travel
                let x = size.width - progress * (size.width + textWidth)
                let lane = item.id % laneCount
                let y = 6 + CGFloat(lane) * laneHeight
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
            width += scalar.value > 0x2E7F ? CGFloat(fontSize) : CGFloat(fontSize) * 0.55
        }
        return width
    }

    private func drawText(_ text: String, color: Color, at point: CGPoint,
                          in ctx: inout GraphicsContext) {
        // 描边：先在上下左右各 1pt 处描一层黑字，再叠彩色字。
        if outline {
            let stroke = ctx.resolve(
                Text(text)
                    .font(.system(size: CGFloat(fontSize), weight: .semibold))
                    .foregroundColor(.black))
            for offset in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0),
                           CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
                ctx.draw(stroke, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y),
                         anchor: .topLeading)
            }
        }
        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: CGFloat(fontSize), weight: .semibold))
                .foregroundColor(color))
        ctx.draw(resolved, at: point, anchor: .topLeading)
    }
}

/// 弹幕外观 — 独立设置页（v2.10，R8）：字号 / 不透明度 /
/// 滚动速度 / 显示区域 / 描边。全部走 AppStorage，与
/// DanmakuView 读同一组键，改动立即生效（正在播放的弹幕
/// 也会跟着变）；顶部预览行实时反映当前设置。
struct DanmakuSettingsView: View {
    @AppStorage("danmaku.fontSize") private var fontSize = 15.0
    @AppStorage("danmaku.opacity") private var opacity = 0.9
    @AppStorage("danmaku.speed") private var speedFactor = 1.0
    @AppStorage("danmaku.area") private var areaFraction = 0.45
    @AppStorage("danmaku.outline") private var outline = true
    /// v2.28: offset in seconds (positive = later). Shared
    /// with DanmakuView; applies to module danmu too.
    @AppStorage("danmaku.offset") private var offset = 0.0

    var body: some View {
        SettingsPage(title: "弹幕外观") {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("预览").font(.headline).foregroundStyle(Theme.text)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: Theme.posterRadius)
                            .fill(Color.black.opacity(0.35))
                            .frame(height: 104)
                        VStack(alignment: .leading, spacing: 10) {
                            sample("这片绝了，泪目", color: .white)
                            sample("前方高能！！", color: .yellow)
                            sample("弹幕护体", color: .cyan)
                        }
                        .padding(12)
                    }
                    Text("改动立即生效，正在播放的弹幕也会跟着变。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }

            Text("字号与透明度").font(.headline).foregroundStyle(Theme.text)
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    sliderRow(title: "字号", valueText: "\(Int(fontSize))pt") {
                        Slider(value: $fontSize, in: 12...24, step: 1)
                    }
                    sliderRow(title: "不透明度", valueText: "\(Int(opacity * 100))%") {
                        Slider(value: $opacity, in: 0.2...1, step: 0.05)
                    }
                }
            }

            Text("滚动与区域").font(.headline).foregroundStyle(Theme.text)
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    sliderRow(title: "滚动速度", valueText: "\(String(format: "%.1fx", speedFactor))") {
                        Slider(value: $speedFactor, in: 0.5...2, step: 0.1)
                    }
                    sliderRow(title: "显示区域", valueText: "屏幕上部 \(Int(areaFraction * 100))%") {
                        Slider(value: $areaFraction, in: 0.25...1, step: 0.05)
                    }
                    sliderRow(title: "时间偏移", valueText: offset == 0 ? "不偏移" : (offset > 0 ? "延后 \(String(format: "%.1f", offset)) 秒" : "提前 \(String(format: "%.1f", -offset)) 秒")) {
                        Slider(value: $offset, in: -5...5, step: 0.5)
                    }
                    Text("弹幕与画面对不上时调这里：正值让弹幕晚出现、负值让它早出现；模块弹幕、文件弹幕、在线弹幕都走同一处。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Text("显示区域越小，滚动弹幕只占画面上方一块，不挡字幕与画面主体。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }

            Text("描边").font(.headline).foregroundStyle(Theme.text)
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("文字描边", isOn: $outline)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("给弹幕字加一圈黑边，亮画面上也看得清；关掉后字更干净。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private func sample(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(color)
            .opacity(opacity)
            .shadow(color: outline ? .black.opacity(0.9) : .clear,
                    radius: outline ? 1 : 0, x: 0, y: 0)
    }

    private func sliderRow<Content: View>(title: String, valueText: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.text)
                Spacer()
                Text(valueText).font(.subheadline).foregroundStyle(Theme.textDim)
                    .monospacedDigit()
            }
            content().tint(Theme.text)
        }
    }
}
