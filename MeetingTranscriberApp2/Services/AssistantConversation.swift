import Foundation

struct AssistantTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
}

final class AssistantConversation {
    private(set) var turns: [AssistantTurn] = []
    private(set) var startedAt: Date?

    var isEmpty: Bool { turns.isEmpty }
    var count: Int { turns.count }

    func append(_ turn: AssistantTurn) {
        if turns.isEmpty { startedAt = Date() }
        turns.append(turn)
    }

    func reset() {
        turns.removeAll()
        startedAt = nil
    }
}
