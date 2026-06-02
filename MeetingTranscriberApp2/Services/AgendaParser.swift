import Foundation

enum AgendaParser {
    static func parse(markdown: String) -> Agenda {
        let raw = markdown
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var title: String = ""
        var sections: [AgendaSection] = []
        var current: AgendaSection? = nil
        var sawTitle = false

        func flushCurrent() {
            if let c = current { sections.append(c) }
            current = nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let h = parseHeading(line) {
                if !sawTitle && h.level == 1 && title.isEmpty {
                    title = h.text
                    sawTitle = true
                    continue
                }
                flushCurrent()
                let (heading, sub) = splitHeadingSubhead(h.text)
                current = AgendaSection(heading: heading, subheading: sub, level: max(h.level, 2))
                continue
            }

            if let n = parseNumbered(line) {
                flushCurrent()
                let (heading, sub) = splitHeadingSubhead(n)
                current = AgendaSection(heading: heading, subheading: sub, level: 2)
                continue
            }

            if let bullet = parseBullet(line) {
                if current == nil {
                    current = AgendaSection(heading: "Notes", level: 2)
                }
                current?.originalBullets.append(bullet)
                continue
            }

            if !sawTitle {
                title = line
                sawTitle = true
                continue
            }

            if var c = current, c.subheading == nil, c.originalBullets.isEmpty {
                c.subheading = line
                current = c
            } else {
                current?.originalBullets.append(line)
            }
        }

        flushCurrent()

        if title.isEmpty { title = "Untitled meeting" }

        return Agenda(title: title, sections: sections, rawMarkdown: raw)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func parseNumbered(_ line: String) -> String? {
        var idx = line.startIndex
        var sawDigit = false
        while idx < line.endIndex, line[idx].isNumber {
            sawDigit = true
            idx = line.index(after: idx)
        }
        guard sawDigit, idx < line.endIndex else { return nil }
        let rest = line[idx...]
        let trimmed = rest.drop(while: { $0 == " " })
        let separators: [Character] = [".", ")", "·", "-", ":"]
        guard let first = trimmed.first, separators.contains(first) else { return nil }
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func parseBullet(_ line: String) -> String? {
        let markers: [String] = ["- ", "* ", "— ", "– ", "• ", "› ", "› "]
        for m in markers where line.hasPrefix(m) {
            return String(line.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
        }
        if line == "-" || line == "*" || line == "—" { return "" }
        return nil
    }

    private static func splitHeadingSubhead(_ text: String) -> (String, String?) {
        for sep in [" — ", " – ", " - "] {
            if let r = text.range(of: sep) {
                let head = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let sub = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty && !sub.isEmpty { return (head, sub) }
            }
        }
        return (text, nil)
    }
}
