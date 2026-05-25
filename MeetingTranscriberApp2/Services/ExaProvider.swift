import Foundation

/// One result from Exa's /search endpoint, with content text included.
struct ExaResult: Codable, Equatable {
    let id: String?
    let title: String
    let url: String
    let publishedDate: String?
    let author: String?
    let text: String?
    let score: Double?
}

enum ExaError: Error, LocalizedError {
    case notConfigured
    case http(status: Int, message: String)
    case decode(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "Exa isn't configured. Paste your API key in Settings."
        case .http(let s, let m): return "Exa HTTP \(s): \(m)"
        case .decode(let m):      return "Exa decode error: \(m)"
        case .transport(let e):   return "Exa network error: \(e.localizedDescription)"
        }
    }
}

/// Thin wrapper around https://api.exa.ai. We use `/search` with `contents.text=true`
/// so each result includes the cleaned page text, letting Haiku synthesize an answer
/// without a second fetch round-trip.
final class ExaProvider {

    private let endpoint = URL(string: "https://api.exa.ai")!
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    static func fromStorage() -> ExaProvider? {
        guard let k = SecureStorage.read(SecureStorage.exaApiKey), !k.isEmpty else {
            return nil
        }
        return ExaProvider(apiKey: k)
    }

    /// Probes the key by calling /search with a trivial query. Returns true if 200.
    func verify() async throws {
        _ = try await search(query: "test", numResults: 1, includeText: false)
    }

    /// Neural + content search. `numResults` defaults to 5 to keep payload sane.
    /// When `includeText` is true, Exa returns ~1000 chars of cleaned content per result.
    func search(query: String, numResults: Int = 5, includeText: Bool = true) async throws -> [ExaResult] {
        var body: [String: Any] = [
            "query": query,
            "type": "auto",                       // neural where helpful, keyword where exact
            "numResults": min(max(numResults, 1), 10),
            "useAutoprompt": true                 // let Exa rewrite the query if it helps
        ]
        if includeText {
            body["contents"] = [
                "text": ["maxCharacters": 1200, "includeHtmlTags": false]
            ]
        }

        let url = endpoint.appendingPathComponent("search")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let pair: (Data, URLResponse)
        do { pair = try await URLSession.shared.data(for: req) }
        catch { throw ExaError.transport(error) }

        guard let http = pair.1 as? HTTPURLResponse else {
            throw ExaError.http(status: -1, message: "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: pair.0, encoding: .utf8) ?? "<no body>"
            throw ExaError.http(status: http.statusCode, message: bodyStr)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: pair.0) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            throw ExaError.decode("results array missing")
        }
        return results.compactMap(Self.parseResult)
    }

    private static func parseResult(_ item: [String: Any]) -> ExaResult? {
        guard let url = item["url"] as? String else { return nil }
        let title = (item["title"] as? String) ?? url
        return ExaResult(
            id: item["id"] as? String,
            title: title,
            url: url,
            publishedDate: item["publishedDate"] as? String,
            author: item["author"] as? String,
            text: item["text"] as? String,
            score: item["score"] as? Double
        )
    }
}
