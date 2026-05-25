import Foundation

// Single JSON file mapping transcript URL path -> user-overridden title.
// Lives next to the transcripts folder so it travels with them.
enum SessionTitleStore {
    private static var storeURL: URL {
        SessionsScanner.transcriptsDir.appendingPathComponent(".titles.json")
    }

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveAll(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }

    static func customTitle(for url: URL) -> String? {
        loadAll()[url.path]
    }

    static func setCustomTitle(_ title: String?, for url: URL) {
        var dict = loadAll()
        if let title, !title.isEmpty {
            dict[url.path] = title
        } else {
            dict.removeValue(forKey: url.path)
        }
        saveAll(dict)
    }

    static func remove(for url: URL) {
        var dict = loadAll()
        dict.removeValue(forKey: url.path)
        saveAll(dict)
    }

    // Resolved priority: user override → LLM-generated → markdown H1 → filename
    static func resolvedTitle(for url: URL, fallback: String) -> String {
        if let custom = customTitle(for: url), !custom.isEmpty { return custom }
        if let summary = SummarySidecar.load(for: url),
           let llmTitle = summary.title, !llmTitle.isEmpty {
            return llmTitle
        }
        return fallback
    }
}
