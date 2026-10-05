import SwiftUI
import CompanionCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct MessageContentView: View {
    let content: String
    private var blocks: [(code: Bool, text: String)] {
        let parts = content.components(separatedBy: "```")
        return parts.enumerated().map { ($0.offset % 2 == 1, $0.element) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    let lines = block.text.components(separatedBy: "\n")
                    let language = lines.first ?? ""
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(language.isEmpty ? "代码" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button { Clipboard.copy(code) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).accessibilityLabel("复制代码")
                        }
                        ScrollView(.horizontal) { Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    }.padding(14).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                } else if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            markdownLine(line)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func markdownLine(_ line: String) -> some View {
        let heading = line.prefix { $0 == "#" }.count
        if (1...6).contains(heading), line.dropFirst(heading).hasPrefix(" ") {
            inline(String(line.dropFirst(heading + 1))).font(.system(size: heading == 1 ? 21 : heading == 2 ? 18 : 16, weight: .semibold)).padding(.top, 10)
        }
        else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            HStack(alignment: .top, spacing: 9) { Text("•").foregroundStyle(.secondary); inline(String(line.dropFirst(2))) }
        } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            HStack(alignment: .top, spacing: 9) { Text(String(line[range]).trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary); inline(String(line[range.upperBound...])) }
        } else if line.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.4)).frame(width: 3); inline(String(line.dropFirst(2))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        } else if line.trimmingCharacters(in: .whitespaces) == "---" { Divider().padding(.vertical, 4) }
        else if line.isEmpty { Color.clear.frame(height: 5) }
        else { inline(line) }
    }
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage
    @ObservedObject var store: QuendaStore
    let sessionID: String
    private var user: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: user ? "person.crop.circle.fill" : "sparkles").foregroundStyle(user ? Color.secondary : Color.accentColor)
                Text(user ? "你" : "Quenda").font(.caption.weight(.semibold))
                Spacer()
                Button { Clipboard.copy(message.content) } label: { Image(systemName: "doc.on.doc").font(.caption) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("复制消息")
            }
            if !message.content.isEmpty {
                if user { Text(message.content).textSelection(.enabled) }
                else { MessageContentView(content: message.content).textSelection(.enabled) }
            }
            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    MessageAttachmentView(attachment: attachment, store: store, sessionID: sessionID)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(user ? Color.accentColor.opacity(0.075) : Color.secondary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.09)))
    }
}

private struct MessageAttachmentView: View {
    let attachment: MessageAttachment
    @ObservedObject var store: QuendaStore
    let sessionID: String
    @State private var bytes: Data?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let bytes {
                #if os(iOS)
                if let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 10)) }
                #else
                if let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 10)) }
                #endif
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.callout).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: attachment.isImage ? "photo" : "doc") }
            if failed { Text("暂时无法预览，附件仍保存在 Mac 的会话中。").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .task(id: attachment.id) {
            guard attachment.isImage, bytes == nil else { return }
            do { bytes = try await store.imageData(session: sessionID, attachment: attachment) }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

extension View {
    func quendaTechnicalInput() -> some View {
        #if os(iOS)
        return self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}
