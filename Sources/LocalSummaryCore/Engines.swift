import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple on-device model (Apple Intelligence, macOS 26+)

/// Uses the ~3B on-device model that ships with macOS. Zero setup, nothing to download,
/// but a small context window, so long transcripts are chunked aggressively.
public struct AppleIntelligenceEngine: SummaryEngine {
    public let displayName = "Apple Intelligence (on-device)"
    public let maxChunkCharacters = 6_000  // ~1.5k tokens, leaves room in a 4k context

    public init() {}

    /// nil when usable, otherwise a human-readable reason.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason): return "Apple Intelligence model unavailable (\(reason))."
            }
        }
        #endif
        return "Requires macOS 26 or later with Apple Intelligence enabled."
    }

    public func complete(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let why = Self.unavailableReason { throw LocalSummaryError.engineUnavailable(why) }
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw LocalSummaryError.engineUnavailable(Self.unavailableReason ?? "unknown")
    }
}

// MARK: - Any local OpenAI-compatible server (Ollama, LM Studio, llama.cpp, MLX server)

/// Talks to a model server on localhost. Defaults to Ollama.
public struct LocalServerEngine: SummaryEngine {
    public var baseURL: URL
    public var model: String
    public var maxChunkCharacters: Int
    public var displayName: String { "\(model) @ \(baseURL.host() ?? "localhost"):\(baseURL.port ?? 80)" }

    public static let ollamaDefault = URL(string: "http://localhost:11434/v1")!
    public static let lmStudioDefault = URL(string: "http://localhost:1234/v1")!

    public init(baseURL: URL = LocalServerEngine.ollamaDefault, model: String = "qwen3:8b", maxChunkCharacters: Int = 24_000) {
        self.baseURL = baseURL
        self.model = model
        self.maxChunkCharacters = maxChunkCharacters
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        let choices: [Choice]
    }

    public func complete(system: String, prompt: String) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: prompt)],
            temperature: 0.2, stream: false))
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LocalSummaryError.engineUnavailable(
                "Could not reach \(baseURL.absoluteString). Is Ollama / LM Studio running? (\(error.localizedDescription))")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalSummaryError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw LocalSummaryError.badResponse("empty choices")
        }
        return Self.stripThinking(text)
    }

    /// Lists model ids the server offers (GET /models). Used by Settings' "Test connection".
    public static func listModels(baseURL: URL) async throws -> [String] {
        struct Models: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        var req = URLRequest(url: baseURL.appending(path: "models"))
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalSummaryError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id).sorted()
    }

    /// Reasoning models (Qwen3, DeepSeek-R1) may prepend <think>…</think>.
    static func stripThinking(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s }
        return String(s[r.upperBound...])
    }
}

// MARK: - Engine selection (shared by CLI and app)

public enum EngineKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple, localServer
    public var id: String { rawValue }
    public var label: String { self == .apple ? "Apple Intelligence" : "Local model server (Ollama / LM Studio)" }
}

public struct EngineSettings: Codable, Sendable, Equatable {
    public var kind: EngineKind = .apple
    public var serverURL: String = LocalServerEngine.ollamaDefault.absoluteString
    public var serverModel: String = "qwen3:8b"
    public init() {}

    public func makeEngine() -> SummaryEngine {
        switch kind {
        case .apple: return AppleIntelligenceEngine()
        case .localServer:
            return LocalServerEngine(
                baseURL: URL(string: serverURL) ?? LocalServerEngine.ollamaDefault, model: serverModel)
        }
    }
}
