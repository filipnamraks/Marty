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
    /// Set when the user hand-edits this section, so live fills won't clobber it.
    var userEdited: Bool

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
        status: Status = .upcoming,
        userEdited: Bool = false
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
        self.userEdited = userEdited
    }

    // Tolerant decoding so older saved agendas (without `userEdited`) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        heading = try c.decode(String.self, forKey: .heading)
        subheading = try c.decodeIfPresent(String.self, forKey: .subheading)
        level = try c.decode(Int.self, forKey: .level)
        originalBullets = try c.decode([String].self, forKey: .originalBullets)
        filledContent = try c.decode(String.self, forKey: .filledContent)
        filledAt = try c.decodeIfPresent(Date.self, forKey: .filledAt)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        status = try c.decode(Status.self, forKey: .status)
        userEdited = try c.decodeIfPresent(Bool.self, forKey: .userEdited) ?? false
    }
}
