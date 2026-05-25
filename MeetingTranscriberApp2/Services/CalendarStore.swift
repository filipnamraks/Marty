import Foundation
import SwiftUI
import Combine

@MainActor
final class CalendarStore: ObservableObject {

    enum LoadState: Equatable {
        case disconnected
        case loading
        case loaded
        case error(String)
    }

    @Published var events: [CalendarEvent] = []
    @Published var state: LoadState = .disconnected
    @Published var connectedEmail: String?
    @Published var lastRefreshed: Date?

    private let provider: CalendarProvider

    init(provider: CalendarProvider = GoogleCalendarProvider()) {
        self.provider = provider
        self.connectedEmail = provider.connectedAccount
        self.state = provider.isConnected ? .loading : .disconnected
    }

    func connect() async {
        do {
            try await provider.connect()
            connectedEmail = provider.connectedAccount
            await refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func disconnect() {
        provider.disconnect()
        connectedEmail = nil
        events = []
        state = .disconnected
    }

    func refresh() async {
        guard provider.isConnected else {
            state = .disconnected
            events = []
            return
        }
        state = .loading
        do {
            let fetched = try await provider.fetchTodayEvents()
            events = fetched
            lastRefreshed = Date()
            state = .loaded
        } catch CalendarProviderError.notConnected {
            connectedEmail = nil
            events = []
            state = .disconnected
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
