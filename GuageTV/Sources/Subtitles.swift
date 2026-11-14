import Foundation
import SwiftUI

/// External subtitles: parse SRT / VTT / ASS files and render
/// them as an overlay synced to the active engine's clock, so
/// they work with both engines (unlike embedded track selection,
/// which only sees what the stream carries).
struct SubCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    static func parse(data: Data, fileName: String) -> [SubCue] {
        let text = guageDecodeText(data)
        let lower = fileName.lowercased()
        if lower.hasSuffix(".ass") || lower.hasSuffix(".ssa") || text.contains("[Events]") {
            return parseASS(text)
        }
        if lower.hasSuffix(".vtt") || text.hasPrefix("WEBVTT") {
            return parseTimedText(text, vtt: true)
        }
        return parseTimedText(text, vtt: false)
    }

    // SRT & VTT share the "start --> end" block shape.
    private static func parseTimedText(_ text: String, vtt: Bool) -> [SubCue] {
        var cues: [SubCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[arrow].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1]) else { continue }
            let body = lines[(arrow + 1)...]
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                cues.append(SubCue(start: start, end: end, text: body))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseTime(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let normalized = cleaned.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":")
        guard pieces.count >= 2,
              let seconds = Double(pieces[pieces.count - 1]),
              let minutes = Double(pieces[pieces.count - 2]) else { return nil }
        let hours = pieces.count >= 3 ? (Double(pieces[0]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    // ASS: [Events] Format line defines the column layout;
    // Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR,
    // MarginV, Effect, Text
    private static func parseASS(_ text: String) -> [SubCue] {
        var format: [String] = []
        var cues: [SubCue] = []
        var inEvents = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                format = line.dropFirst("Format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.hasPrefix("Dialogue:") {
                let body = String(line.dropFirst("Dialogue:".count))
                // Text is the LAST format column and may itself
                // contain commas — split only format.count - 1 times.
                let parts = body.split(separator: ",", maxSplits: max(format.count - 1, 0),
                                       omittingEmptySubsequences: false).map(String.init)
                guard format.count >= 3, parts.count == format.count,
                      let si = format.firstIndex(of: "start"),
                      let ei = format.firstIndex(of: "end"),
                      let ti = format.firstIndex(of: "text"),
                      let start = parseASSTime(parts[si]),
                      let end = parseASSTime(parts[ei]) else { continue }
                let cleaned = parts[ti]
                    .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    cues.append(SubCue(start: start, end: end, text: cleaned))
                }
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        parseTime(raw)
    }
}

/// Bottom-anchored cue text following the active engine's clock.
struct SubtitleOverlayView: View {
    let cues: [SubCue]
    @ObservedObject var mpv: MPVController
    @ObservedObject var native: NativeController
    let isMPV: Bool

    var body: some View {
        VStack {
            Spacer()
            if let cue = currentCue {
                Text(cue.text)
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 30)
            }
        }
        .padding(.bottom, 96)
    }

    private var currentCue: SubCue? {
        let now = isMPV ? mpv.currentTime : native.currentTime
        return cues.first { now >= $0.start && now <= $0.end }
    }
}

/// OpenSubtitles search: needs the user's own free API key
/// (Settings → 播放 → 外挂字幕）. Pick a result and its SRT is
/// downloaded and handed back parsed.
struct SubSearchView: View {
    let title: String
    let onApply: ([SubCue], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("subtitles.osKey") private var apiKey = ""
    @State private var query = ""
    @State private var results: [OSResult] = []
    @State private var searching = false
    @State private var downloadingID: Int?
    @State private var message: String?

    struct OSResult: Identifiable {
        let id: Int          // file_id
        let name: String
        let language: String
        let downloads: Int
    }

    var body: some View {
        NavigationStack {
            List {
                if apiKey.isEmpty {
                    Section {
                        Text("先在「设置 → 播放 → 外挂字幕」填你的 OpenSubtitles 免费 API Key（opensubtitles.com 注册后在 API consumers 里建一个），再回来搜。")
                            .font(.footnote)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Section {
                    HStack {
                        TextField("片名（英文更准）", text: $query)
                        Button("搜索") { Task { await search() } }
                            .disabled(searching || query.isEmpty || apiKey.isEmpty)
                    }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.textDim)
                }
                ForEach(results) { result in
                    Button {
                        Task { await download(result) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                Text("\(result.language) · 下载 \(result.downloads)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            if downloadingID == result.id {
                                ProgressView()
                            }
                        }
                    }
                }
            }
            .navigationTitle("在线字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if query.isEmpty { query = title } }
    }

    private func search() async {
        searching = true
        message = nil
        defer { searching = false }
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "languages", value: "zh-cn,zh-tw,en"),
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("GuageTV/1.40", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = json?["data"] as? [[String: Any]] ?? []
            results = rows.compactMap { row in
                guard let attrs = row["attributes"] as? [String: Any],
                      let files = attrs["files"] as? [[String: Any]],
                      let file = files.first,
                      let fileID = file["file_id"] as? NSNumber else { return nil }
                return OSResult(
                    id: fileID.intValue,
                    name: (file["file_name"] as? String) ?? "subtitle.srt",
                    language: (attrs["language"] as? String) ?? "",
                    downloads: (attrs["download_count"] as? NSNumber)?.intValue ?? 0)
            }
            if results.isEmpty { message = "没搜到，换个关键词试试" }
        } catch {
            message = "搜索失败：\(error.localizedDescription)"
        }
    }

    private func download(_ result: OSResult) async {
        downloadingID = result.id
        defer { downloadingID = nil }
        var request = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/download")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("GuageTV/1.40", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["file_id": result.id, "sub_format": "srt"])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let link = json?["link"] as? String, let url = URL(string: link) else {
                message = "下载链接获取失败（可能 Key 额度不足）"
                return
            }
            let (fileData, _) = try await URLSession.shared.data(from: url)
            let cues = SubtitleParser.parse(data: fileData, fileName: result.name)
            if cues.isEmpty {
                message = "下载到的字幕没解析出内容"
            } else {
                onApply(cues, result.name)
                dismiss()
            }
        } catch {
            message = "下载失败：\(error.localizedDescription)"
        }
    }
}
