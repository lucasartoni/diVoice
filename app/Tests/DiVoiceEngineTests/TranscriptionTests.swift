import Foundation
import Testing

@testable import DiVoiceEngine

private func mistral(_ connector: FakeConnector, http: FakeHTTP = FakeHTTP()) -> MistralTranscription {
  MistralTranscription(endpoint: .direct(.mistral, apiKey: "secret"), http: http, connector: connector)
}

private func openAI(_ connector: FakeConnector, http: FakeHTTP = FakeHTTP()) -> OpenAITranscription {
  OpenAITranscription(endpoint: .direct(.openai, apiKey: "secret"), http: http, connector: connector)
}

private func mistralRequest(vocabulary: [String] = ["Acme", "Zentrix"], language: String? = "it") -> TranscriptionRequest {
  TranscriptionRequest(model: "voxtral-mini-transcribe-realtime-3-0", language: language, vocabulary: vocabulary, delayMs: 480, sampleRate: 16_000)
}

@Suite struct MistralRealtimeTests {
  @Test func configuresOnSessionCreatedThenSendsQueuedAudio() async throws {
    let connector = FakeConnector()
    let socket = connector.socket
    let transcriber = mistral(connector).openStreaming(mistralRequest(), onText: nil)
    await transcriber.sendAudio(Data([1, 2, 3, 4]))
    try await eventually { connector.requests.count == 1 }
    let request = try #require(connector.requests.first)
    #expect(request.url?.absoluteString == "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-3-0")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(socket.sentCount == 0)

    socket.server(["type": "session.created", "session": [:] as [String: Any]])
    try await eventually { socket.sentCount == 2 }
    let update = socket.sent[0]
    #expect(update["type"] as? String == "session.update")
    let session = try #require(update["session"] as? [String: Any])
    #expect((session["audio_format"] as? [String: Any])?["encoding"] as? String == "pcm_s16le")
    #expect((session["audio_format"] as? [String: Any])?["sample_rate"] as? Int == 16_000)
    #expect(session["target_streaming_delay_ms"] as? Int == 480)
    #expect(session["context_bias"] as? [String] == ["Acme", "Zentrix"])
    #expect(session["language"] as? String == "it")
    #expect(socket.sent[1]["type"] as? String == "input_audio.append")
    #expect(socket.sent[1]["audio"] as? String == "AQIDBA==")
    #expect(await transcriber.connectMs != nil)
    await transcriber.abort()
  }

  @Test func omitsBiasAndLanguageWhenAbsent() async throws {
    let connector = FakeConnector()
    let transcriber = mistral(connector).openStreaming(mistralRequest(vocabulary: [], language: nil), onText: nil)
    try await eventually { connector.requests.count == 1 }
    connector.socket.server(["type": "session.created"])
    try await eventually { connector.socket.sentCount == 1 }
    let session = try #require(connector.socket.sent[0]["session"] as? [String: Any])
    #expect(session["context_bias"] == nil)
    #expect(session["language"] == nil)
    await transcriber.abort()
  }

  @Test func accumulatesDeltasAndResolvesOnDone() async throws {
    let connector = FakeConnector()
    let socket = connector.socket
    let partials = Locked<[String]>([])
    let transcriber = mistral(connector).openStreaming(mistralRequest()) { text in partials.withValue { $0.append(text) } }
    try await eventually { connector.requests.count == 1 }
    socket.server(["type": "session.created"])
    socket.server(["type": "transcription.text.delta", "text": "Ciao "])
    socket.server(["type": "transcription.text.delta", "text": "Marco"])
    try await eventually { partials.current.count == 2 }
    async let result = transcriber.finish(timeout: 1)
    try await eventually { socket.sentCount == 3 }
    #expect(socket.sent.suffix(2).map { $0["type"] as? String } == ["input_audio.flush", "input_audio.end"])
    socket.server(["type": "transcription.done", "text": "Ciao Marco.", "language": "it"])
    let final = try await result
    #expect(final == TranscriptResult(text: "Ciao Marco.", language: "it"))
    #expect(partials.current == ["Ciao ", "Ciao Marco"])
    #expect(socket.isClosed)
  }

  @Test func failsOnAnErrorEventOrAnEarlyClose() async throws {
    let a = FakeConnector()
    let ta = mistral(a).openStreaming(mistralRequest(), onText: nil)
    try await eventually { a.requests.count == 1 }
    a.socket.server(["type": "session.created"])
    async let doneA = ta.finish(timeout: 1)
    try await eventually { a.socket.sentCount >= 1 }
    a.socket.server(["type": "error", "error": ["message": "invalid model", "code": 1002] as [String: Any]])
    do {
      _ = try await doneA
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error) == "realtime: invalid model (1002)")
    }

    let b = FakeConnector()
    let tb = mistral(b).openStreaming(mistralRequest(), onText: nil)
    try await eventually { b.requests.count == 1 }
    async let doneB = tb.finish(timeout: 1)
    b.socket.serverClose(1011)
    do {
      _ = try await doneB
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error).contains("connection closed (1011)"))
    }
  }

  @Test func failsWhenTheConnectionFailsOrTimesOut() async throws {
    let refused = FakeConnector()
    refused.failure = EngineError("connection refused (HTTP 401)")
    let failing = mistral(refused).openStreaming(mistralRequest(), onText: nil)
    do {
      _ = try await failing.finish(timeout: 1)
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error).contains("401"))
    }

    let silent = FakeConnector()
    let transcriber = mistral(silent).openStreaming(mistralRequest(), onText: nil)
    do {
      _ = try await transcriber.finish(timeout: 0.02)
      Issue.record("expected a timeout")
    } catch {
      #expect(errorMessage(error).contains("timeout"))
    }
  }

  @Test func clampsTheStreamingDelay() {
    #expect(MistralTranscription.clampDelay(40) == 80)
    #expect(MistralTranscription.clampDelay(5000) == 1200)
    #expect(MistralTranscription.clampDelay(2400) == 2400)
  }

  @Test func batchRepeatsContextBiasPerTerm() async throws {
    let http = FakeHTTP()
    http.json = ["text": "ciao", "language": "it"]
    let request = TranscriptionRequest(model: "voxtral-mini-transcribe-3-0", language: "it", vocabulary: ["Acme", "Zentrix"], sampleRate: 16_000)
    let result = try await mistral(FakeConnector(), http: http).batch(wav: WAV.wrap(silence(ms: 100), sampleRate: 16_000), request, timeout: 5)
    #expect(result == TranscriptResult(text: "ciao", language: "it"))
    let call = try #require(http.requests.first)
    #expect(call.url == "https://api.mistral.ai/v1/audio/transcriptions")
    let fields = call.formFields
    #expect(fields.first { $0.0 == "model" }?.1 == "voxtral-mini-transcribe-3-0")
    #expect(fields.first { $0.0 == "file" }?.1 == "<file>")
    #expect(fields.first { $0.0 == "language" }?.1 == "it")
    #expect(fields.filter { $0.0 == "context_bias" }.map(\.1) == ["Acme", "Zentrix"])
  }
}

@Suite struct OpenAIRealtimeTests {
  @Test func opensATranscriptionSessionAndCommitsAtTheEnd() async throws {
    let connector = FakeConnector()
    let socket = connector.socket
    let request = TranscriptionRequest(model: "gpt-transcribe", language: "it", vocabulary: ["Acme", "bad<term>"], sampleRate: 24_000)
    let transcriber = openAI(connector).openStreaming(request, onText: nil)
    await transcriber.sendAudio(Data([1, 2, 3, 4]))
    try await eventually { connector.requests.count == 1 }
    let urlRequest = try #require(connector.requests.first)
    #expect(urlRequest.url?.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

    socket.server(["type": "session.created"])
    try await eventually { socket.sentCount == 2 }
    let session = try #require(socket.sent[0]["session"] as? [String: Any])
    #expect(session["type"] as? String == "transcription")
    let input = try #require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
    #expect((input["format"] as? [String: Any])?["type"] as? String == "audio/pcm")
    #expect((input["format"] as? [String: Any])?["rate"] as? Int == 24_000)
    #expect(input["turn_detection"] is NSNull)
    let transcription = try #require(input["transcription"] as? [String: Any])
    #expect(transcription["model"] as? String == "gpt-transcribe")
    #expect(transcription["language"] as? String == "it")
    #expect(transcription["keywords"] as? [String] == ["Acme"])
    #expect(socket.sent[1]["type"] as? String == "input_audio_buffer.append")

    async let result = transcriber.finish(timeout: 1)
    try await eventually { socket.sentCount == 3 }
    #expect(socket.sent[2]["type"] as? String == "input_audio_buffer.commit")
    socket.server(["type": "input_audio_buffer.committed", "item_id": "item_1"])
    socket.server(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_1", "transcript": "Ciao Acme."])
    let final = try await result
    #expect(final == TranscriptResult(text: "Ciao Acme."))
  }

  @Test func reportsAFailedTranscription() async throws {
    let connector = FakeConnector()
    let transcriber = openAI(connector).openStreaming(
      TranscriptionRequest(model: "gpt-transcribe", language: nil, vocabulary: [], sampleRate: 24_000), onText: nil)
    try await eventually { connector.requests.count == 1 }
    connector.socket.server(["type": "session.created"])
    async let result = transcriber.finish(timeout: 1)
    try await eventually { connector.socket.sentCount == 2 }
    connector.socket.server(["type": "conversation.item.input_audio_transcription.failed", "error": ["message": "audio too short"]])
    do {
      _ = try await result
      Issue.record("expected an error")
    } catch {
      #expect(errorMessage(error) == "realtime: audio too short")
    }
  }

  @Test func batchSendsKeywordsForGPTTranscribeAndAPromptOtherwise() async throws {
    let http = FakeHTTP()
    http.json = ["text": "ciao"]
    let service = openAI(FakeConnector(), http: http)
    let wav = WAV.wrap(silence(ms: 100, sampleRate: 24_000), sampleRate: 24_000)
    _ = try await service.batch(wav: wav, TranscriptionRequest(model: "gpt-transcribe", language: "it", vocabulary: ["Acme", "Zentrix"], sampleRate: 24_000), timeout: 5)
    let fields = try #require(http.requests.first).formFields
    #expect(fields.filter { $0.0 == "keywords[]" }.map(\.1) == ["Acme", "Zentrix"])
    #expect(fields.first { $0.0 == "prompt" } == nil)

    _ = try await service.batch(wav: wav, TranscriptionRequest(model: "gpt-4o-mini-transcribe", language: nil, vocabulary: ["Acme"], sampleRate: 24_000), timeout: 5)
    let other = try #require(http.requests.last).formFields
    #expect(other.first { $0.0 == "keywords[]" } == nil)
    #expect(other.first { $0.0 == "prompt" }?.1 == "Vocabolario: Acme.")
  }
}

private func elevenLabs(_ connector: FakeConnector, http: FakeHTTP = FakeHTTP()) -> ElevenLabsTranscription {
  ElevenLabsTranscription(endpoint: .direct(.elevenlabs, apiKey: "secret"), http: http, connector: connector)
}

@Suite struct ElevenLabsTests {
  @Test func realtimeCarriesTheSettingsInTheURLAndCommitsAtTheEnd() async throws {
    let connector = FakeConnector()
    let socket = connector.socket
    let request = TranscriptionRequest(
      model: "scribe_v2_realtime", language: "it", vocabulary: ["Zentrix", "Acme [beta]", "A very long product name indeed"], sampleRate: 16_000)
    let partials = Locked<[String]>([])
    let transcriber = elevenLabs(connector).openStreaming(request) { text in partials.withValue { $0.append(text) } }
    await transcriber.sendAudio(Data([1, 2, 3, 4]))
    try await eventually { connector.requests.count == 1 }
    let opened = try #require(connector.requests.first)
    #expect(opened.value(forHTTPHeaderField: "xi-api-key") == "secret")
    #expect(opened.value(forHTTPHeaderField: "Authorization") == nil)
    let query = URLComponents(url: try #require(opened.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(opened.url?.path == "/v1/speech-to-text/realtime")
    #expect(query.first { $0.name == "model_id" }?.value == "scribe_v2_realtime")
    #expect(query.first { $0.name == "audio_format" }?.value == "pcm_16000")
    #expect(query.first { $0.name == "commit_strategy" }?.value == "manual")
    #expect(query.first { $0.name == "language_code" }?.value == "it")
    // Brackets go, and realtime keyterms are at most 20 characters.
    #expect(query.filter { $0.name == "keyterms" }.map(\.value) == ["Zentrix", "Acme beta"])
    // No session.update: the audio waits for session_started, then goes as it is.
    #expect(socket.sentCount == 0)
    socket.server(["message_type": "session_started", "session_id": "s1"])
    try await eventually { socket.sentCount == 1 }
    #expect(socket.sent[0]["message_type"] as? String == "input_audio_chunk")
    #expect(socket.sent[0]["audio_base_64"] as? String == "AQIDBA==")
    #expect(socket.sent[0]["commit"] as? Bool == false)
    #expect(socket.sent[0]["sample_rate"] as? Int == 16_000)

    // A segment can close on its own before the end; the one after the commit is the answer.
    socket.server(["message_type": "partial_transcript", "text": "Ciao"])
    socket.server(["message_type": "committed_transcript", "text": "Ciao Marco."])
    try await eventually { partials.current == ["Ciao Marco."] }
    async let result = transcriber.finish(timeout: 1)
    try await eventually { socket.sentCount == 2 }
    #expect(socket.sent[1]["commit"] as? Bool == true)
    socket.server(["message_type": "committed_transcript", "text": "Ci vediamo domani."])
    #expect(try await result == TranscriptResult(text: "Ciao Marco. Ci vediamo domani."))
    #expect(socket.isClosed)
  }

  @Test func realtimeErrorsFailTheSession() async throws {
    let connector = FakeConnector()
    let transcriber = elevenLabs(connector).openStreaming(
      TranscriptionRequest(model: "scribe_v2_realtime", language: nil, vocabulary: [], sampleRate: 16_000), onText: nil)
    try await eventually { connector.requests.count == 1 }
    connector.socket.server(["message_type": "quota_exceeded", "error": "No credits left"])
    await #expect(throws: (any Error).self) { try await transcriber.finish(timeout: 1) }
  }

  @Test func batchSendsRawPCMAndAtMostAHundredKeyterms() async throws {
    let http = FakeHTTP()
    http.json = ["text": "ciao", "language_code": "ita"]
    let terms = (1...130).map { "Term\($0)" } + ["Bad{term}"]
    let request = TranscriptionRequest(model: "scribe_v2", language: "it", vocabulary: terms, sampleRate: 16_000)
    let result = try await elevenLabs(FakeConnector(), http: http).batch(wav: WAV.wrap(silence(ms: 100), sampleRate: 16_000), request, timeout: 5)
    #expect(result == TranscriptResult(text: "ciao", language: "it"))
    let call = try #require(http.requests.first)
    #expect(call.url == "https://api.elevenlabs.io/v1/speech-to-text")
    #expect(call.headers["xi-api-key"] == "secret")
    #expect(call.headers["Authorization"] == nil)
    let fields = call.formFields
    #expect(fields.first { $0.0 == "model_id" }?.1 == "scribe_v2")
    #expect(fields.first { $0.0 == "file_format" }?.1 == "pcm_s16le_16")
    #expect(fields.first { $0.0 == "file" }?.1 == "<file>")
    #expect(fields.first { $0.0 == "language_code" }?.1 == "it")
    // Beyond 100 keyterms each request is billed at least 20 seconds.
    #expect(fields.filter { $0.0 == "keyterms" }.count == 100)
  }

  @Test func elevenLabsIsTranscriptionOnly() {
    #expect(!ProviderID.elevenlabs.supportsChat)
    #expect(ProviderID.chatProviders == [.mistral, .openai])
    let pipeline = PipelineSettings.defaults(.elevenlabs)
    #expect(pipeline.transcription.provider == .elevenlabs)
    #expect(pipeline.transcription.mode == .hybrid)
    #expect(pipeline.cleanup.provider == .mistral)
    #expect(pipeline.scribe.provider == .mistral)
    #expect(pipeline.providers == [.elevenlabs, .mistral])
  }

  @Test func elevenLabsKeysAreRedactedFromLogs() {
    #expect(!TextTools.redactSecrets("failed with sk_0123456789abcdef0123456789abcdef").contains("0123456789abcdef"))
  }
}
