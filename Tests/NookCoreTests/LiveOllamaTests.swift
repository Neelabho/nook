import Foundation
import Testing
@testable import NookCore

/// Talks to a real local Ollama. Opt-in: `NOOK_LIVE_OLLAMA=1 scripts/test.sh --filter LiveOllama`.
/// Never pulls models; skips if the model isn't installed.
@Suite("Live Ollama (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["NOOK_LIVE_OLLAMA"] == "1"))
struct LiveOllamaTests {
    let model = ProcessInfo.processInfo.environment["NOOK_LIVE_MODEL"] ?? "qwen3:8b"

    @Test func listsModelsStreamsAndCancels() async throws {
        let client = try OllamaClient(endpoint: "http://127.0.0.1:11434")
        let version = try await client.version()
        let models = try await client.listModels()
        print("Ollama \(version); models: \(models.map(\.name))")
        try #require(models.contains { $0.name == model }, "model \(model) not installed")
        let caps = try await client.capabilities(of: model)
        print("capabilities: \(caps.sorted())")

        // 1. Full streamed reply.
        let started = Date()
        var firstToken: TimeInterval?
        var text = ""
        var stats: GenerationStats?
        let messages = [ChatMessage(role: .system, content: AssistantAction.systemPrompt),
                        ChatMessage(role: .user, content: "Reply with exactly: Nook works")]
        for try await event in client.chat(model: model, messages: messages, options: ChatOptions(maxTokens: 64, think: caps.contains("thinking") ? false : nil, keepAlive: "1m")) {
            switch event {
            case .content(let t): if firstToken == nil { firstToken = Date().timeIntervalSince(started) }; text += t
            case .thinking: break
            case .done(let s): stats = s
            }
        }
        print("reply: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        print(String(format: "first token %.2fs, total %.2fs, %.1f tok/s, load %.2fs",
                     firstToken ?? -1, Date().timeIntervalSince(started), stats?.tokensPerSecond ?? 0, Double(stats?.loadDurationNanos ?? 0) / 1e9))
        #expect(text.localizedCaseInsensitiveContains("nook works"))
        #expect(stats != nil)

        let running = try await client.runningModels()
        if let loaded = running.first(where: { $0.name == model }) {
            print("loaded size: \(ByteCountFormatter.string(fromByteCount: loaded.sizeBytes ?? 0, countStyle: .memory)), vram \(ByteCountFormatter.string(fromByteCount: loaded.vramBytes ?? 0, countStyle: .memory))")
        }

        // 2. Cancellation mid-stream.
        let counter = Received()
        let task = Task {
            for try await event in client.chat(model: model, messages: [ChatMessage(role: .user, content: "Count from 1 to 500, one number per line.")],
                                               options: ChatOptions(maxTokens: 2000, think: caps.contains("thinking") ? false : nil, keepAlive: "1m")) {
                await counter.add(event)
            }
        }
        for _ in 0..<300 where await counter.count < 10 { try await Task.sleep(for: .milliseconds(20)) }
        let cancelAt = Date()
        task.cancel()
        _ = await task.result
        let atCancel = await counter.count
        let endedMs = Date().timeIntervalSince(cancelAt) * 1000
        try await Task.sleep(for: .milliseconds(500))
        #expect(await counter.count == atCancel, "no events after cancellation")
        print(String(format: "cancelled after %d events, stream ended %.0f ms after cancel", atCancel, endedMs))

        // 3. Unload to free memory.
        try await client.unload(model: model)
        try await Task.sleep(for: .seconds(1))
        #expect(try await client.runningModels().contains { $0.name == model } == false)
    }
}
