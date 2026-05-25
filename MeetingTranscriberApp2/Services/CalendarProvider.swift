import Foundation

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let location: String?
    let attendeeCount: Int
    let isRecurring: Bool
    let conferenceURL: URL?
}

enum CalendarProviderError: Error, LocalizedError {
    case notConnected
    case authorizationFailed(String)
    case transport(Error)
    case http(status: Int, message: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a calendar."
        case .authorizationFailed(let msg): return "Authorization failed: \(msg)"
        case .transport(let err): return "Network error: \(err.localizedDescription)"
        case .http(let s, let m): return "HTTP \(s): \(m)"
        case .decode(let m): return "Decode error: \(m)"
        }
    }
}

protocol CalendarProvider {
    var isConnected: Bool { get }
    var connectedAccount: String? { get }
    func connect() async throws
    func disconnect()
    func fetchTodayEvents() async throws -> [CalendarEvent]
}
