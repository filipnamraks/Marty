import SwiftUI

struct MastheadView: View {
    @Bindable var transcriber: LiveTranscriber
    let pastSession: PastTranscript?  // nil = live mode

    private static let eyebrowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(eyebrowText)
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }
            .padding(.bottom, 12)

            headline

            metaRow
                .padding(.top, 14)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1.5)
        }
    }

    private var eyebrowText: String {
        let date = Self.eyebrowFormatter.string(from: Date())
        if let past = pastSession {
            return "Archive · \(Self.eyebrowFormatter.string(from: past.summary.date))"
        }
        switch transcriber.state {
        case .running:
            return "\(date.uppercased()) · session in progress"
        case .loading:
            return "\(date.uppercased()) · preparing"
        case .stopping:
            return "\(date.uppercased()) · wrapping up"
        case .idle where transcriber.lines.isEmpty:
            return date.uppercased()
        case .idle:
            return "\(date.uppercased()) · last session"
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let past = pastSession {
            (Text(past.summary.title.isEmpty ? "Untitled " : past.summary.title.prefix(while: { $0 != "—" }))
                .font(.serif(40)) +
             Text(" — ").font(.serif(40)).foregroundStyle(Theme.accentDeep) +
             Text("archive").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch transcriber.state {
            case .running, .stopping:
                (Text("Listening").font(.serif(40)) +
                 Text(" — ").font(.serif(40)).foregroundStyle(Theme.accentDeep) +
                 Text("the conversation is being captured.").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading:
                Text("Warming up the model.")
                    .font(.serif(40))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                if transcriber.lines.isEmpty {
                    (Text("Ready when you are. Hit ").font(.serif(40)) +
                     Text("record").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep) +
                     Text(" to begin.").font(.serif(40)))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("Session ").font(.serif(40)) +
                     Text("complete.").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var metaRow: some View {
        let entries: [(String, String)]
        if let past = pastSession {
            entries = [
                ("speakers", "\(Set(past.lines.map(\.speaker)).count)"),
                ("lines", "\(past.lines.count)"),
                ("words", "\(past.lines.reduce(0) { $0 + $1.text.split { c in c.isWhitespace }.count })"),
            ]
        } else {
            entries = [
                ("speakers", "\(max(transcriber.speakerCount, 0))"),
                ("elapsed", formatElapsed(transcriber.elapsedSeconds)),
                ("words", "\(transcriber.wordCount)"),
                ("wpm", "\(transcriber.wordsPerMinute)"),
            ]
        }
        return HStack(spacing: 18) {
            ForEach(entries, id: \.0) { (label, value) in
                HStack(spacing: 4) {
                    Text(value).font(.mono(11.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(label).font(.mono(11.5)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
