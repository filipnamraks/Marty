import Foundation

struct SessionSummary: Identifiable, Hashable {
    let id: URL          // file URL
    let title: String    // pulled from first non-empty content line, or filename
    let date: Date       // parsed from filename
    let lineCount: Int   // number of transcript lines
}

struct PastTranscript {
    struct Line: Identifiable {
        let id = UUID()
        let timestamp: String  // HH:mm:ss as written in the file
        let speaker: String
        let text: String
    }

    let summary: SessionSummary
    let lines: [Line]
}
