import Foundation

struct Agenda: Codable, Equatable {
    var title: String
    var sections: [AgendaSection]
    var rawMarkdown: String

    var sectionCount: Int { sections.count }
    var filledCount: Int { sections.filter { !$0.filledContent.isEmpty }.count }
}

struct AgendaSection: Codable, Equatable, Identifiable {
    let id: UUID
    var heading: String
    var subheading: String?
    var level: Int
    var originalBullets: [String]
    var filledContent: String
    var filledAt: Date?
    var isDraft: Bool
    var status: Status

    enum Status: String, Codable {
        case upcoming
        case writing
        case filled
        case refined
        case notCovered
        case offAgenda
    }

    init(
        id: UUID = UUID(),
        heading: String,
        subheading: String? = nil,
        level: Int = 2,
        originalBullets: [String] = [],
        filledContent: String = "",
        filledAt: Date? = nil,
        isDraft: Bool = false,
        status: Status = .upcoming
    ) {
        self.id = id
        self.heading = heading
        self.subheading = subheading
        self.level = level
        self.originalBullets = originalBullets
        self.filledContent = filledContent
        self.filledAt = filledAt
        self.isDraft = isDraft
        self.status = status
    }
}
