import SwiftUI
import CompanionCore

private enum DayRecordPage: String, CaseIterable {
    case today = "今天", report = "日报", history = "历史", settings = "设置"
    var symbol: String { switch self { case .today: "circle.lefthalf.filled"; case .report: "doc.text"; case .history: "clock.arrow.circlepath"; case .settings: "slider.horizontal.3" } }
}
private enum DayRecordPalette {
    static let ink = Color(red: 0.15, green: 0.18, blue: 0.15)
    static let muted = Color(red: 0.48, green: 0.53, blue: 0.46)
    static let accent = Color(red: 0.39, green: 0.47, blue: 0.33)
    static let paper = Color(red: 0.98, green: 0.977, blue: 0.957)
    static let panel = Color(red: 1, green: 0.996, blue: 0.984)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.86)
    static let wash = Color(red: 0.92, green: 0.94, blue: 0.89)
}

public struct DayRecordView: View {
    @ObservedObject var store: DayRecordStore
#if os(iOS)
    private var capture: DayRecordPhoneStore?
    public init(store: DayRecordStore, capture: DayRecordPhoneStore? = nil) { self.store = store; self.capture = capture }
#else
    public init(store: DayRecordStore) { self.store = store }
#endif
    @Environment(\.dismiss) private var dismiss
    @State private var page: DayRecordPage = .today
    @State private var transcripts = false
    @State private var detail: DayRecordEntry?
    @State private var citation: DayRecordPresentation.Citation?
    private var hours: [DayRecordEntry] { store.entries.filter { $0.kind == .hour }.reversed() }
    private var raw: [DayRecordEntry] { store.entries.filter { $0.kind == .transcript || $0.kind == .gap } }
    private var daily: DayRecordEntry? { store.entries.first { $0.kind == .report } }
    private var taskCount: Int { daily?.text.components(separatedBy: .newlines).compactMap(DayRecordEntry.taskText).count ?? 0 }
    private var reportTime: String { String(format: "%02d:%02d", store.settings.reportHour, store.settings.reportMinute) }
    public var body: some View {
        HStack(spacing: 0) {
#if os(macOS)
            sidebar.frame(width: 172)
#endif
            VStack(spacing: 0) {
                HStack {
#if os(iOS)
                    Button { dismiss() } label: { Label("Companion", systemImage: "chevron.left").font(.system(size: 11)) }.foregroundStyle(DayRecordPalette.muted)
                    Spacer()
#endif
                    Text("24").font(.system(size: 22, weight: .semibold)) + Text("R").font(.system(size: 24, design: .serif))
                    Spacer()
                    Button { select(.settings) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("24R 设置")
                }.padding(.horizontal, 26).padding(.vertical, 16)
                Rectangle().fill(DayRecordPalette.line).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if transcripts { transcriptPage }
                            else if let detail { detailPage(detail) }
                            else {
                                switch page {
                                case .today: todayPage
                                case .report: reportPage
                                case .history: historyPage
                                case .settings: DayRecordSettingsPanel(store: store)
                                }
                            }
                            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
#if os(macOS)
                            DayRecordVaultStatus(vault: store.library.vault)
#endif
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text(store.online ? "文字连接可用 · 已完成的记录保存在本机" : "Mac 未连接 · 可查看已有文字")
                            }.font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted).frame(maxWidth: .infinity).padding(.top, 8)
                        }.padding(.horizontal, 26).padding(.vertical, 30).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                    }
#if os(macOS)
                    insight.frame(width: 225).frame(maxHeight: .infinity, alignment: .top).background(DayRecordPalette.panel).overlay(alignment: .leading) { Rectangle().fill(DayRecordPalette.line).frame(width: 1) }
#endif
                }
#if os(iOS)
                if let capture { DayRecordRecordingBar(capture: capture) }
                HStack(spacing: 0) {
                    ForEach(DayRecordPage.allCases, id: \.self) { item in
                        Button { select(item) } label: { VStack(spacing: 5) { Image(systemName: item.symbol).font(.system(size: 19)); Text(item.rawValue).font(.system(size: 10)) }.frame(maxWidth: .infinity).padding(.vertical, 12).foregroundStyle(page == item && !transcripts ? DayRecordPalette.accent : DayRecordPalette.muted) }
                    }
                }.overlay(alignment: .top) { Rectangle().fill(DayRecordPalette.line).frame(height: 1) }
#endif
            }
        }.buttonStyle(.plain).foregroundStyle(DayRecordPalette.ink).background(DayRecordPalette.paper).tint(DayRecordPalette.accent)
        .environment(\.colorScheme, .light)
        .navigationTitle("24R")
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
        .sheet(item: $citation) { reference in citationSheet(reference) }
        .onChange(of: store.date) { _, _ in store.reload(); Task { await store.refresh() } }
        .task { await store.refresh(); while !Task.isCancelled { do { try await Task.sleep(for: .seconds(5)) } catch { break }; await store.refresh() } }
    }
    private func select(_ page: DayRecordPage) { self.page = page; transcripts = false; detail = nil }
    private func heading(_ eyebrow: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 10)).tracking(1.7).foregroundStyle(DayRecordPalette.muted)
            Text(title).font(.system(size: 31, weight: .regular, design: .serif)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted).lineSpacing(5)
        }
    }
    private var todayPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading(store.date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased(), "今天，慢慢记下来。", store.date.formatted(date: .complete, time: .omitted))
#if os(iOS)
            if let capture { DayRecordCapturePanel(capture: capture) }
#else
            Label("在 iPhone 开始记录，停顿后传回文字", systemImage: "iphone.radiowaves.left.and.right").font(.system(size: 12)).padding(18).frame(maxWidth: .infinity, alignment: .leading).dayRecordPanel()
#endif
            HStack {
                metric("\(raw.count)", "已识别片段")
                metric("\(hours.count)", "小时已整理")
                metric("\(taskCount)", "待办已提取")
            }
            Button { transcripts = true } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.alignleft").padding(.top, 3)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("查看已识别文本").font(.system(size: 14, weight: .medium))
                        Text(raw.last?.text ?? "片段上传后，识别结果会出现在这里。无需等到整点。").font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0); Image(systemName: "arrow.up.right")
                }.padding(18).dayRecordPanel()
            }
            Button { select(.report) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("YOUR DAILY BRIEF").font(.system(size: 10)).tracking(1.5); Spacer(); Image(systemName: "arrow.up.right") }
                    Text(daily == nil ? "今晚 \(reportTime)，一天会更清楚。" : "今天的日报已就绪").font(.system(size: 17, design: .serif))
                    Text("一日总结 · 待办 · 对策").font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DayRecordPalette.wash, in: RoundedRectangle(cornerRadius: 15))
            }
            HStack { sectionTitle("每小时整理"); Spacer(); Button("整理一次 ↗") { Task { await store.perform("organize") } }.font(.system(size: 11)).disabled(store.busy || !store.online || raw.isEmpty) }
            LazyVStack(alignment: .leading, spacing: 0) {
                if Calendar.current.isDateInToday(store.date) {
                    timelineRow(time: "这一小时 · 待整理", title: "这一小时还在发生", description: "语音按片段上传；已识别的文字会在整点后整理。", pending: true)
                }
                ForEach(hours) { entry in
                    Button { detail = entry } label: { timelineRow(time: entry.date.formatted(date: .omitted, time: .shortened) + " · 已整理", title: summaryTitle(entry), description: preview(entry.text), pending: false) }
                }
                if hours.isEmpty { Text("小时整理完成后，会沿着时间线留在这里。").font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted).padding(.leading, 23) }
            }
        }
    }
    private func metric(_ number: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(number).font(.system(size: 27, design: .serif)); Text(label).font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func timelineRow(time: String, title: String, description: String, pending: Bool) -> some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(spacing: 0) { Circle().strokeBorder(pending ? DayRecordPalette.accent : DayRecordPalette.line, lineWidth: 2).frame(width: 9, height: 9); Rectangle().fill(DayRecordPalette.line).frame(width: 1) }.frame(width: 9)
            VStack(alignment: .leading, spacing: 8) {
                Text(time).font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Text(description).font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted).lineSpacing(5).lineLimit(3)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 27)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var transcriptPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button("‹ 返回今天") { select(.today) }.font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted)
            heading("TRANSCRIPT / AS IT HAPPENS", "已经说过的话。", "停顿约 3 秒后上传，持续说话最长 60 秒一段。文字返回后立即可看，每小时再整理。")
            HStack { sectionTitle("已识别 · \(raw.count) 段"); Spacer(); ShareLink(item: raw.map { $0.date.formatted(date: .omitted, time: .shortened) + "\n" + $0.text }.joined(separator: "\n\n")) { Image(systemName: "square.and.arrow.up") }.disabled(raw.isEmpty) }
            if raw.isEmpty { note("尚无识别结果。正在说话时先在手机暂存，片段发送并完成转写后会显示在这里。") }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(raw.reversed()) { entry in
                    DayRecordTranscriptRow(entry: entry)
                }
            }
        }
    }
    private var reportPage: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading("YOUR DAILY BRIEF", "把今天，变成下一步。", daily == nil ? "晚间 \(reportTime) 生成日报，文字与报告双端保存。" : "\(store.date.formatted(date: .abbreviated, time: .omitted)) · 一日总结")
            Text(analysisLabel).font(.system(size: 11)).foregroundStyle(DayRecordPalette.accent).padding(.horizontal, 12).padding(.vertical, 7).background(DayRecordPalette.wash, in: Capsule())
            if let daily { markdown(daily); sources(daily); ShareLink(item: store.exportReport(daily)) { Label("导出日报", systemImage: "square.and.arrow.up").font(.system(size: 12)) } }
            else { note("今天的记录会整理为一日总结、待办和行动建议。也可以随时手动生成。") }
            Button { Task { await store.perform("report") } } label: { Label(store.busy ? "正在整理…" : daily == nil ? "现在生成日报" : "更新一日总结", systemImage: "doc.text").frame(maxWidth: .infinity).padding(15).background(DayRecordPalette.accent, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.white) }.disabled(store.busy || !store.online || raw.isEmpty)
            Text(store.status).font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted)
        }
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("YOUR DAYS", "每一天，都有迹可循。", "日报与小时记录 · 两端均可查看")
            DatePicker("查看日期", selection: $store.date, displayedComponents: .date).font(.system(size: 12))
            ForEach(store.days, id: \.self) { day in
                Button {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                    if let date = f.date(from: day) { store.date = date; select(.today) }
                } label: { HStack { VStack(alignment: .leading, spacing: 10) { Text(day).font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted); Text("查看这一天的记录").font(.system(size: 15, design: .serif)) }; Spacer(); Image(systemName: "arrow.up.right") }.padding(21).dayRecordPanel() }
            }
#if os(iOS)
            if let capture { DayRecordClipsView(capture: capture) }
#endif
        }
    }
    private func detailPage(_ entry: DayRecordEntry) -> some View {
        VStack(alignment: .leading, spacing: 22) { Button("‹ 返回时间线") { detail = nil }.font(.system(size: 12)); heading("HOURLY NOTE", "这一小时的记录", entry.date.formatted(date: .abbreviated, time: .shortened)); markdown(entry); sources(entry) }
    }
    private func sectionTitle(_ text: String) -> some View { Text(text).font(.system(size: 13, weight: .medium)) }
    private func summaryTitle(_ entry: DayRecordEntry) -> String { DayRecordPresentation.title(entry) }
    private func preview(_ text: String) -> String {
        let entry = DayRecordEntry(kind: .hour, date: store.date, text: text)
        let display = DayRecordPresentation(entry: entry, resolve: store.source).display(text, links: false)
        return DayRecordPresentation.plain(display.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: " "))
    }
    private func markdown(_ entry: DayRecordEntry) -> some View {
        let presentation = DayRecordPresentation(entry: entry, resolve: store.source)
        return DayRecordAnalysisContent(entry: entry, presentation: presentation,
            taskCompleted: entry.kind == .report ? { store.taskCompleted(report: entry, text: $0) } : nil,
            toggleTask: entry.kind == .report ? { text in Task { await store.completeTask(entry, text: text, completed: !store.taskCompleted(report: entry, text: text)) } } : nil,
            tasksDisabled: store.busy || !store.online)
            .environment(\.openURL, OpenURLAction { url in
                if let reference = presentation.citation(url: url) { citation = reference; return .handled }
                return .systemAction
            })
    }
    private func sources(_ entry: DayRecordEntry) -> some View {
        let presentation = DayRecordPresentation(entry: entry, resolve: store.source)
        return DisclosureGroup("查看来源 · \(presentation.citations.count) 条") {
            ForEach(presentation.citations) { reference in
                Button { citation = reference } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "quote.opening")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reference.label).font(.system(size: 12, weight: .medium))
                            if let source = reference.source {
                                Text(source.kind == .transcript || source.kind == .gap ? source.text : preview(source.text)).lineLimit(2).font(.system(size: 12))
                            }
                        }
                        Spacer(minLength: 0); Image(systemName: "chevron.right")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
            }
        }.font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted)
    }
    private func citationSheet(_ reference: DayRecordPresentation.Citation) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("引用原文").font(.headline); Spacer()
                Button("完成") { citation = nil }.padding(.vertical, 8)
            }
            Text(reference.source?.date.formatted(date: .complete, time: .shortened) ?? reference.label).font(.subheadline).foregroundStyle(DayRecordPalette.muted)
            ScrollView {
                if let source = reference.source {
                    if source.kind == .transcript || source.kind == .gap {
                        Text(source.text).font(.system(size: 16)).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } else {
                        MessageContentView(content: DayRecordPresentation(entry: source, resolve: store.source).display(source.text, links: false)).textSelection(.enabled)
                    }
                } else {
                    Text(reference.sourceID.hasPrefix("quenda:") ? "这条引用来自 Quenda 历史会话，原文尚未同步到 24R。" : "这条来源暂未同步到本机，连接 Mac 同步后可查看。").foregroundStyle(DayRecordPalette.muted)
                }
            }
        }.padding(24).frame(minWidth: 280, idealWidth: 520, minHeight: 280)
        .background(DayRecordPalette.paper).foregroundStyle(DayRecordPalette.ink)
#if os(iOS)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
#endif
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DayRecordPalette.muted).padding(18).frame(maxWidth: .infinity, alignment: .leading).dayRecordPanel() }
    private var analysisLabel: String { switch store.settings.analysis { case .ollama: "Ollama · 本地整理"; case .cloud: "云端 Provider · 文字整理"; case .quenda: "Quenda · " + store.settings.agent } }
#if os(macOS)
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Companion", systemImage: "circle.lefthalf.filled").font(.system(size: 15, weight: .medium)).padding(.bottom, 22)
            Text("24R").font(.system(size: 10)).tracking(2).foregroundStyle(DayRecordPalette.muted).padding(.leading, 10)
            ForEach(DayRecordPage.allCases, id: \.self) { item in
                Button { select(item) } label: { Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(page == item ? Color(red: 0.85, green: 0.89, blue: 0.81) : .clear, in: RoundedRectangle(cornerRadius: 9)) }
            }
            Button { transcripts = true; detail = nil } label: { Label("已识别文本", systemImage: "text.alignleft").font(.system(size: 12)).padding(12) }
            Spacer()
            Text("记录在手机，整理在电脑。\n连接由 Companion 管理。").font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted).lineSpacing(6)
        }.padding(16).frame(maxHeight: .infinity).background(DayRecordPalette.wash)
    }
    private var insight: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("DEVICE & DAILY FLOW").font(.system(size: 9)).tracking(1.3).foregroundStyle(DayRecordPalette.muted)
            Text("记录在手机，\n整理在电脑。").font(.system(size: 17, design: .serif)).lineSpacing(6)
            Text("语音片段 · 最长 60 秒\n停顿约 3 秒后发送\n音频转写后自动清理").font(.system(size: 12)).lineSpacing(10).foregroundStyle(DayRecordPalette.muted)
            Divider(); sectionTitle("今天的节奏")
            Text("每小时整理一次\n晚间日报 · \(reportTime)").font(.system(size: 12)).lineSpacing(10).foregroundStyle(DayRecordPalette.muted)
            Divider(); sectionTitle("智能整理")
            Text(analysisLabel).font(.system(size: 12)); Text(store.settings.historyEnabled ? "关联所选历史 · 附来源" : "仅分析当天文字").font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted)
            Divider(); Button("查看已识别文本 ↗") { transcripts = true; detail = nil }.font(.system(size: 12))
            Text(store.status).font(.system(size: 11)).lineSpacing(6).foregroundStyle(DayRecordPalette.muted)
        }.padding(24)
    }
#endif
}
struct DayRecordTranscriptRow: View {
    let entry: DayRecordEntry
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle().fill(entry.kind == .gap ? Color.orange : DayRecordPalette.accent.opacity(0.6)).frame(width: 6, height: 6).padding(.top, 5)
                Rectangle().fill(DayRecordPalette.line).frame(width: 1).padding(.top, 8)
            }.frame(width: 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(entry.date.formatted(.dateTime.hour().minute().second())).monospacedDigit()
                    if entry.end > entry.date { Text("— " + entry.end.formatted(.dateTime.hour().minute().second())).monospacedDigit() }
                    Spacer(minLength: 0)
                    if entry.kind == .gap { Text("中断 · 未校正").foregroundStyle(.orange) }
                }.font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted)
                Text(entry.text).font(.system(size: 16)).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.bottom, 28)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func dayRecordPanel() -> some View { background(DayRecordPalette.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DayRecordPalette.line, lineWidth: 1)) }
}

private struct DayRecordSettingsPanel: View {
    @ObservedObject var store: DayRecordStore
    @State private var draft = DayRecordSettings()
    @State private var apiKey = ""
    @State private var replaceKey = false
    private var reportDate: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: draft.reportHour, minute: draft.reportMinute, second: 0, of: Date()) ?? Date() }, set: { draft.reportHour = Calendar.current.component(.hour, from: $0); draft.reportMinute = Calendar.current.component(.minute, from: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) { Text("MAKE IT YOURS").font(.system(size: 10)).tracking(1.8).foregroundStyle(DayRecordPalette.muted); Text("按你的节奏。").font(.system(size: 31, design: .serif)); hint("模型与 Agent 在 Mac 运行 · 两端共用 24R 配置") }
            group("音频保留", badge: "默认不保存") {
                hint("待转写语音会暂存在手机，重连后补传，确认转写成功后删除；手动操作或命中短语后才长期保留声音。")
                Toggle("关键词触发", isOn: $draft.keywordsEnabled)
                if draft.keywordsEnabled { field("触发短语（一行一个）", text: $draft.keywords); hint("关键词需等片段转写后触发；手动保留立即生效。") }
                Picker("单次保留上限", selection: $draft.retentionMinutes) { ForEach([1,5,15], id: \.self) { Text("\($0) 分钟").tag($0) } }
                hint("片段仅存在 iPhone，在历史页播放、导出或删除。")
            }
            group("智能整理", badge: "ANALYSIS") {
                Picker("分析方式", selection: $draft.analysis) { Text("本地 Ollama").tag(DayRecordSettings.Analysis.ollama); Text("云端模型").tag(DayRecordSettings.Analysis.cloud); Text("Quenda Agent").tag(DayRecordSettings.Analysis.quenda) }.pickerStyle(.segmented)
                switch draft.analysis {
                case .ollama:
                    field("Ollama 服务地址", text: $draft.ollamaURL); hint("由配对的 Mac 访问此地址；127.0.0.1 指 Mac 本机。")
                    field("模型", text: $draft.ollamaModel)
                    Picker("模型驻留", selection: $draft.keepAlive) { Text("完成即卸载").tag("0"); Text("空闲 5 分钟卸载").tag("5m"); Text("空闲 30 分钟卸载").tag("30m"); Text("保持常驻").tag("-1") }
                case .cloud:
                    hint("自定义 Provider · OpenAI 兼容")
                    field("模型服务地址（包含 /v1）", text: $draft.cloudURL); field("模型 ID", text: $draft.cloudModel)
                    Toggle("更新 API Key", isOn: $replaceKey)
                    if replaceKey { SecureField("API Key（留空清除）", text: $apiKey).textFieldStyle(.roundedBorder) }
                    hint("凭据按服务地址存入 Mac 钥匙串；只发送文字与选定历史。")
                case .quenda:
                    field("24R 的 Quenda Agent", text: $draft.agent); field("项目 / Workspace ID", text: $draft.workspace)
                    field("Provider（留空跟随 Agent）", text: $draft.provider); field("Agent 使用的模型", text: $draft.agentModel)
                    hint("使用 Companion 的 Gateway。模型覆盖仅作用于整理会话，不修改其他 Agent。")
                }
                Button("保存并测试连接 ↗") { Task { if await store.save(draft, key: replaceKey ? apiKey : nil) { apiKey = ""; replaceKey = false; await store.perform("test") } } }.foregroundStyle(DayRecordPalette.accent).disabled(store.busy || !store.online)
                Divider()
                Toggle("关联历史", isOn: $draft.historyEnabled)
                if draft.historyEnabled { Stepper("回看最近 \(draft.historyDays) 天", value: $draft.historyDays, in: 1...90); hint("关联 24R 日报及所选 Quenda 项目，保留日期和来源。") }
            }
            group("整理与保存", badge: "DAILY FLOW") {
                HStack { Text("音频上传"); Spacer(); Text("停顿后 · 最长 1 分钟").foregroundStyle(DayRecordPalette.muted) }
                hint("本机检测语音，连续约 3 秒无语音就发送。不说话时不发送；暂停时发送剩余片段。")
                Divider(); HStack { Text("文字整理"); Spacer(); Text("每 1 小时").foregroundStyle(DayRecordPalette.muted) }
                Toggle("自动整理", isOn: $draft.automatic)
                DatePicker("晚间日报", selection: reportDate, displayedComponents: .hourAndMinute)
                HStack { Text("文字与日报"); Spacer(); Text("双端保存").foregroundStyle(DayRecordPalette.accent) }
            }
#if os(macOS)
            DayRecordVaultPanel(library: store.library)
#endif
            Button { Task { if await store.save(draft, key: replaceKey ? apiKey : nil) { apiKey = ""; replaceKey = false } } } label: { Text(store.busy ? "正在处理…" : "保存设置").frame(maxWidth: .infinity).padding(15).background(DayRecordPalette.accent, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.white) }.disabled(store.busy || !store.online)
            hint(store.status)
        }.font(.system(size: 12)).onAppear { draft = store.settings }
    }
    private func field(_ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).foregroundStyle(DayRecordPalette.muted); TextField(title, text: text).textFieldStyle(.roundedBorder).autocorrectionDisabled() } }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
    private func group<Content: View>(_ title: String, badge: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) { HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text(badge).font(.system(size: 10)).foregroundStyle(DayRecordPalette.accent) }; content() }.padding(.top, 20).overlay(alignment: .top) { Rectangle().fill(DayRecordPalette.line).frame(height: 1) }
    }
}
#if os(iOS)
/// Included in 24R's own footer; the host shows it only outside 24R.
public struct DayRecordRecordingBar: View {
    @ObservedObject var capture: DayRecordPhoneStore
    public init(capture: DayRecordPhoneStore) { self.capture = capture }
    public var body: some View {
        if capture.running || capture.starting {
            HStack(spacing: 10) {
                Image(systemName: capture.retaining ? "record.circle.fill" : "waveform").foregroundStyle(capture.retaining ? .red : DayRecordPalette.accent)
                Text(capture.starting ? "24R · 准备记录…" : capture.interrupted ? "24R · 等待恢复收音" : capture.retaining ? "24R · 正在保留音频" : "24R · 记录中，转写后清理音频")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                if capture.retaining { Button("停止保留") { capture.endRetention() }.font(.system(size: 12)).padding(.vertical, 12) }
                Button { capture.pause() } label: { Image(systemName: "pause.fill").frame(width: 44, height: 44) }.accessibilityLabel("暂停 24R 记录")
            }.padding(.leading, 22).padding(.trailing, 10)
            .foregroundStyle(DayRecordPalette.ink).background(DayRecordPalette.wash)
            .overlay(alignment: .top) { Rectangle().fill(DayRecordPalette.line).frame(height: 1) }
        }
    }
}

private struct DayRecordCapturePanel: View {
    @ObservedObject var capture: DayRecordPhoneStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(capture.interrupted ? Color.orange : capture.running ? DayRecordPalette.accent : DayRecordPalette.muted).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(capture.starting ? "正在准备语音检测…" : capture.interrupted ? "等待恢复记录" : capture.running ? (capture.speechDetected ? "检测到说话" : "正在监听，等待说话") : "记录已暂停").font(.system(size: 12, weight: .medium))
                    Text(capture.captureStatus).font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
                }
                Spacer(minLength: 0)
                Button { if capture.running || capture.starting { capture.pause() } else { capture.start() } } label: { Image(systemName: capture.running || capture.starting ? "pause.fill" : "play.fill").font(.system(size: 12)).frame(width: 34, height: 34).background(DayRecordPalette.paper, in: Circle()).overlay(Circle().strokeBorder(DayRecordPalette.line)) }.accessibilityLabel(capture.running ? "暂停记录" : "开始记录")
            }.padding(16).dayRecordPanel()
            VStack(alignment: .leading, spacing: 7) {
                Picker("收音设备", selection: Binding(get: { capture.preferredInputID }, set: { capture.selectAudioInput($0) })) {
                    Text("自动 · 优先外接麦克风").tag("")
                    ForEach(capture.audioInputs) { input in Text(input.name).tag(input.id) }
                    if !capture.preferredInputID.isEmpty, !capture.audioInputs.contains(where: { $0.id == capture.preferredInputID }) {
                        Text("首选设备（未连接）").tag(capture.preferredInputID)
                    }
                }.pickerStyle(.menu).font(.system(size: 12)).disabled(capture.starting)
                Text(capture.interrupted ? "收音暂不可用，等待恢复" : capture.running ? "实际收音 · " + (capture.activeInputName ?? "等待系统选择") : "先在系统蓝牙中配对；开始记录后更新可用麦克风")
                    .font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
                if capture.running, !capture.preferredInputID.isEmpty, !capture.audioInputs.contains(where: { $0.id == capture.preferredInputID }) {
                    Text("首选设备未连接，已使用其他可用麦克风").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if capture.running {
                HStack { Text("本段待上传 · \(Int(capture.pendingSeconds)) / 60 秒"); Spacer(); if capture.uploading { ProgressView().controlSize(.mini); Text("上一段转写中") } }.font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
                ProgressView(value: min(60, capture.pendingSeconds), total: 60).tint(DayRecordPalette.accent)
                Text("本次已上传 · \(capture.completedUploads) 段").font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
            }
            if capture.queuedCount > 0 {
                HStack {
                    Text("待转写 · \(capture.queuedCount) 段 · " + ByteCountFormatter.string(fromByteCount: capture.queuedBytes, countStyle: .file))
                    Spacer(); Button("重试") { capture.retryUploads() }.disabled(capture.uploading)
                }.font(.system(size: 11)).foregroundStyle(DayRecordPalette.muted)
                Text("缓存上限 4 GB；确认文字保存后删除音频。手机重新连接时自动补传。")
                    .font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text(capture.retaining ? "● 正在保留音频" : "音频转写后自动清理").font(.system(size: 11, weight: .medium)); Text(capture.retaining ? "仅保留触发后的声音 · iPhone 本机" : "离线语音暂存，转写完成后删除").font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted) }
                Spacer(minLength: 0)
                Button(capture.retaining ? "停止保存" : "保留音频") { if capture.retaining { capture.endRetention() } else if capture.running { capture.beginRetention() } else { capture.start(retain: true) } }.font(.system(size: 11)).foregroundStyle(capture.retaining ? .red : DayRecordPalette.accent).disabled(capture.starting || capture.interrupted)
            }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(DayRecordPalette.line).frame(height: 1) }
            if let end = capture.retentionEnd { Text(end, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.red) }
            if let last = capture.lastUploadedAt { Text("最近完成转写 · " + last.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(DayRecordPalette.muted) }
        }
    }
}
private struct DayRecordClipsView: View {
    @ObservedObject var capture: DayRecordPhoneStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("主动保留的声音").font(.system(size: 15, design: .serif))
            if capture.clips.isEmpty { Text("没有保留的音频片段。").font(.system(size: 12)).foregroundStyle(DayRecordPalette.muted) }
            ForEach(capture.clips, id: \.self) { url in
                VStack(alignment: .leading, spacing: 12) { Text(capture.creation(url).formatted()).font(.system(size: 12)); HStack { Button("播放") { capture.play(url) }.disabled(capture.running); ShareLink(item: url) { Text("导出") }.disabled(capture.retaining); Spacer(); Button("删除", role: .destructive) { capture.delete(url) }.disabled(capture.retaining) }.font(.system(size: 11)) }.padding(18).dayRecordPanel()
            }
        }
    }
}
#endif
