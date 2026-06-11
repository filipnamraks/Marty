import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportView: View {
    @Bindable var transcriber: LiveTranscriber
    let pastSession: PastTranscript?

    enum Payload: String, CaseIterable, Identifiable {
        case summary, transcript, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary: return "Summary only"
            case .transcript: return "Transcript only"
            case .both: return "Summary + transcript"
            }
        }
    }

    enum Destination: String, CaseIterable, Identifiable {
        case localMarkdown, localText, clipboard, googleDrive, notion
        var id: String { rawValue }
        /// True if this destination needs an outside account that isn't currently configured.
        /// Used to disable the export button when the user hasn't connected the service yet.
        var requiresConnection: Bool { false }
    }

    @State private var payload: Payload = .both
    @State private var useCleanedTranscript: Bool = true
    @State private var destination: Destination = .localMarkdown
    @State private var instruction: String = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case working
        case success(String)
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                masthead
                payloadSection
                destinationSection
                instructionSection
                statusBar
                exportButton
            }
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    // MARK: Masthead
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("SEND IT SOMEWHERE")
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }
            (Text("Export ").font(.serif(40)) +
             Text("this session").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(40)))
                .foregroundStyle(Theme.ink)
            Text("Pick what to export and where to send it. Marty packages it as Markdown by default.")
                .font(.bodySerif(15, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: 640, alignment: .leading)
        }
    }

    // MARK: What to export
    private var payloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("What to export")
            VStack(spacing: 6) {
                ForEach(Payload.allCases) { p in
                    payloadRow(p)
                }
            }
            if payload != .summary {
                Toggle(isOn: $useCleanedTranscript) {
                    Text("Use Marty's polished transcript (if available)")
                        .font(.ui(12))
                        .foregroundStyle(Theme.inkSoft)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            }
        }
    }

    private func payloadRow(_ p: Payload) -> some View {
        Button(action: { payload = p }) {
            HStack(spacing: 12) {
                Image(systemName: payload == p ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(payload == p ? Theme.accentDeep : Theme.inkMuted)
                Text(p.label)
                    .font(.ui(13, weight: payload == p ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(payload == p ? Theme.sidebar : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(payload == p ? Theme.strokeBold : Theme.stroke, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Destination
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Where to send it")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                destinationCard(.localMarkdown, icon: AnyView(LocalIcon()), title: "Save as Markdown", subtitle: "Choose a folder on your Mac.")
                destinationCard(.localText, icon: AnyView(TextIcon()), title: "Save as Plain text", subtitle: "Plain .txt file, no formatting.")
                destinationCard(.clipboard, icon: AnyView(ClipboardIcon()), title: "Copy to clipboard", subtitle: "Paste anywhere — Markdown formatted.")
                destinationCard(.googleDrive, icon: AnyView(GoogleDriveIcon()), title: "Google Drive", subtitle: "Upload to your Drive. Connect in Settings.")
                destinationCard(.notion, icon: AnyView(NotionIcon()), title: "Notion", subtitle: "Append to a page. Connect in Settings.")
            }
        }
    }

    private func destinationCard(_ d: Destination, icon: AnyView, title: String, subtitle: String) -> some View {
        let selected = destination == d
        return Button(action: { destination = d }) {
            HStack(alignment: .top, spacing: 12) {
                icon
                    .frame(width: 36, height: 36)
                    .background(Theme.sidebar)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.serif(17))
                            .foregroundStyle(Theme.ink)
                        if d.requiresConnection {
                            Text("soon")
                                .font(.mono(8.5))
                                .tracking(0.8)
                                .foregroundStyle(Theme.inkMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                        }
                    }
                    Text(subtitle)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.inkSoft)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accentDeep : Theme.inkMuted)
                    .padding(.top, 4)
            }
            .padding(14)
            .background(selected ? Theme.sidebar : Theme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.strokeBold : Theme.stroke, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Instruction
    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Anything Marty should know?")
            TextEditor(text: $instruction)
                .font(.bodySerif(14))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 80)
                .background(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("e.g. \"Put this in my Google Drive under Meetings/2026 and name it 'Acme follow-up'.\" Marty will use this when the integration is wired up.")
                .font(.bodySerif(12, italic: true))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    // MARK: Status
    @ViewBuilder
    private var statusBar: some View {
        switch status {
        case .idle: EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Exporting…").font(.mono(11)).foregroundStyle(Theme.inkSoft)
            }
        case .success(let msg):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                Text(msg).font(.mono(11)).foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg)
                .font(.mono(11))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
        }
    }

    // MARK: Export button
    private var isExportLocked: Bool {
        switch destination {
        case .localMarkdown, .localText, .clipboard: return false
        case .googleDrive: return !GoogleDriveUploader().isConnected
        case .notion:     return (SecureStorage.read(SecureStorage.notionToken) ?? "").isEmpty
        }
    }

    private var exportButton: some View {
        HStack {
            Spacer()
            Button(action: doExport) {
                HStack(spacing: 10) {
                    Image(systemName: isExportLocked ? "lock.fill" : "arrow.up.right.circle.fill")
                        .font(.system(size: 12))
                    Text(buttonLabel).font(.ui(13, weight: .medium))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(isExportLocked ? Theme.inkMuted : Theme.ink)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isExportLocked || status == .working)
        }
    }

    private var buttonLabel: String {
        switch destination {
        case .localMarkdown: return "Save Markdown file…"
        case .localText: return "Save text file…"
        case .clipboard: return "Copy to clipboard"
        case .googleDrive:
            return GoogleDriveUploader().isConnected ? "Upload to Google Drive" : "Google Drive — connect first"
        case .notion:
            let connected = (SecureStorage.read(SecureStorage.notionToken) ?? "").isEmpty == false
            return connected ? "Send to Notion" : "Notion — connect first"
        }
    }

    // MARK: Helpers
    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.mono(10.5))
                .tracking(1.8)
                .foregroundStyle(Theme.inkMuted)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    // MARK: Content + actions
    private func renderMarkdown() -> String {
        var lines: [String] = []
        let summary = transcriber.summary
        let title = summary?.title ?? "Meeting"
        lines.append("# \(title)")
        lines.append("")
        if payload != .transcript, let s = summary {
            if !s.summary.isEmpty {
                lines.append("_\(s.summary)_")
                lines.append("")
            }
            if let n = s.narrative, !n.isEmpty {
                lines.append(n)
                lines.append("")
            }
            if !s.keyPoints.isEmpty {
                lines.append("## Key points")
                for p in s.keyPoints { lines.append("- \(p)") }
                lines.append("")
            }
            if let q = s.keyQuotes, !q.isEmpty {
                lines.append("## Notable quotes")
                for k in q {
                    let ts = k.timestamp.map { " · \($0)" } ?? ""
                    lines.append("> \(k.quote)  ")
                    lines.append("> — \(k.speaker)\(ts)")
                    lines.append("")
                }
            }
            if let d = s.decisions, !d.isEmpty {
                lines.append("## Decisions")
                for x in d { lines.append("- \(x)") }
                lines.append("")
            }
            if !s.actionItems.isEmpty {
                lines.append("## Action items")
                for a in s.actionItems { lines.append("- [ ] \(a)") }
                lines.append("")
            }
            if let q = s.openQuestions, !q.isEmpty {
                lines.append("## Open questions")
                for x in q { lines.append("- \(x)") }
                lines.append("")
            }
        }
        if payload != .summary {
            lines.append("## Transcript")
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let source = transcriptLines()
            for l in source {
                lines.append("[\(f.string(from: l.timestamp))] **\(l.speaker):** \(l.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderPlainText() -> String {
        var lines: [String] = []
        let summary = transcriber.summary
        let title = summary?.title ?? "Meeting"
        lines.append(title)
        lines.append(String(repeating: "=", count: title.count))
        lines.append("")
        if payload != .transcript, let s = summary {
            if !s.summary.isEmpty { lines.append(s.summary); lines.append("") }
            if let n = s.narrative, !n.isEmpty { lines.append(n); lines.append("") }
            if !s.keyPoints.isEmpty {
                lines.append("Key points:")
                for p in s.keyPoints { lines.append("  • \(p)") }
                lines.append("")
            }
            if !s.actionItems.isEmpty {
                lines.append("Action items:")
                for a in s.actionItems { lines.append("  [ ] \(a)") }
                lines.append("")
            }
        }
        if payload != .summary {
            lines.append("Transcript")
            lines.append("----------")
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            for l in transcriptLines() {
                lines.append("[\(f.string(from: l.timestamp))] \(l.speaker): \(l.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func transcriptLines() -> [TranscriptLine] {
        if let past = pastSession {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return past.lines.map { line in
                let ts = f.date(from: line.timestamp) ?? Date()
                return TranscriptLine(timestamp: ts, speaker: line.speaker, text: line.text)
            }
        }
        if useCleanedTranscript, let cleaned = transcriber.cleanedLines {
            return cleaned
        }
        return transcriber.lines
    }

    private func doExport() {
        switch destination {
        case .clipboard:
            let text = renderMarkdown()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status = .success("Copied — paste anywhere.")
        case .localMarkdown:
            saveToDisk(content: renderMarkdown(), defaultName: "marty-session.md", uti: UTType("net.daringfireball.markdown") ?? .plainText)
        case .localText:
            saveToDisk(content: renderPlainText(), defaultName: "marty-session.txt", uti: .plainText)
        case .googleDrive:
            uploadToDrive()
        case .notion:
            uploadToNotion()
        }
    }

    private func uploadToNotion() {
        guard let provider = NotionProvider.fromStorage() else {
            status = .failure("Connect Notion in Settings first.")
            return
        }
        status = .working
        let title = transcriber.summary?.title ?? "Meeting transcript"
        let blocks = renderNotionBlocks()

        Task {
            do {
                // Find a parent page. Use the most recently edited page the integration sees.
                // Fall back to a clear error if no page is shared.
                let candidates = try await provider.search(query: "", pageSize: 10)
                guard let parent = candidates.first(where: { !$0.url.contains("notion.so/database") })
                                ?? candidates.first else {
                    await MainActor.run {
                        status = .failure("No accessible Notion page. Share at least one page with the Marty integration in Notion.")
                    }
                    return
                }
                let newPageURL = try await provider.createPage(
                    parentPageId: parent.id,
                    title: title,
                    blocks: blocks
                )
                await MainActor.run {
                    status = .success("Sent to Notion — under \(parent.title)")
                    NSWorkspace.shared.open(newPageURL)
                }
            } catch {
                await MainActor.run {
                    status = .failure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Notion block rendering

    private func renderNotionBlocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let summary = transcriber.summary

        if payload != .transcript, let s = summary {
            if !s.summary.isEmpty {
                blocks.append(notionParagraph(s.summary))
            }
            if let n = s.narrative, !n.isEmpty {
                blocks.append(notionParagraph(n))
            }
            if !s.keyPoints.isEmpty {
                blocks.append(notionHeading2("Key points"))
                for p in s.keyPoints { blocks.append(notionBullet(p)) }
            }
            if let d = s.decisions, !d.isEmpty {
                blocks.append(notionHeading2("Decisions"))
                for x in d { blocks.append(notionBullet(x)) }
            }
            if !s.actionItems.isEmpty {
                blocks.append(notionHeading2("Action items"))
                for a in s.actionItems { blocks.append(notionTodo(a, checked: false)) }
            }
            if let q = s.openQuestions, !q.isEmpty {
                blocks.append(notionHeading2("Open questions"))
                for x in q { blocks.append(notionBullet(x)) }
            }
        }

        if payload != .summary {
            blocks.append(notionHeading2("Transcript"))
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            for l in transcriptLines() {
                blocks.append(notionTranscriptLine(timestamp: f.string(from: l.timestamp),
                                                   speaker: l.speaker,
                                                   text: l.text))
            }
        }
        return blocks
    }

    private func notionParagraph(_ text: String) -> [String: Any] {
        ["object": "block",
         "type": "paragraph",
         "paragraph": ["rich_text": [["type": "text", "text": ["content": text]]]]]
    }

    private func notionHeading2(_ text: String) -> [String: Any] {
        ["object": "block",
         "type": "heading_2",
         "heading_2": ["rich_text": [["type": "text", "text": ["content": text]]]]]
    }

    private func notionBullet(_ text: String) -> [String: Any] {
        ["object": "block",
         "type": "bulleted_list_item",
         "bulleted_list_item": ["rich_text": [["type": "text", "text": ["content": text]]]]]
    }

    private func notionTodo(_ text: String, checked: Bool) -> [String: Any] {
        ["object": "block",
         "type": "to_do",
         "to_do": [
            "rich_text": [["type": "text", "text": ["content": text]]],
            "checked": checked
         ]]
    }

    /// Transcript line as a paragraph with three runs: gray timestamp, bold speaker, plain text.
    private func notionTranscriptLine(timestamp: String, speaker: String, text: String) -> [String: Any] {
        ["object": "block",
         "type": "paragraph",
         "paragraph": [
            "rich_text": [
                ["type": "text",
                 "text": ["content": "[\(timestamp)] "],
                 "annotations": ["color": "gray"]],
                ["type": "text",
                 "text": ["content": "\(speaker): "],
                 "annotations": ["bold": true]],
                ["type": "text",
                 "text": ["content": text]]
            ]
         ]]
    }

    private func uploadToDrive() {
        let uploader = GoogleDriveUploader()
        guard uploader.isConnected else {
            status = .failure("Connect Google in Settings → Calendar first.")
            return
        }
        let content = renderMarkdown()
        let defaultName = sanitizedFilename()
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .working
        Task {
            do {
                // 1. Ask Claude to interpret the instruction (if any) into folder + filename.
                var folder = "Marty"
                var filename = defaultName
                if !trimmedInstruction.isEmpty {
                    do {
                        let engine = try AnthropicEngine.fromStorage()
                        let routing = try await engine.routeExport(
                            instruction: trimmedInstruction,
                            defaultFolder: folder,
                            defaultFilename: defaultName
                        )
                        print("[Marty] Drive routing — instruction: \(trimmedInstruction)")
                        print("[Marty] Drive routing — model returned: folder=\(routing.folder ?? "nil") filename=\(routing.filename ?? "nil")")
                        if let f = routing.folder?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
                            folder = sanitize(f, replacing: "/\\:")
                        }
                        if let n = routing.filename?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
                            filename = sanitize(n, replacing: "/\\:*?\"<>|")
                        }
                    } catch {
                        await MainActor.run {
                            status = .failure("Couldn't route instruction with Claude: \(error.localizedDescription)")
                        }
                        return
                    }
                }
                let resolvedFolder = folder
                let resolvedFilename = filename
                // 2. Upload.
                let result = try await uploader.uploadText(
                    content,
                    filename: "\(filename).md",
                    mimeType: "text/markdown",
                    folderName: folder,
                    description: trimmedInstruction.isEmpty ? nil : trimmedInstruction
                )
                await MainActor.run {
                    status = .success("Uploaded \"\(result.name)\" → \(resolvedFolder) — opening in Drive.")
                    if let link = result.webViewLink {
                        NSWorkspace.shared.open(link)
                    }
                }
            } catch {
                await MainActor.run { status = .failure(error.localizedDescription) }
            }
        }
    }

    private func sanitize(_ s: String, replacing chars: String) -> String {
        let bad = CharacterSet(charactersIn: chars)
        return s.components(separatedBy: bad).joined(separator: "-")
    }

    private func sanitizedFilename() -> String {
        let base: String
        if let title = transcriber.summary?.title, !title.isEmpty {
            base = title
        } else if let past = pastSession {
            base = past.summary.title
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH-mm"
            base = "Marty session \(f.string(from: Date()))"
        }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return base.components(separatedBy: bad).joined(separator: "-")
    }

    private func saveToDisk(content: String, defaultName: String, uti: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [uti]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                status = .success("Saved to \(url.lastPathComponent).")
            } catch {
                status = .failure("Couldn't save: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Brand glyphs (simple, editorial)

private struct GoogleDriveIcon: View {
    var body: some View {
        Image("GoogleDriveLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 28, height: 28)
    }
}

private struct NotionIcon: View {
    var body: some View {
        Image("NotionLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
    }
}

private struct LocalIcon: View {
    var body: some View {
        Image(systemName: "doc.text")
            .font(.system(size: 14))
            .foregroundStyle(Theme.accentDeep)
    }
}

private struct TextIcon: View {
    var body: some View {
        Image(systemName: "doc.plaintext")
            .font(.system(size: 14))
            .foregroundStyle(Theme.accentDeep)
    }
}

private struct ClipboardIcon: View {
    var body: some View {
        Image(systemName: "doc.on.doc")
            .font(.system(size: 14))
            .foregroundStyle(Theme.accentDeep)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
