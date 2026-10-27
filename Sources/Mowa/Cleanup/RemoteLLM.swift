import Foundation
import Security

/// Cleanup on the user's own model server instead of a model on this Mac. Any server with an
/// OpenAI-compatible chat completions API works: Ollama, LM Studio, llama.cpp, vLLM…
/// Only used when the user selects "Model on a server" in Settings → Models.
enum RemoteLLM {
    /// Value of `AppSettings.cleanupModelID` while the server is selected.
    static let selectionID = "server"

    struct Config {
        let endpoint: URL
        let model: String
        let apiKey: String
    }

    /// nil until both the address and the model name are filled in.
    static func config(_ settings: AppSettings) -> Config? {
        let model = settings.serverModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let endpoint = endpoint(settings.serverURL) else { return nil }
        return Config(endpoint: endpoint, model: model, apiKey: ServerKey.read())
    }

    /// Address and model name are filled in (no Keychain read, cheap enough for view updates).
    static func isConfigured(_ settings: AppSettings) -> Bool {
        !settings.serverModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint(settings.serverURL) != nil
    }

    /// Accepts `http://host:port`, `…/v1` or the full `…/v1/chat/completions` address.
    static func endpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        if s.hasSuffix("/chat/completions") { return url }
        if s.hasSuffix("/v1") { return URL(string: s + "/chat/completions") }
        return URL(string: s + "/v1/chat/completions")
    }

    static func generate(_ config: Config, system: String, user: String, maxTokens: Int,
                         timeout: Double) async throws -> String {
        var request = URLRequest(url: config.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteLLMError.badReply }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw RemoteLLMError.http(http.statusCode, detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw RemoteLLMError.badReply }
        return content
    }

    /// Settings → "Test connection". nil = it works.
    static func test(_ config: Config) async -> String? {
        do {
            _ = try await generate(config, system: "Reply with OK.", user: "OK", maxTokens: 5, timeout: 20)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum RemoteLLMError: LocalizedError {
    case badReply
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badReply:
            return L("The server's reply wasn't understood. It must support the OpenAI chat completions API.")
        case .http(let code, let detail):
            let base = LF("The server answered with error %d.", code)
            return detail.isEmpty ? base : base + " " + detail
        }
    }
}

/// The server's API key, kept in the login Keychain (not in preferences).
enum ServerKey {
    private static let service = "com.unomage.mowa.server"
    private static let account = "apiKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ key: String) {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
