import Foundation
import SwiftUI

@MainActor
@Observable
final class UserProfile {
    static let shared = UserProfile()

    private let nameKey = "Marty.userName"
    private let signedInKey = "Marty.profileSignedIn"

    var name: String
    var isSignedIn: Bool

    var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first.map(String.init)?.first.map(String.init) ?? "?"
        return first.uppercased()
    }

    var displayName: String {
        isSignedIn && !name.isEmpty ? name : "Add your name"
    }

    init() {
        self.name = UserDefaults.standard.string(forKey: nameKey) ?? "Filip Skarman"
        self.isSignedIn = UserDefaults.standard.bool(forKey: signedInKey)
    }

    func signIn(name: String) {
        self.name = name
        self.isSignedIn = true
        UserDefaults.standard.set(name, forKey: nameKey)
        UserDefaults.standard.set(true, forKey: signedInKey)
    }

    func signOut() {
        self.isSignedIn = false
        UserDefaults.standard.set(false, forKey: signedInKey)
    }
}
