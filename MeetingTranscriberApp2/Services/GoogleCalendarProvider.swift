// Google Calendar provider using OAuth 2.0 "Loopback IP" flow for installed apps.
//
// ONE-TIME SETUP (do this once in Google Cloud Console):
//   1. https://console.cloud.google.com → create a project (or reuse one).
//   2. APIs & Services → Library → enable "Google Calendar API".
//   3. APIs & Services → OAuth consent screen → External; add scopes:
//        .../auth/calendar.readonly  and  openid email
//      Add your own Google account as a test user.
//   4. APIs & Services → Credentials → Create Credentials → OAuth client ID
//      → Application type: "Desktop app".
//
// Then copy GoogleSecrets.swift.example to GoogleSecrets.swift (same folder)
// and paste in your Client ID and Client secret. GoogleSecrets.swift is
// .gitignored, so the credentials never get committed.

import Foundation
import AppKit
import CryptoKit

enum GoogleCalendarConfig {
    /// Google OAuth client ID + secret. The real values live in the
    /// .gitignored GoogleSecrets.swift — see the setup notes above.
    static let clientID: String = GoogleSecrets.clientID
    static let clientSecret: String = GoogleSecrets.clientSecret

    static let scopes = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/drive.file openid email"
    static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
}

final class GoogleCalendarProvider: CalendarProvider {

    // Cached access token (memory only). Refresh token is in Keychain.
    private var accessToken: String?
    private var accessTokenExpiresAt: Date?

    var isConnected: Bool {
        (SecureStorage.read(SecureStorage.googleRefreshToken) ?? "").isEmpty == false
    }

    var connectedAccount: String? {
        SecureStorage.read(SecureStorage.googleAccountEmail)
    }

    // MARK: - Connect / disconnect

    func connect() async throws {
        guard !GoogleCalendarConfig.clientID.hasPrefix("REPLACE_WITH_YOUR") else {
            throw CalendarProviderError.authorizationFailed(
                "Set GoogleCalendarConfig.clientID in GoogleCalendarProvider.swift first.")
        }

        let pkce = Self.generatePKCE()
        let state = Self.randomURLSafeString(byteCount: 16)

        // 1. Start loopback listener on an ephemeral port.
        let (port, callback) = try await OAuthLoopback.start(expectedState: state)

        // 2. Open the browser to Google's authorization endpoint.
        let redirect = "http://127.0.0.1:\(port)"
        var comps = URLComponents(url: GoogleCalendarConfig.authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: GoogleCalendarConfig.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleCalendarConfig.scopes),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"), // ensure we get a refresh_token
        ]
        guard let authURL = comps.url else {
            throw CalendarProviderError.authorizationFailed("could not build auth URL")
        }
        await MainActor.run { NSWorkspace.shared.open(authURL) }

        // 3. Wait for the redirect on the loopback.
        let code = try await callback.value

        // 4. Exchange code for tokens.
        try await exchangeCode(code, codeVerifier: pkce.verifier, redirectURI: redirect)
    }

    func disconnect() {
        SecureStorage.delete(SecureStorage.googleRefreshToken)
        SecureStorage.delete(SecureStorage.googleAccountEmail)
        accessToken = nil
        accessTokenExpiresAt = nil
    }

    // MARK: - Calendar API

    func fetchTodayEvents() async throws -> [CalendarEvent] {
        let token = try await validAccessToken()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            throw CalendarProviderError.decode("date math failed")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: start)),
            .init(name: "timeMax", value: iso.string(from: end)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
        ]
        guard let url = comps.url else { throw CalendarProviderError.decode("bad events URL") }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.http(status: -1, message: "no http response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw CalendarProviderError.http(status: http.statusCode, message: msg)
        }

        return try Self.decodeEvents(data)
    }

    // MARK: - Token exchange + refresh

    private func exchangeCode(_ code: String, codeVerifier: String, redirectURI: String) async throws {
        let params: [String: String] = [
            "code": code,
            "client_id": GoogleCalendarConfig.clientID,
            "client_secret": GoogleCalendarConfig.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        let resp = try await postForm(GoogleCalendarConfig.tokenURL, params: params)

        guard let access = resp["access_token"] as? String else {
            throw CalendarProviderError.authorizationFailed("token response missing access_token")
        }
        let expiresIn = (resp["expires_in"] as? Double) ?? 3600
        self.accessToken = access
        self.accessTokenExpiresAt = Date().addingTimeInterval(expiresIn)

        if let refresh = resp["refresh_token"] as? String {
            SecureStorage.write(SecureStorage.googleRefreshToken, value: refresh)
        }
        if let idToken = resp["id_token"] as? String,
           let email = Self.email(fromIDToken: idToken) {
            SecureStorage.write(SecureStorage.googleAccountEmail, value: email)
        }
    }

    private func validAccessToken() async throws -> String {
        if let token = accessToken, let exp = accessTokenExpiresAt, exp.timeIntervalSinceNow > 30 {
            return token
        }
        guard let refresh = SecureStorage.read(SecureStorage.googleRefreshToken), !refresh.isEmpty else {
            throw CalendarProviderError.notConnected
        }
        let params: [String: String] = [
            "client_id": GoogleCalendarConfig.clientID,
            "client_secret": GoogleCalendarConfig.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        let resp = try await postForm(GoogleCalendarConfig.tokenURL, params: params)
        guard let access = resp["access_token"] as? String else {
            // Refresh token may be revoked. Force disconnect so the UI prompts a re-auth.
            disconnect()
            throw CalendarProviderError.notConnected
        }
        let expiresIn = (resp["expires_in"] as? Double) ?? 3600
        self.accessToken = access
        self.accessTokenExpiresAt = Date().addingTimeInterval(expiresIn)
        return access
    }

    // MARK: - HTTP helpers

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: req) }
        catch { throw CalendarProviderError.transport(error) }
    }

    private func postForm(_ url: URL, params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.http(status: -1, message: "no http response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw CalendarProviderError.http(status: http.statusCode, message: msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarProviderError.decode("token JSON parse failed")
        }
        return obj
    }

    // MARK: - Static helpers

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    private static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64URLEncodedString()
        return (verifier, challenge)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    private static func decodeEvents(_ data: Data) throws -> [CalendarEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else {
            throw CalendarProviderError.decode("events list not found")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return items.compactMap { item -> CalendarEvent? in
            guard let id = item["id"] as? String else { return nil }
            let summary = (item["summary"] as? String) ?? "(no title)"
            let status = (item["status"] as? String) ?? "confirmed"
            if status == "cancelled" { return nil }

            // start/end may be { dateTime: "..." } (timed) or { date: "YYYY-MM-DD" } (all-day)
            func parseDate(_ field: String) -> Date? {
                guard let dict = item[field] as? [String: Any] else { return nil }
                if let dt = dict["dateTime"] as? String {
                    return iso.date(from: dt) ?? isoFractional.date(from: dt)
                }
                if let d = dict["date"] as? String {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.timeZone = TimeZone(identifier: dict["timeZone"] as? String ?? "")
                        ?? TimeZone.current
                    return f.date(from: d)
                }
                return nil
            }

            guard let start = parseDate("start"), let end = parseDate("end") else { return nil }

            let attendees = (item["attendees"] as? [[String: Any]]) ?? []
            let attendeeCount = attendees.count
            let isRecurring = (item["recurringEventId"] as? String) != nil
            let location = (item["location"] as? String)

            var conferenceURL: URL?
            if let hangoutLink = item["hangoutLink"] as? String, let url = URL(string: hangoutLink) {
                conferenceURL = url
            } else if let conf = item["conferenceData"] as? [String: Any],
                      let entries = conf["entryPoints"] as? [[String: Any]] {
                for e in entries {
                    if let uri = e["uri"] as? String, let url = URL(string: uri) {
                        conferenceURL = url
                        break
                    }
                }
            }

            // Derive a friendly location string: explicit location > conference label > nil
            var displayLocation: String? = location
            if displayLocation == nil, let conf = item["conferenceData"] as? [String: Any],
               let solution = conf["conferenceSolution"] as? [String: Any],
               let name = solution["name"] as? String {
                displayLocation = name
            }

            return CalendarEvent(
                id: id,
                start: start,
                end: end,
                title: summary,
                location: displayLocation,
                attendeeCount: attendeeCount,
                isRecurring: isRecurring,
                conferenceURL: conferenceURL
            )
        }
    }
}

// MARK: - base64url

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback HTTP listener for OAuth callback (BSD socket — bypasses Network.framework EINVAL)

import Darwin

private enum OAuthLoopback {

    /// Binds an ephemeral 127.0.0.1 port via POSIX sockets and returns the port plus a
    /// Task whose value is the auth code received on the OAuth redirect.
    static func start(expectedState: String) async throws -> (port: UInt16, callback: Task<String, Error>) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CalendarProviderError.authorizationFailed("socket() failed: \(posixErr())")
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian        // let kernel pick
        var loopback = in_addr()
        inet_pton(AF_INET, "127.0.0.1", &loopback)
        addr.sin_addr = loopback

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let msg = posixErr()
            close(fd)
            throw CalendarProviderError.authorizationFailed("bind() failed: \(msg)")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        guard Darwin.listen(fd, 1) == 0 else {
            let msg = posixErr()
            close(fd)
            throw CalendarProviderError.authorizationFailed("listen() failed: \(msg)")
        }

        let callback = Task<String, Error> {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { close(fd) }

                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFD: Int32 = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.accept(fd, sa, &clientLen)
                        }
                    }
                    guard clientFD >= 0 else {
                        cont.resume(throwing: CalendarProviderError.authorizationFailed("accept() failed: \(posixErr())"))
                        return
                    }
                    defer { close(clientFD) }

                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                        Darwin.read(clientFD, buf.baseAddress, buf.count)
                    }
                    guard n > 0 else {
                        cont.resume(throwing: CalendarProviderError.authorizationFailed("read returned \(n)"))
                        return
                    }
                    let req = String(decoding: buffer.prefix(n), as: UTF8.self)

                    let firstLine = req.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    let parts = firstLine.split(separator: " ")

                    var resultCode: String?
                    var resultError: String?

                    if parts.count >= 2,
                       let url = URL(string: "http://127.0.0.1\(parts[1])"),
                       let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        let q = comps.queryItems ?? []
                        let code  = q.first(where: { $0.name == "code"  })?.value
                        let state = q.first(where: { $0.name == "state" })?.value
                        let err   = q.first(where: { $0.name == "error" })?.value
                        if let err = err {
                            resultError = "Authorization denied: \(err)"
                        } else if state == expectedState, let code = code {
                            resultCode = code
                        } else {
                            resultError = "invalid state or missing code"
                        }
                    } else {
                        resultError = "could not parse request"
                    }

                    let bodyText = resultCode != nil
                        ? "Marty is connected. You can close this tab."
                        : (resultError ?? "Unknown error.")
                    let html = """
                    <!doctype html><html><head><meta charset="utf-8"><title>Marty</title>
                    <style>body{font-family:-apple-system,system-ui;background:#fbfaf6;color:#1a1a1a;padding:60px;text-align:center}h2{font-weight:400}p{color:#4a4a4a}</style>
                    </head><body><h2>\(bodyText)</h2><p>You can close this tab.</p></body></html>
                    """
                    let body = Data(html.utf8)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var response = Data(header.utf8)
                    response.append(body)
                    response.withUnsafeBytes { raw in
                        _ = Darwin.write(clientFD, raw.baseAddress, raw.count)
                    }

                    if let code = resultCode {
                        cont.resume(returning: code)
                    } else {
                        cont.resume(throwing: CalendarProviderError.authorizationFailed(resultError ?? "unknown"))
                    }
                }
            }
        }

        return (port, callback)
    }

    private static func posixErr() -> String {
        "errno=\(errno) \(String(cString: strerror(errno)))"
    }
}
