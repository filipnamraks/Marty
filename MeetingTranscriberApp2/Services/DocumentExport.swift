import AppKit
import UniformTypeIdentifiers

/// Turns a meeting's parts into a plain, Word-document-style `NSAttributedString`
/// — no app UI, just clean black-on-white text — and offers Copy (rich) and
/// Save as PDF. This is what makes a saved/exported doc look like a Word file.
enum DocumentExport {

    // MARK: - Build attributed documents

    static func agenda(_ agenda: Agenda) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        doc.append(title(agenda.title))
        for section in agenda.sections {
            doc.append(heading(section.heading))
            if let sub = section.subheading, !sub.isEmpty { doc.append(subheading(sub)) }
            for line in bulletLines(section.filledContent) { doc.append(bullet(line)) }
        }
        return doc
    }

    static func summary(_ s: MeetingSummary) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        doc.append(title(s.title ?? "Summary"))
        if !s.summary.isEmpty { doc.append(subheading(s.summary)) }
        if let narrative = s.narrative, !narrative.isEmpty { doc.append(body(narrative)) }
        appendList(doc, "Key points", s.keyPoints)
        appendList(doc, "Decisions", s.decisions ?? [])
        appendList(doc, "Action items", s.actionItems)
        appendList(doc, "Open questions", s.openQuestions ?? [])
        return doc
    }

    static func transcript(_ lines: [TranscriptLine]) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        doc.append(title("Transcript"))
        for line in lines {
            doc.append(body("\(line.speaker):  \(line.text)"))
        }
        return doc
    }

    private static func appendList(_ doc: NSMutableAttributedString, _ name: String, _ items: [String]) {
        guard !items.isEmpty else { return }
        doc.append(heading(name))
        for item in items { doc.append(bullet(item)) }
    }

    // MARK: - Actions

    static func copy(_ attributed: NSAttributedString) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([attributed])   // provides both RTF and plain text
    }

    static func savePDF(_ attributed: NSAttributedString, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(suggestedName).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)   // US Letter
        info.topMargin = 64; info.bottomMargin = 64
        info.leftMargin = 64; info.rightMargin = 64
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    // MARK: - Styled paragraph builders

    private static let ink = NSColor(calibratedWhite: 0.10, alpha: 1)
    private static let soft = NSColor(calibratedWhite: 0.38, alpha: 1)

    private static func title(_ text: String) -> NSAttributedString {
        paragraph(text, font: .systemFont(ofSize: 22, weight: .bold), color: ink,
                  spacingBefore: 0, spacingAfter: 10)
    }
    private static func heading(_ text: String) -> NSAttributedString {
        paragraph(text, font: .systemFont(ofSize: 14, weight: .semibold), color: ink,
                  spacingBefore: 14, spacingAfter: 3)
    }
    private static func subheading(_ text: String) -> NSAttributedString {
        let f = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        return paragraph(text, font: f, color: soft, spacingBefore: 0, spacingAfter: 5)
    }
    private static func body(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.lineSpacing = 3
        let line = NSMutableAttributedString()
        line.append(inline(text, size: 12, color: ink))
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }
    private static func bullet(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = 16
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 4
        style.lineSpacing = 2
        style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        let line = NSMutableAttributedString(string: "•\t",
                                             attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink])
        line.append(inline(text, size: 12, color: ink))
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Renders inline **bold** markdown into bold runs (dropping the asterisks).
    private static func inline(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size)
        let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
        let out = NSMutableAttributedString()
        var isBold = false
        for part in text.components(separatedBy: "**") {
            if !part.isEmpty {
                out.append(NSAttributedString(string: part,
                                              attributes: [.font: isBold ? bold : base, .foregroundColor: color]))
            }
            isBold.toggle()
        }
        return out
    }

    private static func paragraph(_ text: String, font: NSFont, color: NSColor,
                                  spacingBefore: CGFloat, spacingAfter: CGFloat,
                                  lineSpacing: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = lineSpacing
        return NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ])
    }

    private static func bulletLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").compactMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return String(t.dropFirst(2)) }
            return t
        }
    }
}
