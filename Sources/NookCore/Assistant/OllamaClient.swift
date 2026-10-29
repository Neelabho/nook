import Foundation

/// Validates the configured Ollama endpoint. Only loopback HTTP(S) endpoints are accepted,
/// so a misconfiguration can never send prompts to another machine.
public enum OllamaEndpoint {
    public enum ValidationError: Error, Equatable, LocalizedError {
        case malformed, unsupportedScheme, notLoopback, containsCredentials, unexpectedPathOrQuery

        public var errorDescription: String? {
            switch self {
            case .malformed: return "The endpoint isn't a valid URL."
            case .unsupportedScheme: return "Only http:// or https:// endpoints are allowed."
            case .notLoopback: return "Only this Mac (127.0.0.1, ::1 or localhost) is allowed. Nook never sends prompts to another machine."
            case .containsCredentials: return "Endpoints must not contain a username or password."
            case .unexpectedPathOrQuery: return "Use the server root (for example http://127.0.0.1:11434) without a path or query."
            }
        }
    }

    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public static func validate(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw ValidationError.malformed
        }
        guard scheme == "http" || scheme == "https" else { throw ValidationError.unsupportedScheme }
        guard components.user == nil, components.password == nil else { throw ValidationError.containsCredentials }
        guard loopbackHosts.contains(host) else { throw ValidationError.notLoopback }
        guard components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil else {
            throw ValidationError.unexpectedPathOrQuery
        }
        if let port = components.port, !(1...65_535).contains(port) { throw ValidationError.malformed }
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = components.host
        normalized.port = components.port ?? (scheme == "http" ? 11_434 : nil)
        guard let url = normalized.url else { throw ValidationError.malformed }
        return url
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var id: UUID
    public var role: Role
    public var content: String
    public var thinking: String?
    public var createdAt: Date
    public var stats: GenerationStats?

    public init(id: UUID = UUID(), role: Role, content: String, thinking: String? = nil, createdAt: Date = Date(), stats: GenerationStats? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.createdAt = createdAt
        self.stats = stats
    }
}

public struct GenerationStats: Codable, Equatable, Sendable {
    public var evalCount: Int?
    public var evalDurationNanos: Int64?
    public var loadDurationNanos: Int64?
    public var totalDurationNanos: Int64?
    public var doneReason: String?

    public var tokensPerSecond: Double? {
        guard let count = evalCount, let nanos = evalDurationNanos, nanos > 0 else { return nil }
        return Double(count) / (Double(nanos) / 1_000_000_000)
    }
}

public struct OllamaModel: Equatable, Sendable, Identifiable, Hashable {
    public var name: String
    public var sizeBytes: Int64?
    public var parameterSize: String?
    public var family: String?
    public var quantization: String?
    public var id: String { name }
}

public struct OllamaRunningModel: Equatable, Sendable {
    public var name: String
    public var sizeBytes: Int64?
    public var vramBytes: Int64?
    public var expiresAt: Date?
}

public enum OllamaError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint(String)
    case serviceUnavailable
    case modelNotFound(String)
    case cloudModelRefused(String)
    case server(status: Int, message: String)
    case malformedResponse
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let why): return why
        case .serviceUnavailable: return "Ollama isn't running on this Mac. Open the Ollama app (or run `ollama serve`) and try again."
        case .modelNotFound(let name): return "The model “\(name)” isn't installed in Ollama. Nook never downloads models; install it yourself with `ollama pull \(name)` if you want it."
        case .cloudModelRefused(let name): return "“\(name)” is a cloud model. Nook only uses models that run locally."
        case .server(let status, let message): return "Ollama returned an error (\(status)): \(message)"
        case .malformedResponse: return "Ollama sent a response Nook couldn't read."
        case .timedOut: return "Ollama didn't respond in time. The model may still be loading — try again."
        case .cancelled: return "Stopped."
        }
    }
}

/// Transport abstraction so streaming, errors and cancellation can be tested without a server.
public protocol OllamaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

public final class URLSessionOllamaTransport: OllamaTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]          // never route loopback traffic through a proxy
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 120            // first token can take a while while the model loads
        config.timeoutIntervalForResource = 60 * 30
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaError.malformedResponse }
        return (data, http)
    }

    public func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaError.malformedResponse }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return (stream, http)
    }
}

public enum ChatStreamEvent: Equatable, Sendable {
    case content(String)
    case thinking(String)
    case done(GenerationStats)
}

public struct ChatOptions: Equatable, Sendable {
    public var contextWindow: Int
    public var maxTokens: Int
    public var think: Bool?
    public var keepAlive: String

    public init(contextWindow: Int = 8192, maxTokens: Int = 2048, think: Bool? = false, keepAlive: String = "5m") {
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.think = think
        self.keepAlive = keepAlive
    }
}

/// Minimal client for the local Ollama HTTP API. It makes requests only when called;
/// there is no background polling or keep-alive traffic.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let transport: OllamaTransport

    public init(endpoint: String, transport: OllamaTransport = URLSessionOllamaTransport()) throws {
        do {
            baseURL = try OllamaEndpoint.validate(endpoint)
        } catch {
            throw OllamaError.invalidEndpoint((error as? LocalizedError)?.errorDescription ?? "Invalid endpoint")
        }
        self.transport = transport
    }

    public static func isCloudModel(name: String, json: [String: Any]) -> Bool {
        if json["remote_host"] != nil || json["remote_model"] != nil { return true }
        let tag = name.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        return tag == "cloud" || tag.hasSuffix("-cloud") || name.lowercased().hasSuffix("-cloud")
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 10) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func mapTransportError(_ error: Error) -> OllamaError {
        if let e = error as? OllamaError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                 NSURLErrorNotConnectedToInternet:
                return .serviceUnavailable
            default: return .serviceUnavailable
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ECONNREFUSED) { return .serviceUnavailable }
        return .malformedResponse
    }

    static func serverError(status: Int, data: Data) -> OllamaError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        return .server(status: status, message: message)
    }

    /// Server version; doubles as a cheap availability check.
    public func version() async throws -> String {
        do {
            let (data, response) = try await transport.send(request("api/version", timeout: 3))
            guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, data: data) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let v = json["version"] as? String else {
                throw OllamaError.malformedResponse
            }
            return v
        } catch { throw Self.mapTransportError(error) }
    }

    /// Locally installed models. Cloud-proxied models are excluded.
    public func listModels() async throws -> [OllamaModel] {
        do {
            let (data, response) = try await transport.send(request("api/tags", timeout: 5))
            guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, data: data) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { throw OllamaError.malformedResponse }
            return models.compactMap { m in
                guard let name = (m["name"] as? String) ?? (m["model"] as? String), !Self.isCloudModel(name: name, json: m) else { return nil }
                let details = m["details"] as? [String: Any]
                return OllamaModel(
                    name: name,
                    sizeBytes: (m["size"] as? NSNumber)?.int64Value,
                    parameterSize: details?["parameter_size"] as? String,
                    family: details?["family"] as? String,
                    quantization: details?["quantization_level"] as? String
                )
            }.sorted { $0.name < $1.name }
        } catch { throw Self.mapTransportError(error) }
    }

    /// Models currently loaded in memory (for transparent memory reporting).
    public func runningModels() async throws -> [OllamaRunningModel] {
        do {
            let (data, response) = try await transport.send(request("api/ps", timeout: 3))
            guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, data: data) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { throw OllamaError.malformedResponse }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return models.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                return OllamaRunningModel(
                    name: name,
                    sizeBytes: (m["size"] as? NSNumber)?.int64Value,
                    vramBytes: (m["size_vram"] as? NSNumber)?.int64Value,
                    expiresAt: (m["expires_at"] as? String).flatMap { iso.date(from: $0) }
                )
            }
        } catch { throw Self.mapTransportError(error) }
    }

    /// Capabilities reported by `/api/show` (e.g. "completion", "thinking", "vision").
    public func capabilities(of model: String) async throws -> Set<String> {
        do {
            let (data, response) = try await transport.send(request("api/show", method: "POST", body: ["model": model], timeout: 5))
            if response.statusCode == 404 { throw OllamaError.modelNotFound(model) }
            guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, data: data) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OllamaError.malformedResponse }
            if Self.isCloudModel(name: model, json: json) { throw OllamaError.cloudModelRefused(model) }
            return Set((json["capabilities"] as? [String]) ?? [])
        } catch { throw Self.mapTransportError(error) }
    }

    /// Asks Ollama to release the model from memory now.
    public func unload(model: String) async throws {
        do {
            let (data, response) = try await transport.send(request("api/generate", method: "POST", body: ["model": model, "keep_alive": 0], timeout: 10))
            guard response.statusCode == 200 else { throw Self.serverError(status: response.statusCode, data: data) }
        } catch { throw Self.mapTransportError(error) }
    }

    static func chatBody(model: String, messages: [ChatMessage], options: ChatOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "options": ["num_ctx": options.contextWindow, "num_predict": options.maxTokens],
        ]
        if let think = options.think { body["think"] = think }
        body["keep_alive"] = options.keepAlive == "0" ? 0 : options.keepAlive
        return body
    }

    /// Streams a chat completion. Cancel the consuming task to stop generation; the HTTP request
    /// is cancelled with it, which tells Ollama to stop.
    public func chat(model: String, messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let transport = self.transport
        let request: URLRequest
        do {
            request = try self.request("api/chat", method: "POST", body: Self.chatBody(model: model, messages: messages, options: options), timeout: 300)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: OllamaError.malformedResponse) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (lines, response) = try await transport.stream(request)
                    if response.statusCode != 200 {
                        var collected = Data()
                        for try await line in lines { collected.append(contentsOf: Array(line.utf8)) }
                        if response.statusCode == 404 { throw OllamaError.modelNotFound(model) }
                        throw Self.serverError(status: response.statusCode, data: collected)
                    }
                    var filter = ThinkTagFilter()
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty else { continue }
                        for event in try Self.parseChatLine(line, filter: &filter) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseChatLine(_ line: String, filter: inout ThinkTagFilter) throws -> [ChatStreamEvent] {
        guard let data = line.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaError.malformedResponse
        }
        if let error = json["error"] as? String { throw OllamaError.server(status: 200, message: error) }
        var events: [ChatStreamEvent] = []
        if let message = json["message"] as? [String: Any] {
            if let thinking = message["thinking"] as? String, !thinking.isEmpty { events.append(.thinking(thinking)) }
            if let content = message["content"] as? String, !content.isEmpty {
                events.append(contentsOf: filter.consume(content))
            }
        }
        if (json["done"] as? Bool) == true {
            events.append(contentsOf: filter.flush())
            events.append(.done(GenerationStats(
                evalCount: (json["eval_count"] as? NSNumber)?.intValue,
                evalDurationNanos: (json["eval_duration"] as? NSNumber)?.int64Value,
                loadDurationNanos: (json["load_duration"] as? NSNumber)?.int64Value,
                totalDurationNanos: (json["total_duration"] as? NSNumber)?.int64Value,
                doneReason: json["done_reason"] as? String
            )))
        }
        return events
    }
}

/// Routes inline `<think>…</think>` sections (emitted by some model/server combinations)
/// to the thinking channel, even when tags are split across streamed chunks.
public struct ThinkTagFilter: Sendable {
    private var buffer = ""
    private var inThink = false
    public init() {}

    public mutating func consume(_ chunk: String) -> [ChatStreamEvent] {
        buffer += chunk
        var events: [ChatStreamEvent] = []
        while true {
            let tag = inThink ? "</think>" : "<think>"
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty { events.append(inThink ? .thinking(before) : .content(before)) }
                buffer = String(buffer[range.upperBound...])
                inThink.toggle()
                continue
            }
            // Keep a possible partial tag at the end of the buffer for the next chunk.
            let keep = Self.partialSuffixLength(of: buffer, tag: tag)
            let emitEnd = buffer.index(buffer.endIndex, offsetBy: -keep)
            let emit = String(buffer[..<emitEnd])
            if !emit.isEmpty { events.append(inThink ? .thinking(emit) : .content(emit)) }
            buffer = String(buffer[emitEnd...])
            return events
        }
    }

    public mutating func flush() -> [ChatStreamEvent] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return [inThink ? .thinking(buffer) : .content(buffer)]
    }

    static func partialSuffixLength(of text: String, tag: String) -> Int {
        let maxLen = min(tag.count - 1, text.count)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) where tag.hasPrefix(String(text.suffix(len))) {
            return len
        }
        return 0
    }
}
