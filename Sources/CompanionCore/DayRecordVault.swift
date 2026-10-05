#if os(macOS)
import Foundation
import Combine

/// The selected vault is the source of truth. No independent journal is maintained by the Mac.
@MainActor public final class DayRecordVault: ObservableObject {
    @Published public private(set) var directory: URL?
    @Published public private(set) var error: String?
    private let configuration: URL
    private var access: URL?
    private struct Location: Codable { let path: String; let bookmark: Data }
    private struct Metadata: Codable {
        let id: String; let kind: DayRecordEntry.Kind; let date: Date; let end: Date; let sources: [String]
        init(_ entry: DayRecordEntry) { id = entry.id; kind = entry.kind; date = entry.date; end = entry.end; sources = entry.sources }
        func entry(_ text: String) -> DayRecordEntry { DayRecordEntry(id: id, kind: kind, date: date, end: end, text: text, sources: sources) }
    }
    private static let marker = ".24r-vault.json"
    private static let folders = ["Transcripts", "Hourly", "Reports", "Tasks"]
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public init(configuration: URL) {
        self.configuration = configuration
        guard FileManager.default.fileExists(atPath: configuration.path) else { return }
        do {
            let location = try JSONDecoder().decode(Location.self, from: Data(contentsOf: configuration))
            var stale = false
            let url = try URL(resolvingBookmarkData: location.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { access = url }
            directory = url
            if stale { try saveLocation(url) }
        } catch { self.error = "资料库位置无法恢复，请重新选择文件夹：\(error.localizedDescription)" }
    }
    deinit { access?.stopAccessingSecurityScopedResource() }
    public var configured: Bool { directory != nil || FileManager.default.fileExists(atPath: configuration.path) }
    private func root() throws -> URL {
        guard let directory else { throw CompanionError.server(error ?? "资料库未连接。") }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.marker).path) else { throw CompanionError.server("资料库不可用，请检查文件夹或磁盘连接；不会改写到其他目录。") }
        return directory
    }
    public func select(parent: URL, library: DayRecordLibrary) throws {
        let selected = parent.standardizedFileURL.resolvingSymlinksInPath()
        let root = FileManager.default.fileExists(atPath: selected.appendingPathComponent(Self.marker).path) ? selected : selected.appendingPathComponent("24R", isDirectory: true)
        let granted = parent.startAccessingSecurityScopedResource(); defer { if granted { parent.stopAccessingSecurityScopedResource() } }
        guard root != library.directory.standardizedFileURL.resolvingSymlinksInPath() else { throw CompanionError.server("请选择其他文件夹，不能覆盖旧版内部目录。") }
        let markerFile = root.appendingPathComponent(Self.marker)
        let exists = FileManager.default.fileExists(atPath: markerFile.path)
        let state = exists ? try JSONSerialization.jsonObject(with: Data(contentsOf: markerFile)) as? [String: Any] : nil
        let importing = state?["importing"] as? String
        if !exists || importing != nil {
            // New vaults receive existing data. Opening another existing vault never merges two libraries.
            let origin = directory?.standardizedFileURL.path ?? library.directory.standardizedFileURL.path
            guard importing == nil || importing == origin else { throw CompanionError.server("该资料库上次迁入未完成，请在原资料库打开时重新选择此位置。") }
            if configured { _ = try self.root() }
            let snapshot = try library.days().map { ($0, try library.entries(day: $0)) }
            if !exists { try Self.prepare(root, importing: origin) }
            for (day, records) in snapshot { try Self.write(records, day: day, root: root, library: library) }
            try DayRecordLibrary.write(Data("{\"version\":2}".utf8), to: markerFile)
        } else { try migrate(root, library: library) }
        try saveLocation(root)
        access?.stopAccessingSecurityScopedResource(); access = nil
        if root.startAccessingSecurityScopedResource() { access = root }
        directory = root; error = nil; library.invalidate()
    }
    public func synchronize(_ library: DayRecordLibrary) {
        guard configured else { return }
        do { let root = try root(); try migrate(root, library: library); library.invalidate(); error = nil }
        catch { self.error = "资料库读取失败：\(error.localizedDescription)" }
    }
    private func saveLocation(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try DayRecordLibrary.write(JSONEncoder().encode(Location(path: url.path, bookmark: bookmark)), to: configuration)
    }
    public func days() -> [String] {
        do { return try Self.days(root()) }
        catch { self.error = error.localizedDescription; return [] }
    }
    private static func days(_ root: URL) throws -> [String] {
        var days = Set<String>()
        for folder in folders {
            let directory = try path(folder, root: root)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let day = file.deletingPathExtension().lastPathComponent
                guard DayRecordLibrary.validDay(day), file.pathExtension == (folder == "Transcripts" ? "json" : "md") else { continue }
                // Fixed directories and exact day filenames only. No recursive scan of unrelated notes.
                _ = try path(folder + "/" + file.lastPathComponent, root: root)
                days.insert(day)
            }
        }
        return days.sorted(by: >)
    }
    public func version(day: String) -> String {
        guard let root = try? root() else { return "unavailable" }
        return Self.folders.map { folder in
            let file = root.appendingPathComponent("\(folder)/\(day)." + (folder == "Transcripts" ? "json" : "md"))
            let a = try? FileManager.default.attributesOfItem(atPath: file.path)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(a?[.size] as? Int ?? 0)"
        }.joined(separator: ":")
    }
    public func entries(day: String) throws -> [DayRecordEntry] {
        do { let records = try Self.read(day: day, root: root()); error = nil; return records }
        catch { self.error = error.localizedDescription; throw error }
    }
    public func merge(_ incoming: [DayRecordEntry], day: String, library: DayRecordLibrary) throws {
        let root = try root(), existing = try Self.read(day: day, root: root)
        var records = existing
        for entry in incoming {
            if let index = records.firstIndex(where: { $0.id == entry.id }) { records[index] = entry } else { records.append(entry) }
        }
        // Only write the collections involved in this mutation. Other externally edited files stay intact.
        let kinds = Set(incoming.map(\.kind))
        try Self.write(records, day: day, root: root, library: library, kinds: kinds)
        error = nil
    }
    private static func path(_ relative: String, root: URL) throws -> URL {
        guard !relative.contains(".."), !relative.hasPrefix("/") else { throw CompanionError.invalidFrame }
        var component = root
        for part in relative.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? FileManager.default.attributesOfItem(atPath: component.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw CompanionError.server("24R 文件路径包含符号链接：\(relative)") }
        }
        return component
    }
    private static func prepare(_ root: URL, importing: String) throws {
        // Other folders are allowed; do not adopt existing date files without a 24R marker.
        guard try days(root).isEmpty else { throw CompanionError.server("该 24R 文件夹已有同名日期文件，但没有资料库标记。请选择其他位置，原文件未修改。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DayRecordLibrary.write(JSONSerialization.data(withJSONObject: ["version": 2, "importing": importing]), to: root.appendingPathComponent(marker))
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path) { try DayRecordLibrary.write(Data(readme.utf8), to: root.appendingPathComponent("README.md")) }
    }
    private static func contents(_ relative: String, root: URL) throws -> String? {
        let url = try path(relative, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 4_000_000 else { throw CompanionError.server("24R 文档过大：\(relative)") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    private static func body(_ text: String, day: String, type: String) throws -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { throw CompanionError.server("24R 文档缺少格式属性：\(day) \(type)") }
        let header = String(text[..<end.lowerBound])
        guard header.contains("generator: 24R"), header.contains("type: " + type), header.contains("date: " + day) else { throw CompanionError.server("文档不是对应日期的 24R \(type)：\(day)") }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func metadataLine(_ entry: DayRecordEntry) throws -> String {
        let encoder = Self.encoder; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "<!-- 24r: " + String(decoding: try encoder.encode(Metadata(entry)), as: UTF8.self) + " -->"
    }
    private static func unpack(_ content: String, fallback: DayRecordEntry) throws -> DayRecordEntry {
        var lines = content.components(separatedBy: .newlines)
        var entry = fallback
        if let index = lines.firstIndex(where: { $0.hasPrefix("<!-- 24r: ") && $0.hasSuffix(" -->") }) {
            let line = lines.remove(at: index)
            let metadata = try decoder.decode(Metadata.self, from: Data(line.dropFirst(10).dropLast(4).utf8))
            guard metadata.id == fallback.id, metadata.kind == fallback.kind else { throw CompanionError.server("24R 文档标识不匹配。") }
            entry = metadata.entry("")
        }
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        entry.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalize(entry)
    }
    private static func read(day: String, root: URL) throws -> [DayRecordEntry] {
        guard DayRecordLibrary.validDay(day), let start = dayDate(day) else { throw CompanionError.invalidFrame }
        var records: [DayRecordEntry] = []
        let rawFile = try path("Transcripts/\(day).json", root: root)
        if FileManager.default.fileExists(atPath: rawFile.path) {
            records = try decoder.decode([DayRecordEntry].self, from: Data(contentsOf: rawFile))
            guard records.allSatisfy({ ($0.kind == .transcript || $0.kind == .gap) && DayRecordLibrary.day($0.date) == day && $0.text.utf8.count <= 160_000 && $0.id.count <= 200 }), Set(records.map(\.id)).count == records.count else { throw CompanionError.server("转写 JSON 的日期、类型或 ID 无效：\(day)") }
        }
        if let text = try contents("Hourly/\(day).md", root: root) {
            let content = try body(text, day: day, type: "hourly")
            let chunks = content.components(separatedBy: "<!-- 24r: ")
            for chunk in chunks.dropFirst() {
                guard let end = chunk.range(of: " -->") else { throw CompanionError.server("小时摘要格式不完整。") }
                let meta = try decoder.decode(Metadata.self, from: Data(chunk[..<end.lowerBound].utf8))
                guard meta.kind == .hour, DayRecordLibrary.day(meta.date) == day else { throw CompanionError.invalidFrame }
                var content = String(chunk[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.hasPrefix("## "), let newline = content.firstIndex(of: "\n") { content = String(content[content.index(after: newline)...]) }
                content = content.components(separatedBy: .newlines).filter { !$0.hasPrefix("^hour-") && $0 != "---" }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                records.append(normalize(meta.entry(content)))
            }
            if chunks.count == 1, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CompanionError.server("小时摘要缺少 24R 标识，请保留每小时的元数据注释。") }
        }
        let taskDocument = try contents("Tasks/\(day).md", root: root)
        let tasks = try taskDocument.map { tasksIn(try body($0, day: day, type: "tasks")) } ?? []
        var report: DayRecordEntry?
        if let text = try contents("Reports/\(day).md", root: root) {
            let content = try body(text, day: day, type: "daily-report")
            let fallback = DayRecordEntry(id: "report-" + day, kind: .report, date: start, end: start, text: "")
            var parsed = try unpack(content, fallback: fallback)
            let modified = try path("Reports/\(day).md", root: root).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified { parsed.end = max(parsed.end, modified) }
            parsed.text = parsed.text.replacingOccurrences(of: "\n\n## 待办\n\n[查看与编辑当天待办](../Tasks/\(day).md)", with: "")
            report = parsed
        } else if !tasks.isEmpty { report = DayRecordEntry(id: "report-" + day, kind: .report, date: start, end: start, text: "") }
        if var report {
            // Task text/state has one owner: Tasks/day.md. Reports only link to it.
            report.text = withoutTasks(report.text)
            if !tasks.isEmpty { report.text += "\n\n## 待办\n" + tasks.map { ($0.done ? "- [x] " : "- [ ] ") + $0.text }.joined(separator: "\n") }
            report = normalize(report); records.append(report)
            for task in tasks {
                let normalized = normalize(DayRecordEntry(kind: .task, date: start, text: task.text)).text
                var entry = DayRecordEntry(id: DayRecordEntry.taskID(report: report.id, text: normalized), kind: .task, date: report.date, text: normalized, sources: [report.id]); entry.completed = task.done; records.append(entry)
            }
        }
        return records.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    private struct Todo { let text: String; let done: Bool }
    private static func tasksIn(_ text: String) -> [Todo] {
        var code = false, seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { code.toggle(); return nil }
            guard !code, let task = DayRecordEntry.taskText(line), seen.insert(task).inserted else { return nil }
            return Todo(text: task, done: line.hasPrefix("- [x]") || line.hasPrefix("- [X]"))
        }
    }
    private static func withoutTasks(_ text: String) -> String {
        var code = false
        return text.components(separatedBy: .newlines).filter { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { code.toggle() }
            return code || (DayRecordEntry.taskText(line) == nil && line != "## 待办")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func write(_ records: [DayRecordEntry], day: String, root: URL, library: DayRecordLibrary, kinds: Set<DayRecordEntry.Kind>? = nil) throws {
        func writing(_ values: [DayRecordEntry.Kind]) -> Bool { kinds == nil || values.contains { kinds!.contains($0) } }
        func save(_ text: String, _ relative: String) throws { try DayRecordLibrary.write(Data(text.utf8), to: path(relative, root: root)) }
        if writing([.transcript, .gap]) {
            let raw = records.filter { $0.kind == .transcript || $0.kind == .gap }
            try DayRecordLibrary.write(encoder.encode(raw), to: path("Transcripts/\(day).json", root: root))
            let body = raw.map { "## \(time($0.date)) — \(time($0.end))\n\n" + $0.text + "\n\n^" + anchor($0.id) }.joined(separator: "\n\n")
            try save(frontmatter(day, type: "transcript") + "# \(day) 识别原文\n\n" + body + "\n", "Transcripts/\(day).md")
        }
        if writing([.hour]) {
            let hours = records.filter { $0.kind == .hour }
            if !hours.isEmpty {
                let body = try hours.map { try metadataLine($0) + "\n## \(time($0.date))\n\n" + readable($0, records: records, library: library) + "\n\n^" + anchor($0.id) }.joined(separator: "\n\n")
                try save(frontmatter(day, type: "hourly") + "# \(day) 小时摘要\n\n" + body + "\n", "Hourly/\(day).md")
            }
        }
        if let report = records.first(where: { $0.kind == .report }), writing([.report, .task]) {
            var tasks = tasksIn(report.text)
            // Keep user/Agent tasks when a generated report supplies a new list.
            if let current = try contents("Tasks/\(day).md", root: root) {
                for task in tasksIn(try body(current, day: day, type: "tasks")) {
                    let normalized = normalize(DayRecordEntry(kind: .task, date: report.date, text: task.text)).text
                    if !tasks.contains(where: { $0.text == normalized }) { tasks.append(Todo(text: normalized, done: task.done)) }
                }
            }
            let lines = tasks.map { task -> String in
                let done = records.first { $0.id == DayRecordEntry.taskID(report: report.id, text: task.text) }?.completed ?? task.done
                let text = readable(DayRecordEntry(kind: .task, date: report.date, text: task.text, sources: report.sources), records: records, library: library)
                return (done ? "- [x] " : "- [ ] ") + text
            }
            var taskText = frontmatter(day, type: "tasks") + "# \(day) 待办\n\n" + lines.joined(separator: "\n") + "\n"
            if let current = try contents("Tasks/\(day).md", root: root) {
                var pending = Dictionary(uniqueKeysWithValues: zip(tasks.map(\.text), lines))
                var code = false
                taskText = current.components(separatedBy: .newlines).map { line in
                    if line.hasPrefix("```") || line.hasPrefix("~~~") { code.toggle() }
                    guard !code, let text = DayRecordEntry.taskText(line) else { return line }
                    let normalized = normalize(DayRecordEntry(kind: .task, date: report.date, text: text)).text
                    return pending.removeValue(forKey: normalized) ?? line
                }.joined(separator: "\n")
                let additions = tasks.compactMap { pending[$0.text] }
                if !additions.isEmpty { taskText += "\n" + additions.joined(separator: "\n") + "\n" }
            }
            try save(taskText, "Tasks/\(day).md")
            if writing([.report]) {
                var body = report; body.text = withoutTasks(report.text)
                try save(frontmatter(day, type: "daily-report") + "# \(day) 一日总结\n" + metadataLine(report) + "\n\n" + readable(body, records: records, library: library) + "\n\n## 待办\n\n[查看与编辑当天待办](../Tasks/\(day).md)\n", "Reports/\(day).md")
            }
        }
    }
    private static func frontmatter(_ day: String, type: String) -> String { "---\ndate: \(day)\ntype: \(type)\ngenerator: 24R\nschema_version: 2\n---\n\n" }
    private static func anchor(_ id: String) -> String { id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    private static func dayDate(_ day: String) -> Date? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: day) }
    private static func time(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date) }
    private static func normalize(_ entry: DayRecordEntry) -> DayRecordEntry {
        var entry = entry
        let regex = try! NSRegularExpression(pattern: #"\[\[(?:\.\./)?(Transcripts|Hourly|Reports)/(\d{4}-\d{2}-\d{2})(?:#\^([A-Za-z0-9-]+))?\|[^\]]*\]\]"#)
        let ns = entry.text as NSString
        for match in regex.matches(in: entry.text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = match.range(at: 3).location == NSNotFound ? "report-" + ns.substring(with: match.range(at: 2)) : ns.substring(with: match.range(at: 3))
            if !entry.sources.contains(id) { entry.sources.append(id) }
            if let range = Range(match.range, in: entry.text) { entry.text.replaceSubrange(range, with: "[\(id)]") }
        }
        return entry
    }
    private static func readable(_ entry: DayRecordEntry, records: [DayRecordEntry], library: DayRecordLibrary) -> String {
        var body = entry.text
        for id in entry.sources {
            var source = records.first { $0.id == id }
            if source == nil, let range = id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) { source = (try? library.entries(day: String(id[range])))?.first { $0.id == id } }
            guard let source else { continue }
            let folder: String
            switch source.kind { case .transcript, .gap: folder = "Transcripts"; case .hour: folder = "Hourly"; case .report: folder = "Reports"; case .task: continue }
            let day = DayRecordLibrary.day(source.date), suffix = source.kind == .report ? "" : "#^" + anchor(source.id)
            body = body.replacingOccurrences(of: "[\(id)]", with: "[[../\(folder)/\(day)\(suffix)|\(source.kind == .report ? day + " 日报" : time(source.date))]]")
        }
        return body
    }
    private func migrate(_ root: URL, library: DayRecordLibrary) throws {
        let data = try Data(contentsOf: root.appendingPathComponent(Self.marker))
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let version = state?["version"] as? Int
        guard state?["importing"] == nil else { throw CompanionError.server("资料库迁入未完成，请回到原资料库重试。") }
        guard version == 1 || version == 2 else { throw CompanionError.server("资料库格式版本暂不支持。") }
        guard version == 1 else { return }
        // One-time v1 export migration. The external report is authoritative, including edits.
        for day in try Self.days(root) {
            // A previously completed day is valid even if migration stopped before the final marker update.
            if let report = try Self.contents("Reports/\(day).md", root: root), report.contains("schema_version: 2") {
                _ = try Self.read(day: day, root: root); continue
            }
            if let hours = try Self.contents("Hourly/\(day).md", root: root), hours.contains("schema_version: 2") {
                _ = try Self.read(day: day, root: root); continue
            }
            var records = try library.legacyEntries(day: day)
            if let raw = try Self.contents("Transcripts/\(day).json", root: root) {
                records.removeAll { $0.kind == .transcript || $0.kind == .gap }
                records += try Self.decoder.decode([DayRecordEntry].self, from: Data(raw.utf8))
            }
            if let report = try Self.contents("Reports/\(day).md", root: root), let date = Self.dayDate(day) {
                let fallback = records.first { $0.kind == .report } ?? DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "")
                let content = try Self.body(report, day: day, type: "daily-report")
                let parsed = try Self.unpack(content, fallback: fallback)
                records.removeAll { $0.kind == .report || $0.kind == .task }; records.append(parsed)
            }
            // Preserve the exact old hourly file before adding entry metadata.
            if let hours = try Self.contents("Hourly/\(day).md", root: root) {
                let archive = try Self.path("MigrationBackup/Hourly-\(day).md", root: root)
                if !FileManager.default.fileExists(atPath: archive.path) { try DayRecordLibrary.write(Data(hours.utf8), to: archive) }
                let chunks = (try Self.body(hours, day: day, type: "hourly")).components(separatedBy: "\n\n---\n\n")
                var oldHours = records.filter { $0.kind == .hour }.sorted { $0.date < $1.date }
                if oldHours.isEmpty {
                    for chunk in chunks {
                        if let line = chunk.components(separatedBy: .newlines).first(where: { $0.hasPrefix("^hour-") }),
                           let seconds = Double(line.dropFirst(6)) {
                            oldHours.append(DayRecordEntry(id: String(line.dropFirst()), kind: .hour, date: Date(timeIntervalSince1970: seconds), text: ""))
                        }
                    }
                    records += oldHours
                }
                for (index, old) in oldHours.enumerated() where index < chunks.count {
                    var lines = chunks[index].components(separatedBy: .newlines)
                    if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
                    while lines.first?.isEmpty == true { lines.removeFirst() }
                    if lines.first?.hasPrefix("## ") == true { lines.removeFirst() }
                    var hour = old; hour.text = lines.filter { !$0.hasPrefix("^hour-") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let position = records.firstIndex(where: { $0.id == old.id }) { records[position] = Self.normalize(hour) }
                }
            }
            try Self.write(records, day: day, root: root, library: library)
        }
        try DayRecordLibrary.write(Data("{\"version\":2}".utf8), to: root.appendingPathComponent(Self.marker))
        let guide = root.appendingPathComponent("24R-Guide.md")
        if !FileManager.default.fileExists(atPath: guide.path) { try DayRecordLibrary.write(Data(Self.readme.utf8), to: guide) }
    }
    private static let readme = """
    # 24R 资料库

    此目录是 Mac 24R 的唯一数据来源，可用 Obsidian 或 Agent 编辑。App 只读取以下目录内严格匹配 YYYY-MM-DD 的文件，不扫描其他目录。

    - Transcripts/YYYY-MM-DD.json：原始转写数组（id/kind/date/end/text/sources），日期为 ISO 8601 UTC；文件名按 Mac 当地日期分组。Markdown 为阅读用派生文件，修改原文请编辑 JSON。
    - Hourly/YYYY-MM-DD.md：小时摘要，保留每小时的 24r 元数据注释。
    - Reports/YYYY-MM-DD.md：日报正文，引用可以跳到原文。
    - Tasks/YYYY-MM-DD.md：待办唯一来源，标准 - [ ] / - [x]；App 和文件中的勾选直接更新这里。日报链接到本文件。

    Markdown 保留 date、type（hourly/daily-report/tasks）、generator: 24R、schema_version: 2 属性。Agent 新建日报或待办时遵守日期文件名及属性格式即可。内部元数据注释保留记录 ID、时间、引用，没有另一份正文。其他笔记和文件夹均可自由使用，不会被 App 扫描或修改。

    删除或修改文件会反映到 App；无效文件会显示读取错误，不回退到另一套旧数据。打开其他已有资料库不会合并内容；新建资料库才复制当前记录。旧目录只保留为迁移备份，不再更新。音频和密钥不存放于此。
    """
}
#endif
