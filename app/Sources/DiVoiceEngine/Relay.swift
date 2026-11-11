import Foundation

/// What the organization's server sends back when the audio ends.
public struct RelayTranscript: Sendable, Equatable {
  public var text: String
  /// realtime, batch, batch_fallback, realtime_fallback or none: decided by the server.
  public var path: String
  public var model: String?
  public var language: String?
  public var warning: String?
  public var timings: [String: Double]
}

/// Counts of a finished dictation for the team statistics. Never text.
public struct RelayStats: Codable, Sendable, Equatable {
  public var mode: String
  public var category: String
  public var words: Int
  /// The member's local day, YYYY-MM-DD.
  public var localDay: String
  public var typingWPM: Int
  public var cleanupPath: String
  public var timings: [String: Double]

  public init(mode: String, category: String, words: Int, localDay: String, typingWPM: Int, cleanupPath: String, timings: [String: Double]) {
    self.mode = mode
    self.category = category
    self.words = words
    self.localDay = localDay
    self.typingWPM = typingWPM
    self.cleanupPath = cleanupPath
    self.timings = timings
  }
}

/// One dictation through the organization's server (diServer's src/relay.ts), on one WebSocket:
/// the audio goes up while the user speaks, the transcript comes back at the end, then the
/// cleanup or Scribe request built here goes up and its event stream comes back.
/// The server holds the provider keys and models; this side never sees them.
public actor RelayConnection {
  public enum Purpose: String, Sendable {
    case dictation
    /// Verify in the settings: not counted in the statistics.
    case verify
  }

  private enum Outgoing {
    case text(String)
    case binary(Data)
  }

  private let request: URLRequest
  private let connector: WebSocketConnector
  private let now: EngineClock
  private let startedAt: Double
  private var connection: WebSocketConnection?
  private var outbox: [Outgoing] = []
  private var onText: (@Sendable (String) -> Void)?
  private let transcript = OneShot<RelayTranscript>()
  private var chats: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
  private var chatLabels: [Int: String] = [:]
  private var nextChat = 1
  private var started = false
  private var finished = false
  private var closed = false
  private var failure: String?
  public private(set) var connectMs: Double?
  /// The server's transcript, with its path and timings (for the bench and the logs).
  public private(set) var transcriptResult: RelayTranscript?
  /// The server's timings of the last chat: key lookup, provider's headers and first line, total.
  public private(set) var lastChatTimings: [String: Double] = [:]

  /// Connects right away: the connection is ready by the time the user has said a few words.
  public static func open(server: URL, token: String, connector: WebSocketConnector, now: @escaping EngineClock = EngineClocks.monotonic)
    -> RelayConnection
  {
    let relay = RelayConnection(server: server, token: token, connector: connector, now: now)
    Task { await relay.run() }
    return relay
  }

  private init(server: URL, token: String, connector: WebSocketConnector, now: @escaping EngineClock) {
    let endpoint = ProviderEndpoint(baseURL: server, apiKey: token)
    request = endpoint.request(endpoint.webSocketURL("/v2/relay"), timeout: 15)
    self.connector = connector
    self.now = now
    startedAt = now()
  }

  private func run() async {
    let connection: WebSocketConnection
    do {
      connection = try await connector.connect(request)
    } catch {
      fail("server: \(errorMessage(error))")
      return
    }
    if closed {
      connection.close()
      return
    }
    self.connection = connection
    for message in outbox { deliver(message, on: connection) }
    outbox = []
    while !closed {
      do {
        handle(try await connection.receive())
      } catch {
        if !closed { fail("server: \(errorMessage(error))") }
        return
      }
    }
  }

  private func deliver(_ message: Outgoing, on connection: WebSocketConnection) {
    switch message {
    case .text(let text): connection.send(text)
    case .binary(let data): connection.send(data: data)
    }
  }

  private func send(_ message: Outgoing) {
    guard !closed else { return }
    if let connection { deliver(message, on: connection) } else { outbox.append(message) }
  }

  private func handle(_ text: String) {
    guard let message = JSON.object(text), let type = message["type"] as? String else { return }
    switch type {
    case "ready":
      if connectMs == nil { connectMs = now() - startedAt }
    case "partial":
      if let partial = message["text"] as? String { onText?(partial) }
    case "transcript":
      let result = RelayTranscript(
        text: message["text"] as? String ?? "",
        path: message["path"] as? String ?? "none",
        model: message["model"] as? String,
        language: message["language"] as? String,
        warning: message["warning"] as? String,
        timings: Self.numbers(message["timings"]))
      transcriptResult = result
      transcript.fulfill(.success(result))
    case "chat.line":
      if let id = message["id"] as? Int, let line = message["line"] as? String { chats[id]?.yield(line) }
    case "chat.done":
      lastChatTimings = Self.numbers(message["timings"])
      if let id = message["id"] as? Int { chats.removeValue(forKey: id)?.finish() }
    case "chat.error":
      lastChatTimings = Self.numbers(message["timings"])
      guard let id = message["id"] as? Int else { return }
      let status = message["status"] as? Int ?? 502
      let body = message["body"] as? String ?? ""
      chats.removeValue(forKey: id)?.finish(throwing: HTTPStatusError(label: chatLabels[id] ?? "chat", status: status, body: body))
    case "error":
      fail(message["message"] as? String ?? "server error")
    default:
      break
    }
  }

  private static func numbers(_ value: Any?) -> [String: Double] {
    (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
  }

  /// Opens the dictation. `sampleRate` nil: a Verify of a chat model alone, without audio.
  public func start(
    sessionId: String, sampleRate: Int?, language: String?, vocabulary: [String], purpose: Purpose,
    onText: (@Sendable (String) -> Void)? = nil
  ) {
    guard !started else { return }
    started = true
    self.onText = onText
    var message: [String: Any] = ["type": "start", "sessionId": sessionId, "vocabulary": vocabulary, "purpose": purpose.rawValue]
    if let sampleRate { message["sampleRate"] = sampleRate }
    if let language { message["language"] = language }
    send(.text(JSON.string(message)))
  }

  public func sendAudio(_ chunk: Data) {
    guard started, !finished, !chunk.isEmpty else { return }
    send(.binary(chunk))
  }

  /// Ends the audio and waits for the server's transcript.
  public func finish(timeout: Double) async throws -> RelayTranscript {
    if !finished {
      finished = true
      send(.text(#"{"type":"finish"}"#))
    }
    if let failure { throw EngineError(failure) }
    let transcript = self.transcript
    return try await withTimeout(timeout, "server") { try await transcript.value() }
  }

  /// Sends a chat request built by the app and returns the provider's event stream, line by line.
  public func chat(role: String, body: Data, label: String) -> AsyncThrowingStream<String, Error> {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    if let failure {
      continuation.finish(throwing: EngineError(failure))
      return stream
    }
    let id = nextChat
    nextChat += 1
    chats[id] = continuation
    chatLabels[id] = label
    send(.text(#"{"type":"chat","id":\#(id),"role":"\#(role)","body":"# + String(decoding: body, as: UTF8.self) + "}"))
    return stream
  }

  /// Sends the statistics and waits until they're written: closing right after a plain send can
  /// drop them, and the server then records the dictation without its day, so the team's
  /// statistics leave it out.
  public func sendStats(_ stats: RelayStats) async {
    guard let data = try? JSONEncoder().encode(stats), var object = JSON.object(data) else { return }
    object["type"] = "stats"
    let text = JSON.string(object)
    guard !closed else { return }
    guard let connection else {
      outbox.append(.text(text))
      return
    }
    // A stuck connection doesn't keep the session open: two seconds at most.
    _ = try? await withTimeout(2, "stats") { await connection.sendAndWait(text) }
  }

  /// Ends the session: the server records the statistics when the connection closes.
  public func close() {
    guard !closed else { return }
    closed = true
    connection?.close()
    if !transcript.isFulfilled { transcript.fulfill(.failure(EngineError("server: session closed"))) }
    for continuation in chats.values { continuation.finish(throwing: EngineError("server: session closed")) }
    chats = [:]
  }

  /// Stops a dictation the user cancelled.
  public func cancel() {
    if let connection, !closed { connection.send(#"{"type":"cancel"}"#) }
    close()
  }

  private func fail(_ message: String) {
    guard failure == nil else { return }
    failure = message
    transcript.fulfill(.failure(EngineError(message)))
    for continuation in chats.values { continuation.finish(throwing: EngineError(message)) }
    chats = [:]
    closed = true
    connection?.close()
  }
}

// MARK: - The engine's services on a relay

/// Transcription through the organization's server. The server runs the hybrid logic (batch
/// on its copy of the audio, streaming as the fallback), so this side only streams.
public struct RelayTranscription: TranscriptionService {
  public let provider: ProviderID
  private let relay: RelayConnection
  private let sessionId: String
  private let purpose: RelayConnection.Purpose

  public init(provider: ProviderID, relay: RelayConnection, sessionId: String, purpose: RelayConnection.Purpose = .dictation) {
    self.provider = provider
    self.relay = relay
    self.sessionId = sessionId
    self.purpose = purpose
  }

  public func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber {
    let relay = self.relay
    let sessionId = self.sessionId
    let purpose = self.purpose
    // Audio waits for this: the start message must go out first.
    let started = Task {
      await relay.start(
        sessionId: sessionId, sampleRate: request.sampleRate, language: request.language, vocabulary: request.vocabulary,
        purpose: purpose, onText: onText)
    }
    return RelayStreamingTranscriber(relay: relay, started: started)
  }

  public func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult {
    throw EngineError("nothing was transcribed")
  }

  /// The server may run a batch transcription after the streaming one fails.
  public func finishTimeout(audioMs: Int) -> Double { 30 + Double(audioMs) / 4_000 }
}

struct RelayStreamingTranscriber: StreamingTranscriber {
  let relay: RelayConnection
  let started: Task<Void, Never>

  func sendAudio(_ chunk: Data) async {
    await started.value
    await relay.sendAudio(chunk)
  }

  func finish(timeout: Double) async throws -> TranscriptResult {
    await started.value
    let transcript = try await relay.finish(timeout: timeout)
    return TranscriptResult(text: transcript.text, language: transcript.language)
  }

  func abort() async {
    await relay.cancel()
  }

  var connectMs: Double? {
    get async { await relay.connectMs }
  }
}

/// Chat through the organization's server: the request is the one this app would send to the
/// provider; the server swaps in the organization's key and model.
public struct RelayHTTPClient: HTTPClient {
  private let relay: RelayConnection
  private let role: String

  public init(relay: RelayConnection, role: String) {
    self.relay = relay
    self.role = role
  }

  public func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw EngineError("not available through the organization's server")
  }

  public func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws {
    guard let body = request.httpBody else { throw EngineError("\(label): empty request") }
    for try await line in await relay.chat(role: role, body: body, label: label) {
      try onLine(line)
    }
  }
}

public enum RelayServices {
  /// The pipeline as the app runs it with an organization: the models are the organization's
  /// (so requests are built for them), the transcription streams to the server, which decides
  /// between streaming and batch itself.
  public static func clientPipeline(_ organization: PipelineSettings) -> PipelineSettings {
    var pipeline = organization
    pipeline.transcription.mode = .realtime
    return pipeline
  }

  public static func services(
    _ pipeline: PipelineSettings, relay: RelayConnection, server: URL, sessionId: String, purpose: RelayConnection.Purpose = .dictation
  ) -> DictationServices {
    let endpoint = ProviderEndpoint(baseURL: server, apiKey: "")
    return DictationServices(
      transcription: RelayTranscription(provider: pipeline.transcription.provider, relay: relay, sessionId: sessionId, purpose: purpose),
      cleanup: ChatCompletionsClient(provider: pipeline.cleanup.provider, endpoint: endpoint, http: RelayHTTPClient(relay: relay, role: "cleanup")),
      scribe: ChatCompletionsClient(provider: pipeline.scribe.provider, endpoint: endpoint, http: RelayHTTPClient(relay: relay, role: "scribe")))
  }
}
