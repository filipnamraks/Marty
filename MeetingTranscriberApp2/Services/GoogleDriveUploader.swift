import Foundation

// Uploads text content to the user's Google Drive.
// Reuses the OAuth refresh token written by GoogleCalendarProvider — the
// app uses one Google OAuth client with both calendar.readonly and drive.file scopes.
final class GoogleDriveUploader {

    enum UploadError: LocalizedError {
        case notConnected
        case insufficientScope
        case transport(Error)
        case http(status: Int, message: String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to Google. Connect from Settings or the Home schedule prompt."
            case .insufficientScope:
                return "Connected Google account is missing Drive permission. Disconnect and reconnect to grant Drive access."
            case .transport(let e): return "Network: \(e.localizedDescription)"
            case .http(let s, let m): return "Google Drive (\(s)): \(m)"
            case .decode(let m): return "Couldn't decode Drive response: \(m)"
            }
        }
    }

    struct UploadResult {
        let fileID: String
        let name: String
        let webViewLink: URL?
    }

    private var accessToken: String?
    private var accessTokenExpiresAt: Date?

    var isConnected: Bool {
        !(SecureStorage.read(SecureStorage.googleRefreshToken) ?? "").isEmpty
    }

    // MARK: - Public

    /// Upload `content` as a file inside `folderName` (under My Drive root). Folder is created if missing.
    func uploadText(
        _ content: String,
        filename: String,
        mimeType: String = "text/markdown",
        folderName: String = "Marty",
        description: String? = nil
    ) async throws -> UploadResult {
        let token = try await validAccessToken()
        let folderID = try await ensureFolder(named: folderName, token: token)
        return try await multipartUpload(
            content: content,
            filename: filename,
            mimeType: mimeType,
            parentID: folderID,
            description: description,
            token: token
        )
    }

    // MARK: - Folder management

    private func ensureFolder(named name: String, token: String) async throws -> String {
        if let existing = try await findFolder(named: name, token: token) {
            return existing
        }
        return try await createFolder(named: name, token: token)
    }

    private func findFolder(named name: String, token: String) async throws -> String? {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let q = "mimeType='application/vnd.google-apps.folder' and trashed=false and name='\(escaped)'"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "1"),
        ]
        guard let url = comps.url else { throw UploadError.decode("could not build search URL") }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.http(status: -1, message: "no http response")
        }
        if http.statusCode == 403 {
            throw UploadError.insufficientScope
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw UploadError.http(status: http.statusCode, message: msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? [[String: Any]] else {
            throw UploadError.decode("search payload missing files")
        }
        return files.first?["id"] as? String
    }

    private func createFolder(named name: String, token: String) async throws -> String {
        let body: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
        ]
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,name")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.http(status: -1, message: "no http response")
        }
        if http.statusCode == 403 { throw UploadError.insufficientScope }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw UploadError.http(status: http.statusCode, message: msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw UploadError.decode("create folder response missing id")
        }
        return id
    }

    // MARK: - Multipart upload

    private func multipartUpload(
        content: String,
        filename: String,
        mimeType: String,
        parentID: String,
        description: String?,
        token: String
    ) async throws -> UploadResult {
        var metadata: [String: Any] = [
            "name": filename,
            "mimeType": mimeType,
            "parents": [parentID],
        ]
        if let description, !description.isEmpty {
            metadata["description"] = description
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let contentData = Data(content.utf8)

        let boundary = "marty-" + UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(contentData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.http(status: -1, message: "no http response")
        }
        if http.statusCode == 403 { throw UploadError.insufficientScope }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw UploadError.http(status: http.statusCode, message: msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let name = obj["name"] as? String else {
            throw UploadError.decode("upload response missing id/name")
        }
        let link = (obj["webViewLink"] as? String).flatMap(URL.init(string:))
        return UploadResult(fileID: id, name: name, webViewLink: link)
    }

    // MARK: - Token plumbing (reuses refresh token stored by GoogleCalendarProvider)

    private func validAccessToken() async throws -> String {
        if let token = accessToken, let exp = accessTokenExpiresAt, exp.timeIntervalSinceNow > 30 {
            return token
        }
        guard let refresh = SecureStorage.read(SecureStorage.googleRefreshToken), !refresh.isEmpty else {
            throw UploadError.notConnected
        }
        let params: [String: String] = [
            "client_id": GoogleCalendarConfig.clientID,
            "client_secret": GoogleCalendarConfig.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        let resp = try await postForm(GoogleCalendarConfig.tokenURL, params: params)
        guard let access = resp["access_token"] as? String else {
            throw UploadError.notConnected
        }
        let expiresIn = (resp["expires_in"] as? Double) ?? 3600
        self.accessToken = access
        self.accessTokenExpiresAt = Date().addingTimeInterval(expiresIn)
        return access
    }

    // MARK: - HTTP helpers

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: req) }
        catch { throw UploadError.transport(error) }
    }

    private func postForm(_ url: URL, params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.http(status: -1, message: "no http response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw UploadError.http(status: http.statusCode, message: msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadError.decode("token JSON parse failed")
        }
        return obj
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}
