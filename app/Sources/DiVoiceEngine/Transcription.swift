import Foundation

public struct TranscriptResult: Sendable, Equatable {
  public var text: String
  public var language: String?

  public init(text: String, language: String? = nil) {
    self.text = text
    self.language = language
  }
}

/// A streaming transcription that receives audio while the user speaks.
public protocol StreamingTranscriber: Sendable {
  func sendAudio(_ chunk: Data) async
  /// Ends the audio and waits for the final transcript.
  func finish(timeout: Double) async throws -> TranscriptResult
  func abort() async
  /// Milliseconds from opening to the session being configured, if it happened.
  var connectMs: Double? { get async }
}

public struct TranscriptionRequest: Sendable {
  public var model: String
  public var language: String?
  /// Terms to bias the recognition towards (the dictionary).
  public var vocabulary: [String]
  /// Mistral realtime streaming delay.
  public var delayMs: Int
  public var sampleRate: Int
  /// The text already in the field (ElevenLabs realtime takes it as `previous_text`).
  public var previousText: String?

  public init(model: String, language: String?, vocabulary: [String], delayMs: Int = 480, sampleRate: Int, previousText: String? = nil) {
    self.model = model
    self.language = language
    self.vocabulary = vocabulary
    self.delayMs = delayMs
    self.sampleRate = sampleRate
    self.previousText = previousText
  }
}

public protocol TranscriptionService: Sendable {
  var provider: ProviderID { get }
  func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber
  func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult
  /// How long to wait for the streaming transcript after the end of the audio.
  func finishTimeout(audioMs: Int) -> Double
}

// MARK: - Realtime session shared by the providers

/// What a provider's realtime protocol means for the session.
enum RealtimeEvent: Sendable {
  case ready
  case delta(String)
  /// A final segment (ElevenLabs): after the end of the audio it's the last one.
  case committed(String)
  case done(text: String?, language: String?)
  case failure(String)
  case ignore
}

/// The provider-specific parts of a realtime transcription socket.
struct RealtimeDialect: Sendable {
  var request: URLRequest
  /// `session.update` sent once the server says the session exists; nil when the URL carries the settings.
  var configure: String?
  var append: @Sendable (Data) -> String
  var finish: [String]
  var parse: @Sendable (String) -> RealtimeEvent
}

/// A realtime transcription over WebSocket. Audio sent before the session is configured
/// waits in a queue: session parameters lock at the first audio chunk.
actor RealtimeSession: StreamingTranscriber {
  private let dialect: RealtimeDialect
  private let connector: WebSocketConnector
  private let now: EngineClock
  private let onText: (@Sendable (String) -> Void)?
  private let startedAt: Double
  private let done = OneShot<TranscriptResult>()
  private var connection: WebSocketConnection?
  private var configured = false
  private var finished = false
  private var pending: [String] = []
  private var text = ""
  /// Segments already final, in order (ElevenLabs).
  private var committed: [String] = []
  private(set) var connectMs: Double?

  static func open(
    _ dialect: RealtimeDialect, connector: WebSocketConnector, now: @escaping EngineClock, onText: (@Sendable (String) -> Void)?
  ) -> RealtimeSession {
    let session = RealtimeSession(dialect: dialect, connector: connector, now: now, onText: onText)
    Task { await session.run() }
    return session
  }

  private init(dialect: RealtimeDialect, connector: WebSocketConnector, now: @escaping EngineClock, onText: (@Sendable (String) -> Void)?) {
    self.dialect = dialect
    self.connector = connector
    self.now = now
    self.onText = onText
    self.startedAt = now()
  }

  private func run() async {
    let connection: WebSocketConnection
    do {
      connection = try await connector.connect(dialect.request)
    } catch {
      fail("realtime: \(errorMessage(error))")
      return
    }
    if done.isFulfilled {
      connection.close()
      return
    }
    self.connection = connection
    while !done.isFulfilled {
      do {
        handle(try await connection.receive())
      } catch {
        fail("realtime: \(errorMessage(error))")
        return
      }
    }
  }

  private func handle(_ message: String) {
    switch dialect.parse(message) {
    case .ready:
      configure()
    case .delta(let delta):
      guard !delta.isEmpty else { return }
      text += delta
      onText?(text)
    case .committed(let segment):
      let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
      if !segment.isEmpty {
        committed.append(segment)
        onText?(committed.joined(separator: " "))
      }
      // Before the end of the audio a segment can close on its own; the one after it is the answer.
      if finished, done.fulfill(.success(TranscriptResult(text: committed.joined(separator: " ")))) { connection?.close() }
    case .done(let final, let language):
      if done.fulfill(.success(TranscriptResult(text: final ?? text, language: language))) { connection?.close() }
    case .failure(let message):
      fail("realtime: \(message)")
    case .ignore:
      break
    }
  }

  private func configure() {
    guard let connection, !configured, !done.isFulfilled else { return }
    if let configure = dialect.configure { connection.send(configure) }
    configured = true
    connectMs = now() - startedAt
    for message in pending { connection.send(message) }
    pending = []
  }

  private func sendOrQueue(_ message: String) {
    if configured, let connection { connection.send(message) } else { pending.append(message) }
  }

  func sendAudio(_ chunk: Data) {
    guard !done.isFulfilled, !finished, !chunk.isEmpty else { return }
    sendOrQueue(dialect.append(chunk))
  }

  func finish(timeout: Double) async throws -> TranscriptResult {
    if !done.isFulfilled, !finished {
      finished = true
      for message in dialect.finish { sendOrQueue(message) }
    }
    let done = self.done
    do {
      return try await withTimeout(timeout, "realtime") { try await done.value() }
    } catch {
      abort()
      throw error
    }
  }

  func abort() {
    fail("realtime: session cancelled")
  }

  private func fail(_ message: String) {
    if done.fulfill(.failure(EngineError(message))) { connection?.close() }
  }
}

// MARK: - Mistral

/// Voxtral: realtime over WebSocket, batch with a multipart upload. The vocabulary goes in `context_bias`.
public struct MistralTranscription: TranscriptionService {
  public let provider = ProviderID.mistral
  private let endpoint: ProviderEndpoint
  private let http: HTTPClient
  private let connector: WebSocketConnector
  private let now: EngineClock

  public init(endpoint: ProviderEndpoint, http: HTTPClient, connector: WebSocketConnector, now: @escaping EngineClock = EngineClocks.monotonic) {
    self.endpoint = endpoint
    self.http = http
    self.connector = connector
    self.now = now
  }

  /// Accepted delays: 80–1200 ms, or 2400.
  static func clampDelay(_ ms: Int) -> Int {
    ms == 2400 ? ms : min(1200, max(80, ms))
  }

  func dialect(_ request: TranscriptionRequest) -> RealtimeDialect {
    let url = endpoint.webSocketURL("/v1/audio/transcriptions/realtime", query: [URLQueryItem(name: "model", value: request.model)])
    var session: [String: Any] = [
      "audio_format": ["encoding": "pcm_s16le", "sample_rate": request.sampleRate],
      "target_streaming_delay_ms": Self.clampDelay(request.delayMs),
    ]
    if !request.vocabulary.isEmpty { session["context_bias"] = request.vocabulary }
    if let language = request.language { session["language"] = language }
    return RealtimeDialect(
      request: endpoint.request(url),
      configure: JSON.string(["type": "session.update", "session": session]),
      append: { JSON.string(["type": "input_audio.append", "audio": $0.base64EncodedString()]) },
      finish: [JSON.string(["type": "input_audio.flush"]), JSON.string(["type": "input_audio.end"])],
      parse: { raw in
        guard let message = JSON.object(raw), let type = message["type"] as? String else { return .ignore }
        switch type {
        case "session.created": return .ready
        case "transcription.text.delta": return .delta(message["text"] as? String ?? "")
        case "transcription.done": return .done(text: message["text"] as? String, language: message["language"] as? String)
        case "error": return .failure(JSON.describeError(message["error"]))
        default: return .ignore
        }
      })
  }

  public func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber {
    RealtimeSession.open(dialect(request), connector: connector, now: now, onText: onText)
  }

  public func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult {
    var form = MultipartForm()
    form.field("model", request.model)
    form.file("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
    if let language = request.language { form.field("language", language) }
    // context_bias is a list: the multipart field repeats once per term.
    for term in request.vocabulary { form.field("context_bias", term) }
    return try await postBatch(form, timeout: timeout)
  }

  private func postBatch(_ form: MultipartForm, timeout: Double) async throws -> TranscriptResult {
    var urlRequest = endpoint.request(endpoint.url("/v1/audio/transcriptions"), method: "POST", timeout: timeout)
    urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = form.finished()
    let (data, response) = try await http.data(urlRequest)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPStatusError(label: "batch", status: response.statusCode, body: String(decoding: data.prefix(2048), as: UTF8.self))
    }
    let json = JSON.object(data)
    return TranscriptResult(text: json?["text"] as? String ?? "", language: json?["language"] as? String)
  }

  public func finishTimeout(audioMs: Int) -> Double { 4 }
}

// MARK: - OpenAI

/// OpenAI transcription. Realtime uses a transcription session without voice activity
/// detection: audio streams while speaking and one commit at release asks for the transcript.
public struct OpenAITranscription: TranscriptionService {
  public let provider = ProviderID.openai
  private let endpoint: ProviderEndpoint
  private let http: HTTPClient
  private let connector: WebSocketConnector
  private let now: EngineClock

  public init(endpoint: ProviderEndpoint, http: HTTPClient, connector: WebSocketConnector, now: @escaping EngineClock = EngineClocks.monotonic) {
    self.endpoint = endpoint
    self.http = http
    self.connector = connector
    self.now = now
  }

  /// Keywords must be single lines without angle brackets.
  static func keywords(_ terms: [String]) -> [String] {
    terms.filter { !$0.contains(where: { "<>\r\n".contains($0) }) }
  }

  static func vocabularyPrompt(_ terms: [String]) -> String? {
    terms.isEmpty ? nil : "Vocabolario: \(terms.joined(separator: ", "))."
  }

  func dialect(_ request: TranscriptionRequest) -> RealtimeDialect {
    let url = endpoint.webSocketURL("/v1/realtime", query: [URLQueryItem(name: "intent", value: "transcription")])
    let caps = ModelCatalog.transcriptionCapabilities(.openai, request.model)
    var transcription: [String: Any] = ["model": request.model]
    if let language = request.language { transcription["language"] = language }
    if caps.keywords {
      let keywords = Self.keywords(request.vocabulary)
      if !keywords.isEmpty { transcription["keywords"] = keywords }
    } else if let prompt = Self.vocabularyPrompt(request.vocabulary) {
      transcription["prompt"] = prompt
    }
    let session: [String: Any] = [
      "type": "transcription",
      "audio": [
        "input": [
          "format": ["type": "audio/pcm", "rate": request.sampleRate],
          "transcription": transcription,
          "turn_detection": NSNull(),
        ] as [String: Any]
      ],
    ]
    return RealtimeDialect(
      request: endpoint.request(url),
      configure: JSON.string(["type": "session.update", "session": session]),
      append: { JSON.string(["type": "input_audio_buffer.append", "audio": $0.base64EncodedString()]) },
      finish: [JSON.string(["type": "input_audio_buffer.commit"])],
      parse: { raw in
        guard let message = JSON.object(raw), let type = message["type"] as? String else { return .ignore }
        switch type {
        case "session.created", "transcription_session.created": return .ready
        case "conversation.item.input_audio_transcription.delta": return .delta(message["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
          let languages = message["languages"] as? [String]
          return .done(text: message["transcript"] as? String, language: languages?.first ?? message["language"] as? String)
        case "conversation.item.input_audio_transcription.failed": return .failure(JSON.describeError(message["error"]))
        case "error": return .failure(JSON.describeError(message["error"]))
        default: return .ignore
        }
      })
  }

  public func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber {
    RealtimeSession.open(dialect(request), connector: connector, now: now, onText: onText)
  }

  public func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult {
    var form = MultipartForm()
    form.field("model", request.model)
    form.file("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
    if let language = request.language { form.field("language", language) }
    if ModelCatalog.transcriptionCapabilities(.openai, request.model).keywords {
      for keyword in Self.keywords(request.vocabulary) { form.field("keywords[]", keyword) }
    } else if let prompt = Self.vocabularyPrompt(request.vocabulary) {
      form.field("prompt", prompt)
    }
    var urlRequest = endpoint.request(endpoint.url("/v1/audio/transcriptions"), method: "POST", timeout: timeout)
    urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = form.finished()
    let (data, response) = try await http.data(urlRequest)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPStatusError(label: "batch", status: response.statusCode, body: String(decoding: data.prefix(2048), as: UTF8.self))
    }
    let json = JSON.object(data)
    return TranscriptResult(text: json?["text"] as? String ?? "", language: json?["language"] as? String)
  }

  /// The transcription starts at the commit, so long recordings need more time.
  public func finishTimeout(audioMs: Int) -> Double { 6 + Double(audioMs) / 20_000 }
}

// MARK: - ElevenLabs

/// ElevenLabs Scribe (v3 by default, v2 alike): batch with a multipart upload of raw PCM, realtime over WebSocket with
/// the settings in the URL and a manual commit at release. The vocabulary goes in `keyterms`.
public struct ElevenLabsTranscription: TranscriptionService {
  public let provider = ProviderID.elevenlabs
  private let endpoint: ProviderEndpoint
  private let http: HTTPClient
  private let connector: WebSocketConnector
  private let now: EngineClock

  public init(endpoint: ProviderEndpoint, http: HTTPClient, connector: WebSocketConnector, now: @escaping EngineClock = EngineClocks.monotonic) {
    self.endpoint = endpoint
    self.http = http
    self.connector = connector
    self.now = now
  }

  /// Keyterms the API accepts: no `<>{}[]\`, at most `maxLength` characters and 5 words, and at
  /// most `limit` of them. Batch: beyond 100 terms each request is billed at least 20 seconds.
  static func keyterms(_ terms: [String], limit: Int, maxLength: Int) -> [String] {
    var seen = Set<String>()
    return terms.compactMap { term -> String? in
      let clean = term.filter { !"<>{}[]\\".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty, clean.count <= maxLength, clean.split(separator: " ").count <= 5 else { return nil }
      return seen.insert(clean.lowercased()).inserted ? clean : nil
    }
    .prefix(limit).map { $0 }
  }

  func dialect(_ request: TranscriptionRequest) -> RealtimeDialect {
    var query = [
      URLQueryItem(name: "model_id", value: request.model),
      URLQueryItem(name: "audio_format", value: "pcm_\(request.sampleRate)"),
      URLQueryItem(name: "commit_strategy", value: "manual"),
    ]
    if let language = request.language { query.append(URLQueryItem(name: "language_code", value: language)) }
    for term in Self.keyterms(request.vocabulary, limit: 50, maxLength: 20) { query.append(URLQueryItem(name: "keyterms", value: term)) }
    let url = endpoint.webSocketURL("/v1/speech-to-text/realtime", query: query)
    let rate = request.sampleRate
    // previous_text is accepted only on the first chunk.
    let previous = Locked<String?>(request.previousText.map { String($0.suffix(1_000)) })
    @Sendable func chunk(_ audio: Data, commit: Bool) -> [String: Any] {
      ["message_type": "input_audio_chunk", "audio_base_64": audio.base64EncodedString(), "commit": commit, "sample_rate": rate]
    }
    return RealtimeDialect(
      request: endpoint.request(url),
      configure: nil,
      append: { audio in
        var message = chunk(audio, commit: false)
        let text = previous.withValue { value -> String? in
          defer { value = nil }
          return value
        }
        if let text { message["previous_text"] = text }
        return JSON.string(message)
      },
      finish: [JSON.string(chunk(Data(), commit: true))],
      parse: { raw in
        guard let message = JSON.object(raw), let type = message["message_type"] as? String else { return .ignore }
        switch type {
        case "session_started": return .ready
        case "committed_transcript", "committed_transcript_with_timestamps": return .committed(message["text"] as? String ?? "")
        case "partial_transcript", "warning": return .ignore
        default:
          // Errors have their own types (auth_error, quota_exceeded, input_error...).
          guard type.hasSuffix("error") || type.hasSuffix("exceeded") || type.hasSuffix("limited") || type.hasSuffix("exhausted")
            || type.hasSuffix("overflow") || type.hasSuffix("throttled") || type.hasSuffix("terms") || type == "insufficient_audio_activity"
            || type == "invalid_request"
          else { return .ignore }
          let detail = message["error"] as? String ?? message["message"] as? String ?? ""
          return .failure(detail.isEmpty ? type : "\(type): \(detail)")
        }
      })
  }

  public func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber {
    RealtimeSession.open(dialect(request), connector: connector, now: now, onText: onText)
  }

  public func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult {
    var form = MultipartForm()
    form.field("model_id", request.model)
    // Raw 16 kHz PCM is faster for ElevenLabs than a WAV file: the header goes.
    if request.sampleRate == 16_000, wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8) {
      form.field("file_format", "pcm_s16le_16")
      form.file("file", filename: "audio.pcm", contentType: "application/octet-stream", data: wav.dropFirst(44))
    } else {
      form.file("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
    }
    if let language = request.language { form.field("language_code", language) }
    form.field("tag_audio_events", "false")
    for term in Self.keyterms(request.vocabulary, limit: 100, maxLength: 50) { form.field("keyterms", term) }
    var urlRequest = endpoint.request(endpoint.url("/v1/speech-to-text"), method: "POST", timeout: timeout)
    urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = form.finished()
    let (data, response) = try await http.data(urlRequest)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPStatusError(label: "batch", status: response.statusCode, body: String(decoding: data.prefix(2048), as: UTF8.self))
    }
    let json = JSON.object(data)
    let language = (json?["language_code"] as? String).map { String($0.prefix(2)) }
    return TranscriptResult(text: json?["text"] as? String ?? "", language: language)
  }

  public func finishTimeout(audioMs: Int) -> Double { 4 + Double(audioMs) / 30_000 }
}

/// Clients for a provider, from its endpoint (direct API or relay).
public enum ProviderClients {
  public static func transcription(
    _ provider: ProviderID, endpoint: ProviderEndpoint, http: HTTPClient, connector: WebSocketConnector,
    now: @escaping EngineClock = EngineClocks.monotonic
  ) -> TranscriptionService {
    switch provider {
    case .mistral: MistralTranscription(endpoint: endpoint, http: http, connector: connector, now: now)
    // An OpenAI-compatible server is never picked for transcription; if it were, OpenAI's API is the closest.
    case .openai, .compatible: OpenAITranscription(endpoint: endpoint, http: http, connector: connector, now: now)
    case .elevenlabs: ElevenLabsTranscription(endpoint: endpoint, http: http, connector: connector, now: now)
    }
  }

  public static func chat(
    _ provider: ProviderID, endpoint: ProviderEndpoint, http: HTTPClient, now: @escaping EngineClock = EngineClocks.monotonic
  ) -> ChatService {
    ChatCompletionsClient(provider: provider, endpoint: endpoint, http: http, now: now)
  }
}
