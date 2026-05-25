import Foundation

/// Single search hit returned to Haiku as part of a tool_result.
struct NotionResult: Codable, Equatable {
    let id: String
    let title: String
    let url: String
    let snippet: String?         // best-effort excerpt of the page
    let lastEdited: String?      // ISO timestamp from Notion
}

enum NotionError: Error, LocalizedError {
    case notConfigured
    case http(status: Int, message: String)
    case decode(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "Notion isn't connected. Add the integration token in Settings."
        case .http(let s, let m):   return "Notion HTTP \(s): \(m)"
        case .decode(let m):        return "Notion decode error: \(m)"
        case .transport(let e):     return "Notion network error: \(e.localizedDescription)"
        }
    }
}

/// Thin wrapper around the Notion REST API for our live-assistant use case.
/// Only the `search` endpoint is wired today — we add `databases/{id}/query`
/// and `pages/{id}` lazily when Haiku asks for them.
final class NotionProvider {

    private let endpoint = URL(string: "https://api.notion.com/v1")!
    private let token: String

    init(token: String) {
        self.token = token
    }

    /// Convenience: read the saved integration token from Keychain.
    static func fromStorage() -> NotionProvider? {
        guard let t = SecureStorage.read(SecureStorage.notionToken), !t.isEmpty else {
            return nil
        }
        return NotionProvider(token: t)
    }

    /// Verifies the token by calling `/v1/users/me` and returns the workspace name.
    /// Caller stores the name in Keychain so the UI can show "Connected to <Workspace>".
    func verifyAndFetchWorkspaceName() async throws -> String {
        let url = endpoint.appendingPathComponent("users/me")
        let (data, _) = try await get(url)
        let obj = try jsonObject(data)
        if let bot = obj["bot"] as? [String: Any],
           let workspace = bot["workspace_name"] as? String, !workspace.isEmpty {
            return workspace
        }
        // Fallback: name field on the bot user
        if let name = obj["name"] as? String, !name.isEmpty {
            return name
        }
        return "Notion"
    }

    /// Notion's full-text search across pages + databases the integration has access to.
    /// `pageSize` capped at 10 to keep tool_result payload size sane.
    func search(query: String, pageSize: Int = 6) async throws -> [NotionResult] {
        let url = endpoint.appendingPathComponent("search")
        let body: [String: Any] = [
            "query": query,
            "page_size": pageSize,
            "sort": ["direction": "descending", "timestamp": "last_edited_time"]
        ]
        let (data, _) = try await post(url, body: body)
        let obj = try jsonObject(data)
        guard let results = obj["results"] as? [[String: Any]] else {
            throw NotionError.decode("missing results array")
        }
        return results.compactMap(Self.parseResult)
    }

    /// Creates a new page in Notion under the given parent page (which must be shared
    /// with the integration). Handles Notion's 100-block-per-request limit by creating
    /// the page with the first batch then appending the rest via /v1/blocks/{id}/children.
    /// Returns the new page's URL.
    func createPage(parentPageId: String, title: String, blocks: [[String: Any]]) async throws -> URL {
        let firstBatch = Array(blocks.prefix(100))
        let rest = blocks.count > 100 ? Array(blocks.dropFirst(100)) : []

        let body: [String: Any] = [
            "parent": ["page_id": parentPageId],
            "properties": [
                "title": [
                    "title": [["text": ["content": title]]]
                ]
            ],
            "children": firstBatch
        ]
        let url = endpoint.appendingPathComponent("pages")
        let (data, _) = try await post(url, body: body)
        let obj = try jsonObject(data)
        guard let pageID = obj["id"] as? String,
              let pageURLStr = obj["url"] as? String,
              let pageURL = URL(string: pageURLStr) else {
            throw NotionError.decode("created page missing id/url")
        }

        // Append the remaining blocks in batches of 100.
        if !rest.isEmpty {
            for chunk in stride(from: 0, to: rest.count, by: 100) {
                let end = min(chunk + 100, rest.count)
                let batch = Array(rest[chunk..<end])
                try await appendBlocks(pageId: pageID, blocks: batch)
            }
        }
        return pageURL
    }

    /// PATCH /v1/blocks/{id}/children — appends children to a block (page IDs work too).
    func appendBlocks(pageId: String, blocks: [[String: Any]]) async throws {
        let url = endpoint.appendingPathComponent("blocks/\(pageId)/children")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        addHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])
        _ = try await send(req)
    }

    /// Fetches the actual block content of a page (paragraphs, headings, lists, etc.)
    /// and returns the concatenated plain text, truncated to `maxChars`.
    /// Notion's /v1/search only gives metadata — this is what lets Marty actually
    /// read what's inside a page.
    func readPageContent(pageId: String, maxChars: Int = 4000) async throws -> String {
        var url = endpoint.appendingPathComponent("blocks/\(pageId)/children")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "page_size", value: "100")]
        url = comps.url ?? url

        let (data, _) = try await get(url)
        let obj = try jsonObject(data)
        guard let results = obj["results"] as? [[String: Any]] else {
            return ""
        }
        var pieces: [String] = []
        var charCount = 0
        for block in results {
            let text = Self.extractBlockText(block)
            if text.isEmpty { continue }
            pieces.append(text)
            charCount += text.count
            if charCount >= maxChars { break }
        }
        let joined = pieces.joined(separator: "\n")
        if joined.count > maxChars {
            return String(joined.prefix(maxChars)) + "…"
        }
        return joined
    }

    /// Pulls the plain-text content out of a Notion block, handling the common
    /// block types (paragraph, heading, list items, todo, quote, callout, code).
    private static func extractBlockText(_ block: [String: Any]) -> String {
        guard let type = block["type"] as? String,
              let payload = block[type] as? [String: Any] else { return "" }

        // Most block types put their text in a `rich_text` array of objects with `plain_text`.
        if let rich = payload["rich_text"] as? [[String: Any]] {
            let text = rich.compactMap { $0["plain_text"] as? String }.joined()
            switch type {
            case "heading_1": return text.isEmpty ? "" : "# \(text)"
            case "heading_2": return text.isEmpty ? "" : "## \(text)"
            case "heading_3": return text.isEmpty ? "" : "### \(text)"
            case "bulleted_list_item": return text.isEmpty ? "" : "• \(text)"
            case "numbered_list_item": return text.isEmpty ? "" : "1. \(text)"
            case "to_do":
                let checked = (payload["checked"] as? Bool) ?? false
                return text.isEmpty ? "" : "\(checked ? "[x]" : "[ ]") \(text)"
            case "quote": return text.isEmpty ? "" : "> \(text)"
            case "callout": return text
            case "code":
                let lang = (payload["language"] as? String) ?? ""
                return text.isEmpty ? "" : "```\(lang)\n\(text)\n```"
            default: return text
            }
        }
        // Toggle blocks have rich_text + children but children aren't returned here
        // unless we recurse — skip for v1.
        return ""
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addHeaders(&req)
        return try await send(req)
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func addHeaders(_ req: inout URLRequest) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let pair: (Data, URLResponse)
        do { pair = try await URLSession.shared.data(for: req) }
        catch { throw NotionError.transport(error) }
        guard let http = pair.1 as? HTTPURLResponse else {
            throw NotionError.http(status: -1, message: "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: pair.0, encoding: .utf8) ?? "<no body>"
            throw NotionError.http(status: http.statusCode, message: body)
        }
        return (pair.0, http)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.decode("not a JSON object")
        }
        return obj
    }

    // MARK: - Result parsing

    private static func parseResult(_ item: [String: Any]) -> NotionResult? {
        guard let id = item["id"] as? String,
              let url = item["url"] as? String else { return nil }
        let object = (item["object"] as? String) ?? "page"
        let title = extractTitle(item, object: object) ?? "(untitled)"
        let lastEdited = item["last_edited_time"] as? String
        let snippet = extractSnippet(item)
        return NotionResult(id: id, title: title, url: url, snippet: snippet, lastEdited: lastEdited)
    }

    /// Notion stores titles in different places depending on whether the result
    /// is a page (under `properties.title.title[].plain_text`) or a database
    /// (under `title[].plain_text`).
    private static func extractTitle(_ item: [String: Any], object: String) -> String? {
        if object == "database", let arr = item["title"] as? [[String: Any]] {
            return arr.compactMap { $0["plain_text"] as? String }.joined()
        }
        if let props = item["properties"] as? [String: Any] {
            // Find the title property (its type == "title")
            for (_, value) in props {
                guard let prop = value as? [String: Any],
                      prop["type"] as? String == "title",
                      let arr = prop["title"] as? [[String: Any]] else { continue }
                let joined = arr.compactMap { $0["plain_text"] as? String }.joined()
                if !joined.isEmpty { return joined }
            }
        }
        return nil
    }

    /// Best-effort short excerpt: scan property values and rich_text arrays for
    /// non-empty text, then truncate. Notion's search response doesn't return
    /// page body, so this is mostly other text properties.
    private static func extractSnippet(_ item: [String: Any]) -> String? {
        guard let props = item["properties"] as? [String: Any] else { return nil }
        var pieces: [String] = []
        for (key, value) in props {
            guard let prop = value as? [String: Any],
                  let type = prop["type"] as? String,
                  type != "title" else { continue }
            if let arr = prop[type] as? [[String: Any]] {
                let s = arr.compactMap { $0["plain_text"] as? String }.joined(separator: " ")
                if !s.isEmpty { pieces.append("\(key): \(s)") }
            } else if let s = prop[type] as? String, !s.isEmpty {
                pieces.append("\(key): \(s)")
            } else if let n = prop[type] as? NSNumber {
                pieces.append("\(key): \(n)")
            }
        }
        guard !pieces.isEmpty else { return nil }
        let joined = pieces.joined(separator: " · ")
        return joined.count > 240 ? String(joined.prefix(240)) + "…" : joined
    }
}
