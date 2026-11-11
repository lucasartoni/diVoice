import DiVoiceCore
import Foundation

@testable import DiVoiceEngine

func entry(
  _ term: String, aliases: [String] = [], note: String? = nil, scope: VocabularyEntry.Scope = .team,
  source: VocabularyEntry.Source = .seed, enabled: Bool = true, usage: Int = 0, id: String? = nil
) -> VocabularyEntry {
  VocabularyEntry(
    id: id ?? "id-\(term.lowercased())", term: term, aliases: aliases, note: note, scope: scope, source: source,
    enabled: enabled, usageCount: usage)
}

/// Silent PCM of the given length.
func silence(ms: Int, sampleRate: Int = 16_000) -> Data {
  Data(count: ms * sampleRate / 1000 * 2)
}

/// Waits until `condition` holds (or fails after a second).
func eventually(_ condition: @Sendable () -> Bool) async throws {
  for _ in 0..<1000 {
    if condition() { return }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
  throw EngineError("condition not reached")
}

// MARK: - HTTP

struct RecordedRequest: @unchecked Sendable {
  let url: String
  let headers: [String: String]
  let body: Data

  var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }

  /// Multipart fields as (name, value) pairs; file parts are reported by name with their size.
  var formFields: [(String, String)] {
    let text = String(decoding: body, as: UTF8.self)
    var out: [(String, String)] = []
    for part in text.components(separatedBy: "\r\n--") {
      guard let nameRange = part.range(of: "name=\""), let end = part[nameRange.upperBound...].firstIndex(of: "\"") else { continue }
      let name = String(part[nameRange.upperBound..<end])
      guard let separator = part.range(of: "\r\n\r\n") else { continue }
      var value = String(part[separator.upperBound...])
      if value.hasSuffix("\r\n") { value.removeLast(2) }
      out.append((name, part.contains("filename=") ? "<file>" : value))
    }
    return out
  }
}

/// Answers chat requests with an SSE stream of `pieces`, JSON requests with `json`.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [RecordedRequest] = []
  var pieces: [String]
  var contentBlocks = false
  var status = 200
  var json: [String: Any] = [:]

  init(pieces: [String] = ["ok"]) {
    self.pieces = pieces
  }

  var requests: [RecordedRequest] { lock.withLock { recorded } }

  private func record(_ request: URLRequest) {
    let headers = request.allHTTPHeaderFields ?? [:]
    lock.withLock { recorded.append(RecordedRequest(url: request.url!.absoluteString, headers: headers, body: request.httpBody ?? Data())) }
  }

  func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    record(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    if status != 200 { return (Data("boom".utf8), response) }
    return (try JSONSerialization.data(withJSONObject: json), response)
  }

  func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws {
    record(request)
    if status != 200 { throw HTTPStatusError(label: label, status: status, body: "boom") }
    for piece in pieces {
      let content: Any = contentBlocks ? [["type": "text", "text": piece]] : piece
      let chunk = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
      try onLine("data: \(String(decoding: chunk, as: UTF8.self))")
    }
    try onLine(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
    try onLine("data: [DONE]")
  }
}

// MARK: - WebSocket

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [String] = []
  private var waiter: CheckedContinuation<String, Error>?
  private var failure: Error?
  private var sentMessages: [String] = []
  private(set) var closedByClient = false

  var sent: [[String: Any]] {
    lock.withLock { sentMessages }.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) ?? [:] }
  }

  var sentCount: Int { lock.withLock { sentMessages.count } }
  var isClosed: Bool { lock.withLock { closedByClient } }

  func send(_ text: String) {
    lock.withLock { sentMessages.append(text) }
  }

  /// Like a real socket, the message is written a moment later, and a close before then drops it.
  func sendAndWait(_ text: String) async {
    try? await Task.sleep(nanoseconds: 20_000_000)
    lock.withLock {
      waitedMessages.append(text)
      if !closedByClient { sentMessages.append(text) }
    }
  }

  private var waitedMessages: [String] = []
  /// Message types sent with `sendAndWait`.
  var waitedTypes: [String] {
    lock.withLock { waitedMessages }.compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String
    }
  }

  private var sentBinary: [Data] = []
  var binary: [Data] { lock.withLock { sentBinary } }

  func send(data: Data) {
    lock.withLock {
      sentBinary.append(data)
      sentMessages.append(#"{"binary":\#(data.count)}"#)
    }
  }

  func receive() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if !queue.isEmpty {
        let message = queue.removeFirst()
        lock.unlock()
        continuation.resume(returning: message)
      } else if let failure {
        lock.unlock()
        continuation.resume(throwing: failure)
      } else {
        waiter = continuation
        lock.unlock()
      }
    }
  }

  func close() {
    lock.withLock { closedByClient = true }
    deliver(error: EngineError("closed by client"))
  }

  /// A message from the server.
  func server(_ message: [String: Any]) {
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    lock.lock()
    if let waiter {
      self.waiter = nil
      lock.unlock()
      waiter.resume(returning: text)
    } else {
      queue.append(text)
      lock.unlock()
    }
  }

  func serverClose(_ code: Int) {
    deliver(error: EngineError("connection closed (\(code))"))
  }

  private func deliver(error: Error) {
    lock.lock()
    if failure == nil { failure = error }
    let waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(throwing: error)
  }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
  let socket = FakeSocket()
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  var failure: Error?

  var requests: [URLRequest] { lock.withLock { recorded } }

  func connect(_ request: URLRequest) async throws -> WebSocketConnection {
    lock.withLock { recorded.append(request) }
    if let failure { throw failure }
    return socket
  }
}

// MARK: - Transcription

actor FakeTranscriber: StreamingTranscriber {
  private let outcome: Result<TranscriptResult, Error>
  private let onText: (@Sendable (String) -> Void)?
  private(set) var audioBytes = 0
  private(set) var aborted = false
  let connectMs: Double? = 7

  init(outcome: Result<TranscriptResult, Error>, onText: (@Sendable (String) -> Void)?) {
    self.outcome = outcome
    self.onText = onText
  }

  func sendAudio(_ chunk: Data) {
    audioBytes += chunk.count
    onText?("testo parziale")
  }

  func finish(timeout: Double) async throws -> TranscriptResult {
    try outcome.get()
  }

  func abort() {
    aborted = true
  }
}

final class FakeTranscription: TranscriptionService, @unchecked Sendable {
  let provider: ProviderID
  private let lock = NSLock()
  let realtime: Result<TranscriptResult, Error>
  let batchResult: Result<TranscriptResult, Error>
  private var opened: [(TranscriptionRequest, FakeTranscriber)] = []
  private var batches: [(Data, TranscriptionRequest)] = []

  init(provider: ProviderID = .mistral, realtime: Result<TranscriptResult, Error> = .success(TranscriptResult(text: "")), batch: Result<TranscriptResult, Error> = .success(TranscriptResult(text: ""))) {
    self.provider = provider
    self.realtime = realtime
    self.batchResult = batch
  }

  var transcriber: FakeTranscriber? { lock.withLock { opened.first?.1 } }
  var streamingRequest: TranscriptionRequest? { lock.withLock { opened.first?.0 } }
  var batchCalls: [(Data, TranscriptionRequest)] { lock.withLock { batches } }

  func openStreaming(_ request: TranscriptionRequest, onText: (@Sendable (String) -> Void)?) -> StreamingTranscriber {
    let transcriber = FakeTranscriber(outcome: realtime, onText: onText)
    lock.withLock { opened.append((request, transcriber)) }
    return transcriber
  }

  func batch(wav: Data, _ request: TranscriptionRequest, timeout: Double) async throws -> TranscriptResult {
    lock.withLock { batches.append((wav, request)) }
    return try batchResult.get()
  }

  func finishTimeout(audioMs: Int) -> Double { 4 }
}
