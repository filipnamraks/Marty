import Foundation

enum Page: Hashable {
    case home
    case live
    case library
    case past(SessionSummary)
}
