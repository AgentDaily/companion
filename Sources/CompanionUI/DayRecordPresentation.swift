import SwiftUI
import CompanionCore

/// Display-only formatting: the stored Markdown and task identifiers remain untouched.
struct DayRecordPresentation {
    struct Citation: Identifiable {
        let id: Int
        let sourceID: String
        let source: DayRecordEntry?
        var label: String {
            guard let source else { return sourceID.hasPrefix("quenda:") ? "Quenda 来源 \(id + 1)" : "来源 \(id + 1) · 未同步" }
            let time = source.date.formatted(.dateTime.hour().minute())
            switch source.kind {
            case .report: return source.date.formatted(.dateTime.month().day()) + " 日报 · \(id + 1)"
            case .hour: return time + " 小时记录 · \(id + 1)"
            default: return time + " 原文 · \(id + 1)"
            }
        }
    }
    enum Block: Equatable {
        case markdown(String)
        case task(String, checked: Bool)
    }
    let citations: [Citation]
    init(entry: DayRecordEntry, resolve: (String) -> DayRecordEntry?) {
        var ids = entry.sources.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // Include unresolved UUID references without displaying their technical identifiers.
        let pattern = #"\[([0-9A-Fa-f]{8}[-–][0-9A-Fa-f]{4}[-–][0-9A-Fa-f]{4}[-–][0-9A-Fa-f]{4}[-–][0-9A-Fa-f]{12})\]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let text = entry.text as NSString
        for match in regex.matches(in: entry.text, range: NSRange(location: 0, length: text.length)) {
            let id = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "–", with: "-")
            if !ids.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { ids.append(id) }
        }
        citations = ids.enumerated().map { Citation(id: $0.offset, sourceID: $0.element, source: resolve($0.element)) }
    }
    func display(_ markdown: String, links: Bool = true) -> String {
        var result = markdown
        for citation in citations {
            let pattern = "\\[" + NSRegularExpression.escapedPattern(for: citation.sourceID).replacingOccurrences(of: "-", with: "[-–]") + "\\]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let replacement = links ? "[\(citation.label)](dayrecord-source://reference/\(citation.id))" : "（\(citation.label)）"
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return result
    }
    func citation(url: URL) -> Citation? {
        guard url.scheme == "dayrecord-source", url.host == "reference", let index = Int(url.lastPathComponent) else { return nil }
        return citations.first { $0.id == index }
    }
    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = [], pending: [String] = []
        var fenced = false
        func flush() { if !pending.isEmpty { blocks.append(.markdown(pending.joined(separator: "\n"))); pending = [] } }
        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            if !fenced, let task = DayRecordEntry.taskText(line) {
                flush(); blocks.append(.task(task, checked: !line.hasPrefix("- [ ]")))
            } else { pending.append(line) }
        }
        flush(); return blocks
    }
    static func plain(_ markdown: String) -> String {
        String(((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)).characters)
    }
    static func title(_ entry: DayRecordEntry) -> String {
        let presentation = Self(entry: entry, resolve: { _ in nil })
        guard let line = entry.text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }) else { return "这一小时的记录" }
        let cleaned = plain(presentation.display(line, links: false)).replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        let topic = cleaned.components(separatedBy: CharacterSet(charactersIn: "：:")).first ?? cleaned
        return topic.count <= 24 ? topic : "这一小时的记录"
    }
}

struct DayRecordAnalysisContent: View {
    let entry: DayRecordEntry
    let presentation: DayRecordPresentation
    var taskCompleted: ((String) -> Bool)? = nil
    var toggleTask: ((String) -> Void)? = nil
    var tasksDisabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(DayRecordPresentation.blocks(entry.text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    MessageContentView(content: presentation.display(text)).textSelection(.enabled)
                case .task(let original, let checked):
                    let completed = taskCompleted?(original) ?? checked
                    HStack(alignment: .top, spacing: 12) {
                        if let toggleTask {
                            Button { toggleTask(original) } label: {
                                Image(systemName: completed ? "checkmark.square.fill" : "square").frame(width: 28, height: 32)
                            }.disabled(tasksDisabled).accessibilityLabel(completed ? "标记为未完成" : "完成待办")
                        } else { Image(systemName: completed ? "checkmark.square.fill" : "square") }
                        // Keep citation links separate from the checkbox's tap target.
                        MessageContentView(content: presentation.display(original)).strikethrough(completed).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }.font(.system(size: 15)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
    }
}
