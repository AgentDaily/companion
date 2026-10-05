#if os(macOS)
import Foundation

/// A small output contract for completion models; never imposed on autonomous agents.
struct DayRecordFindings {
    struct Item: Codable {
        let text: String
        let sources: [String]
        let quote: String
        init(text: String, sources: [String], quote: String = "") { self.text = text; self.sources = sources; self.quote = quote }
        private enum CodingKeys: String, CodingKey { case text, sources, quote }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decode(String.self, forKey: .text)
            sources = try values.decode([String].self, forKey: .sources)
            quote = try values.decodeIfPresent(String.self, forKey: .quote) ?? ""
        }
    }
    let aliases: [String: String]
    let material: String
    init(material: String, sources: [String]) {
        aliases = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ("S\($0.offset + 1)", $0.element) })
        var text = material
        for (alias, id) in aliases { text = text.replacingOccurrences(of: "[\(id)]", with: "[\(alias)]") }
        self.material = text
    }
    static func contract(fields: [String]) -> String {
        let meanings = ["timeline": "按时间排列的已发生活动和地点变化", "events": "重要事件及影响", "observations": "有依据的心情变化及不确定性", "encouragement": "直接对你说的理解和温和鼓励", "difficulties": "明确遇到的困难及可能原因", "strategies": "针对困难给出的一个具体、低负担的行动建议", "achievements": "已经发生的具体好事或进展", "recognition": "直接对你说的具体赞赏与认同", "mood_tags": "明确原话支持的简短情绪标签", "scene_tags": "有依据的简短场景标签", "topic_tags": "简短主题标签", "summary": "简短事实摘要", "todos": "用户明确承诺的行动", "history": "与已提供历史的关联", "uncertainties": "缺少证据而需要确认的事情"]
        let tagExamples = ["mood_tags": "开心", "scene_tags": "办公", "topic_tags": "蓝牙调试"]
        let example = "{" + fields.map { field in
            "\"" + field + "\":[{\"text\":\"" + (tagExamples[field] ?? meanings[field] ?? "简短中文正文") + "\",\"sources\":[\"S1\"],\"quote\":\"" + (field == "todos" ? "逐字复制原文中的明确承诺" : field == "mood_tags" ? "逐字复制原文中的情绪表达" : "") + "\"}]"
        }.joined(separator: ",") + "}"
        let quoteRule = fields.contains("mood_tags") ? "mood_tags 必须填写逐字支持情绪标签的原话 quote，其他字段可为空。" : "仅 todos 项必须有逐字可核对的明确承诺原话 quote；其他项 quote 可为空。"
        return """
        严格按以下完整结构返回一个 JSON 对象，字段名不变，用真实结果替换示例：
        \(example)
        每个字段是数组，0–5 项。每项只有 text（不超过150字的中文正文）、sources（资料中已有的 S 编号数组）、quote（原话，可为空）。不另加标题、表格或其他分析维度。
        \(quoteRule)text 中不放引用编号，sources 按该条内容对应的原文选择，不要沿用示例的 S1，不得编造、缩写或改名。无资料的字段返回 []。
        """
    }
    func decode(_ text: String, fields: [String]) throws -> [String: [Item]] {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```") {
            json = json.components(separatedBy: .newlines).dropFirst().dropLast().joined(separator: "\n")
        }
        let result = try JSONDecoder().decode([String: [Item]].self, from: Data(json.utf8))
        guard Set(result.keys) == Set(fields), result.values.allSatisfy({ items in
            items.count <= 5 && items.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 600 && $0.quote.count <= 300 && $0.sources.count <= 6 && $0.sources.allSatisfy { aliases[$0] != nil } }
        }) else { throw CompanionError.server("模型输出结构或来源编号不符合要求。") }
        return result
    }
    func render(_ items: [Item], tasks: Bool = false) -> String {
        guard !items.isEmpty else { return tasks ? "暂无明确承诺的待办。" : "这部分暂没有足够记录，待补充。" }
        return items.map { item in
            let text = item.text.components(separatedBy: .newlines).joined(separator: " ")
            let references = item.sources.compactMap { aliases[$0].map { "[\($0)]" } }.joined(separator: " ")
            return (tasks ? "- [ ] " : "- ") + text + (references.isEmpty ? "" : " " + references)
        }.joined(separator: "\n")
    }
    func supportedTask(_ item: Item, evidence: [DayRecordEntry], summaries: [DayRecordEntry] = []) -> Bool {
        let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard quote.count >= 4 else { return false }
        return item.sources.contains { alias in
            guard let id = aliases[alias] else { return false }
            let linked = Set([id] + (summaries.first { $0.id == id }?.sources ?? []))
            return evidence.contains { linked.contains($0.id) && $0.text.contains(quote) }
        }
    }
}
#endif
