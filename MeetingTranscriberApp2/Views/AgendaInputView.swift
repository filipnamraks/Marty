import SwiftUI

/// Intake screen — the "Before" state from the Ledger mockup. Two cards:
/// paste your agenda, or fetch it via a local source (calendar / notion / drive).
struct AgendaInputView: View {
    var onAgendaReady: (Agenda) -> Void
    var onCancel: (() -> Void)? = nil
    var calendar: CalendarStore

    @State private var pasteText: String = ""
    @State private var fetchInstruction: String = ""
    @State private var fetchState: FetchState = .idle

    enum FetchState: Equatable {
        case idle
        case loading
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                HStack(alignment: .top, spacing: 18) {
                    pasteCard
                    fetchCard
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 36)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .overlay(alignment: .topLeading) {
            if let onCancel { backButton(onCancel) }
        }
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("←")
                Text("Back")
            }
            .font(.ui(12, weight: .medium))
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.leading, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before — bring in the agenda")
                .font(.mono(11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(Theme.inkMuted)
            Text("The agenda is the artifact.")
                .font(.serif(36))
                .foregroundStyle(Theme.ink)
            Text("Drop it in or fetch it from your calendar. Headlines and subheadlines become the document Marty fills in as you talk.")
                .font(.bodySerif(15))
                .foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste it in")
                .font(.serif(22))
                .foregroundStyle(Theme.ink)
            Text("Drop in the agenda from anywhere. Marty reads headlines and subheadlines and builds the document shell.")
                .font(.bodySerif(13))
                .foregroundStyle(Theme.inkSoft)

            ZStack(alignment: .topLeading) {
                if pasteText.isEmpty {
                    Text(samplePlaceholder)
                        .font(.bodySerif(13.5))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $pasteText)
                    .font(.bodySerif(13.5))
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 200)
            }
            .background(Theme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.strokeBold, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )

            HStack {
                Spacer()
                Button(action: submitPaste) {
                    Text("Build agenda →")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Theme.paper)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.strokeBold, lineWidth: 1.5)
        )
    }

    private var fetchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or fetch it")
                .font(.serif(22))
                .foregroundStyle(Theme.ink)
            Text("Give one line. A local source pulls the real agenda from your calendar, notes, or docs.")
                .font(.bodySerif(13))
                .foregroundStyle(Theme.inkSoft)

            VStack(alignment: .leading, spacing: 10) {
                TextField("> \"the weekly product sync, today at 10\"",
                          text: $fetchInstruction)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .foregroundStyle(Theme.inkSoft)

                HStack(spacing: 8) {
                    sourceTag("calendar")
                    sourceTag("notion")
                    sourceTag("drive")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sidebar)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )

            fetchStatus

            HStack {
                Spacer()
                Button(action: submitFetch) {
                    Text(fetchState == .loading ? "Fetching…" : "Fetch →")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(Color.white)
                                .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                        )
                }
                .buttonStyle(.plain)
                .disabled(disableFetch)
                .opacity(disableFetch ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.strokeBold, lineWidth: 1.5)
        )
    }

    private func sourceTag(_ name: String) -> some View {
        Text(name)
            .font(.mono(10))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0xEE/255, green: 0xF0/255, blue: 0xEA/255))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }

    private func submitPaste() {
        let agenda = AgendaParser.parse(markdown: pasteText)
        onAgendaReady(agenda)
    }

    private var disableFetch: Bool {
        fetchState == .loading ||
            fetchInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var fetchStatus: some View {
        switch fetchState {
        case .idle:
            EmptyView()
        case .loading:
            Text("Looking across calendar & Notion…")
                .font(.mono(10))
                .foregroundStyle(Theme.inkMuted)
        case .error(let msg):
            Text(msg)
                .font(.mono(10))
                .foregroundStyle(Theme.recordText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submitFetch() {
        let intent = fetchInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return }
        fetchState = .loading
        Task {
            let resolver = AgendaResolver.standard(calendar: calendar)
            do {
                let agenda = try await resolver.resolve(intent: intent)
                fetchState = .idle
                onAgendaReady(agenda)
            } catch {
                fetchState = .error(error.localizedDescription)
            }
        }
    }

    private let samplePlaceholder = """
        Weekly Product Sync
        1. Last week's metrics — activation, retention, funnel
        2. Onboarding redesign
        3. Pricing experiment
        4. Support backlog
        5. Next steps & owners
        """
}
