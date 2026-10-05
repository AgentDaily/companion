#if os(macOS)
import SwiftUI
import AppKit
import CompanionCore

struct DayRecordVaultPanel: View {
    let library: DayRecordLibrary
    @ObservedObject var vault: DayRecordVault
    @State private var selectionError: String?
    init(library: DayRecordLibrary) { self.library = library; vault = library.vault }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac 资料库文件夹").font(.system(size: 13, weight: .medium))
            Text(vault.directory?.path ?? "尚未选择 · 当前记录保存在 App 本地")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Button(vault.directory == nil ? "选择保存位置…" : "更换保存位置…") { choose() }
                if let directory = vault.directory {
                    Button("在 Finder 打开") { NSWorkspace.shared.open(directory) }
                    Button("重新读取资料库") { selectionError = nil; vault.synchronize(library) }
                }
            }.font(.system(size: 12))
            Text("在所选位置创建 24R 文件夹，可放进已有 Obsidian vault。转写按天保存为 JSON，小时摘要和日报分别保存为 Markdown；已有记录会一并写入，资料库是 App 唯一数据来源；旧位置只保留为迁移备份。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            Text("直接读取 Reports、Hourly、Tasks 和 Transcripts；外部修改刷新后可见。其他文件夹和非日期文件不读取。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            if let message = selectionError ?? vault.error { Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(.top, 20).overlay(alignment: .top) { Divider() }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "选择 24R 资料库的保存位置"
        panel.message = "新位置会创建 24R 并迁入现有记录；选择已有 24R 资料库则直接打开，不合并两边内容。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "保存到这里"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try vault.select(parent: url, library: library); selectionError = nil }
            catch { selectionError = error.localizedDescription }
        }
    }
}
#endif
#if os(macOS)
struct DayRecordVaultStatus: View {
    @ObservedObject var vault: DayRecordVault
    var body: some View {
        if let error = vault.error {
            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}
#endif
