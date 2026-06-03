import Foundation

enum Page: Hashable {
    case home
    case live
    case library
    case past(SessionSummary)
    case saved(String)   // SavedMeeting id
}
