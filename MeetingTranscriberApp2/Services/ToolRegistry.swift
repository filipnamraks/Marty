import Foundation

/// A single client-side tool we expose to Claude. The schema is JSON Schema as
/// Anthropic expects in `tools[]`. The handler runs on a background task and
/// returns a String (typically JSON-encoded) that becomes the tool_result.
struct ClientTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let run: (_ input: [String: Any]) async throws -> String

    /// Anthropic API representation (`{ name, description, input_schema }`).
    func apiSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": inputSchema
        ]
    }
}

/// Holds the available client-side tools for a single ask() call. New connectors
/// add themselves here; the loop dispatches `tool_use` blocks by name.
final class ToolRegistry {
    private(set) var tools: [ClientTool] = []

    func register(_ tool: ClientTool) {
        tools.append(tool)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw NSError(
                domain: "Marty.ToolRegistry",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' not registered."]
            )
        }
        return try await tool.run(input)
    }

    var isEmpty: Bool { tools.isEmpty }
    var names: [String] { tools.map(\.name) }
}

// MARK: - Built-in tool: exa_search

extension ToolRegistry {
    /// Registers the `exa_search` tool backed by `ExaProvider`. Only adds it
    /// if an Exa API key exists in Keychain.
    func registerExaIfAvailable() {
        guard let provider = ExaProvider.fromStorage() else { return }
        register(ClientTool(
            name: "exa_search",
            description: """
            Search the public web for real-time information using Exa, an AI-optimized search \
            engine. Use this for anything that requires current public data: weather, news, \
            recent funding rounds, prices, sports, today's events. Returns top results with \
            title, URL, and cleaned page text — cite results inline by title with their URL.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Natural-language query. Exa understands semantic intent — phrase it as a complete question or topic, not just keywords."
                    ]
                ],
                "required": ["query"]
            ],
            run: { input in
                let query = (input["query"] as? String) ?? ""
                print("[Marty][Exa] search query=\"\(query)\"")
                guard !query.isEmpty else {
                    return "{\"results\": [], \"note\": \"empty query\"}"
                }
                do {
                    let hits = try await provider.search(query: query, numResults: 5)
                    print("[Marty][Exa] returned \(hits.count) hits")
                    for hit in hits.prefix(3) {
                        print("[Marty][Exa]   • \(hit.title) — \(hit.url)")
                    }
                    let payload: [String: Any] = [
                        "results": hits.map { hit -> [String: Any] in
                            var item: [String: Any] = [
                                "title": hit.title,
                                "url": hit.url
                            ]
                            if let t = hit.text { item["content"] = t }
                            if let p = hit.publishedDate { item["published"] = p }
                            if let a = hit.author { item["author"] = a }
                            return item
                        },
                        "count": hits.count
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                    return String(data: data, encoding: .utf8) ?? "{\"results\": []}"
                } catch {
                    print("[Marty][Exa] ERROR: \(error.localizedDescription)")
                    throw error
                }
            }
        ))
    }
}

// MARK: - Built-in tool: search_notion

extension ToolRegistry {
    /// Registers the `search_notion` tool backed by `NotionProvider`.
    /// Only adds it if a Notion token exists in Keychain.
    func registerNotionIfAvailable() {
        guard let provider = NotionProvider.fromStorage() else { return }
        register(ClientTool(
            name: "search_notion",
            description: """
            Search the user's Notion workspace for pages and databases relevant to the query. \
            Use this when the user asks about people, companies, projects, meeting notes, \
            decisions, deals, or anything else that might be in their own Notion. Returns the \
            top results with title, URL, and snippets. Cite results by title with their URL.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Natural-language search terms — names, topics, keywords."
                    ]
                ],
                "required": ["query"]
            ],
            run: { input in
                let query = (input["query"] as? String) ?? ""
                print("[Marty][Notion] search query=\"\(query)\"")
                guard !query.isEmpty else {
                    return "{\"results\": [], \"note\": \"empty query\"}"
                }
                do {
                    let hits = try await provider.search(query: query)
                    print("[Marty][Notion] returned \(hits.count) hits")
                    for hit in hits.prefix(3) {
                        print("[Marty][Notion]   • \(hit.title) — \(hit.url)")
                    }

                    // Fetch full page content for the top 2 results so Haiku can
                    // actually read what's inside (Notion search returns metadata only).
                    var contents: [String: String] = [:]
                    for hit in hits.prefix(2) {
                        do {
                            let body = try await provider.readPageContent(pageId: hit.id, maxChars: 3500)
                            if !body.isEmpty {
                                contents[hit.id] = body
                                print("[Marty][Notion]   ↳ fetched \(body.count) chars from \(hit.title)")
                            }
                        } catch {
                            print("[Marty][Notion]   ↳ couldn't read \(hit.title): \(error.localizedDescription)")
                        }
                    }

                    let payload: [String: Any] = [
                        "results": hits.map { hit -> [String: Any] in
                            var item: [String: Any] = [
                                "title": hit.title,
                                "url": hit.url
                            ]
                            if let s = hit.snippet { item["snippet"] = s }
                            if let e = hit.lastEdited { item["last_edited"] = e }
                            if let body = contents[hit.id] { item["content"] = body }
                            return item
                        },
                        "count": hits.count
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                    return String(data: data, encoding: .utf8) ?? "{\"results\": []}"
                } catch {
                    print("[Marty][Notion] ERROR: \(error.localizedDescription)")
                    throw error
                }
            }
        ))
    }
}
