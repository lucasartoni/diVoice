import DiVoiceCore
import Foundation
import Testing

@testable import DiVoiceEngine

@Suite("Organization relay")
struct RelayTests {
  let server = URL(string: "https://team.example.com")!
  let sessionId = "0b5c8a62-3f1e-4f6a-9d1e-2a7b9c4d5e6f"

  @Test func connectsWithTheMemberTokenAndSendsAudioAsBinaryFrames() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    let services = RelayServices.services(.defaults(.mistral), relay: relay, server: server, sessionId: sessionId)
    let streaming = services.transcription.openStreaming(
      TranscriptionRequest(model: "ignored", language: "it", vocabulary: ["Zentrix"], sampleRate: 16_000), onText: nil)
    await streaming.sendAudio(Data(count: 3_200))
    await streaming.sendAudio(Data(count: 1_600))

    try await eventually { connector.socket.binary.count == 2 }
    let request = try #require(connector.requests.first)
    #expect(request.url?.absoluteString == "wss://team.example.com/v2/relay")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-member-token")
    let start = try #require(connector.socket.sent.first)
    #expect(start["type"] as? String == "start")
    #expect(start["sessionId"] as? String == sessionId)
    #expect(start["sampleRate"] as? Int == 16_000)
    #expect(start["language"] as? String == "it")
    #expect(start["vocabulary"] as? [String] == ["Zentrix"])
    #expect(start["purpose"] as? String == "dictation")
    #expect(connector.socket.binary.map(\.count) == [3_200, 1_600])

    async let result = streaming.finish(timeout: 5)
    try await eventually { connector.socket.sent.contains { $0["type"] as? String == "finish" } }
    connector.socket.server(["type": "transcript", "text": "ciao a tutti", "path": "batch", "language": "it", "timings": ["transcribeMs": 310]])
    let transcript = try await result
    #expect(transcript == TranscriptResult(text: "ciao a tutti", language: "it"))
  }

  @Test func relaysTheCleanupRequestAndReadsTheStreamBack() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    var pipeline = PipelineSettings.defaults(.mistral)
    pipeline.cleanup.prediction = true
    let services = RelayServices.services(pipeline, relay: relay, server: server, sessionId: sessionId)
    let call = ChatCall(model: pipeline.cleanup.model, messages: [ChatMessage(role: .user, content: "Transcript:\nciao")], temperature: 0, maxTokens: 64)

    async let streamed = services.cleanup.stream(call, timeout: 5, onDelta: nil)
    try await eventually { connector.socket.sent.contains { $0["type"] as? String == "chat" } }
    let chat = try #require(connector.socket.sent.first { $0["type"] as? String == "chat" })
    #expect(chat["role"] as? String == "cleanup")
    let id = try #require(chat["id"] as? Int)
    let body = try #require(chat["body"] as? [String: Any])
    #expect(body["model"] as? String == "mistral-small-2603")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 64)

    connector.socket.server(["type": "chat.line", "id": id, "line": #"data: {"choices":[{"delta":{"content":"Ciao."}}]}"#])
    connector.socket.server(["type": "chat.line", "id": id, "line": "data: [DONE]"])
    connector.socket.server(["type": "chat.done", "id": id])
    let result = try await streamed
    #expect(result.text == "Ciao.")
  }

  @Test func providerErrorsArriveAsHTTPErrors() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    let services = RelayServices.services(.defaults(.mistral), relay: relay, server: server, sessionId: sessionId)
    let call = ChatCall(model: "x", messages: [ChatMessage(role: .user, content: "hi")], maxTokens: 10)
    async let streamed = services.scribe.stream(call, timeout: 5, onDelta: nil)
    try await eventually { connector.socket.sent.contains { $0["type"] as? String == "chat" } }
    connector.socket.server(["type": "chat.error", "id": 1, "status": 400, "body": #"{"message":"Invalid model"}"#])
    do {
      _ = try await streamed
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error) == "chat x: HTTP 400 Invalid model")
    }
  }

  @Test func aServerErrorEndsTheDictation() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    let services = RelayServices.services(.defaults(.mistral), relay: relay, server: server, sessionId: sessionId)
    let streaming = services.transcription.openStreaming(TranscriptionRequest(model: "", language: nil, vocabulary: [], sampleRate: 16_000), onText: nil)
    await streaming.sendAudio(Data(count: 320))
    try await eventually { connector.socket.binary.count == 1 }
    connector.socket.server(["type": "error", "code": "no_key", "message": "your organization has no Mistral key yet: ask your admin"])
    do {
      _ = try await streaming.finish(timeout: 5)
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error) == "your organization has no Mistral key yet: ask your admin")
    }
    #expect(connector.socket.isClosed)
  }

  @Test func aWholeDictationRunsThroughTheRelayAndSendsItsCounts() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    let pipeline = RelayServices.clientPipeline(.defaults(.mistral))
    #expect(pipeline.transcription.mode == .realtime)
    let services = RelayServices.services(pipeline, relay: relay, server: server, sessionId: sessionId)
    let run = DictationRun(
      request: DictationRequest(mode: .dictation, context: DictationContext(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack"), language: "it", vocabulary: [], cacheKey: "k"),
      settings: pipeline, services: services)
    await run.start()
    try await run.append(Data(count: 32_000))
    async let output = run.finish()

    try await eventually { connector.socket.sent.contains { $0["type"] as? String == "finish" } }
    connector.socket.server(["type": "transcript", "text": "ehm ci vediamo domani alle dieci", "path": "batch"])
    try await eventually { connector.socket.sent.contains { $0["type"] as? String == "chat" } }
    connector.socket.server(["type": "chat.line", "id": 1, "line": #"data: {"choices":[{"delta":{"content":"Ci vediamo domani alle 10."}}]}"#])
    connector.socket.server(["type": "chat.done", "id": 1])
    let result = try await output
    #expect(result.text == "Ci vediamo domani alle 10.")
    #expect(result.processing == .llm)

    // The app closes right after the counts: they must be written before the close.
    await relay.sendStats(RelayStats(mode: "dictation", category: "workChat", words: result.words, localDay: "2026-11-09", typingWPM: 40, cleanupPath: "llm", timings: ["cleanupMs": 300]))
    await relay.close()
    #expect(connector.socket.waitedTypes == ["stats"])
    let stats = try #require(connector.socket.sent.first { $0["type"] as? String == "stats" })
    #expect(stats["words"] as? Int == 5)
    #expect(stats["localDay"] as? String == "2026-11-09")
    #expect(stats["text"] == nil)
    #expect(connector.socket.isClosed)
  }

  @Test func verifyOfAChatModelOpensASessionWithoutAudio() async throws {
    let connector = FakeConnector()
    let relay = RelayConnection.open(server: server, token: "test-member-token", connector: connector)
    await relay.start(sessionId: sessionId, sampleRate: nil, language: nil, vocabulary: [], purpose: .verify)
    try await eventually { connector.socket.sentCount == 1 }
    let start = try #require(connector.socket.sent.first)
    #expect(start["purpose"] as? String == "verify")
    #expect(start["sampleRate"] == nil)
  }
}
