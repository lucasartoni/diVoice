import Foundation

/// A chat completion request, independent of the provider.
public struct ChatCall: Sendable {
  public var model: String
  public var messages: [ChatMessage]
  public var temperature: Double?
  public var maxTokens: Int
  public var reasoning: ReasoningLevel?
  /// Predicted output (sent only if enabled and accepted by the model).
  public var prediction: String?
  public var cacheKey: String?
  public var fastTier: Bool
  /// `response_format` for JSON answers.
  public var jsonSchema: [String: any Sendable]?

  public init(
    model: String,
    messages: [ChatMessage],
    temperature: Double? = nil,
    maxTokens: Int,
    reasoning: ReasoningLevel? = nil,
    prediction: String? = nil,
    cacheKey: String? = nil,
    fastTier: Bool = false,
    jsonSchema: [String: any Sendable]? = nil
  ) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.reasoning = reasoning
    self.prediction = prediction
    self.cacheKey = cacheKey
    self.fastTier = fastTier
    self.jsonSchema = jsonSchema
  }
}

public struct ChatStreamResult: Sendable, Equatable {
  public var text: String
  public var ttftMs: Double?
  public var totalMs: Double
  public var finishReason: String?
}

public protocol ChatService: Sendable {
  var provider: ProviderID { get }
  func stream(_ call: ChatCall, timeout: Double, onDelta: (@Sendable (String) -> Void)?) async throws -> ChatStreamResult
  /// Non-streaming completion; returns the message content.
  func complete(_ call: ChatCall, timeout: Double) async throws -> String
}

/// `/v1/chat/completions` for Mistral, OpenAI and OpenAI-compatible servers, with each provider's parameter names.
public struct ChatCompletionsClient: ChatService {
  public let provider: ProviderID
  private let endpoint: ProviderEndpoint
  private let http: HTTPClient
  private let now: EngineClock

  public init(provider: ProviderID, endpoint: ProviderEndpoint, http: HTTPClient, now: @escaping EngineClock = EngineClocks.monotonic) {
    self.provider = provider
    self.endpoint = endpoint
    self.http = http
    self.now = now
  }

  /// Extra output tokens for the model's reasoning, on top of the answer's limit.
  public static let reasoningRoom = 4_000

  /// The request body for this provider and model.
  public func body(_ call: ChatCall, stream: Bool) -> [String: Any] {
    let caps = ModelCatalog.chatCapabilities(provider, call.model)
    var body: [String: Any] = [
      "model": call.model,
      "messages": call.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
      "stream": stream,
    ]
    let effort = call.reasoning.flatMap { caps.reasoning(for: $0) }
    if let effort { body["reasoning_effort"] = effort.rawValue }
    if let temperature = call.temperature, caps.temperature { body["temperature"] = temperature }
    // Reasoning tokens count towards the limit, with both providers: without room, a short
    // answer is cut off once the model has finished thinking.
    let reasoningRoom = (effort.map { $0 > .none } ?? false) ? Self.reasoningRoom : 0
    switch provider {
    case .mistral:
      body["max_tokens"] = call.maxTokens + reasoningRoom
      // Greedy sampling (temperature 0) requires top_p 1 on some models (Large 4).
      if call.temperature == 0, caps.temperature { body["top_p"] = 1 }
    case .openai:
      body["max_completion_tokens"] = call.maxTokens + reasoningRoom
      if call.fastTier, caps.fastTier { body["service_tier"] = "fast" }
    case .elevenlabs, .compatible:
      // ElevenLabs has no chat models: the settings never pick it for cleanup or Scribe.
      body["max_tokens"] = call.maxTokens + reasoningRoom
    }
    if let prediction = call.prediction, caps.prediction { body["prediction"] = ["type": "content", "content": prediction] }
    // An OpenAI-compatible server may refuse parameters it doesn't know.
    if let cacheKey = call.cacheKey, provider != .compatible { body["prompt_cache_key"] = cacheKey }
    if let schema = call.jsonSchema { body["response_format"] = schema }
    return body
  }

  private func request(_ call: ChatCall, stream: Bool, timeout: Double) -> URLRequest {
    var request = endpoint.request(endpoint.url("/v1/chat/completions"), method: "POST", timeout: timeout)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(JSON.string(body(call, stream: stream)).utf8)
    return request
  }

  /// Content can be a string or, with reasoning on (Mistral), a list of blocks.
  static func extractText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    if let blocks = content as? [[String: Any]] {
      return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
    return ""
  }

  public func stream(_ call: ChatCall, timeout: Double, onDelta: (@Sendable (String) -> Void)?) async throws -> ChatStreamResult {
    let started = now()
    let request = request(call, stream: true, timeout: timeout)
    let label = "chat \(call.model)"
    let now = self.now
    let http = self.http
    return try await withTimeout(timeout, label) {
      var text = ""
      var ttft: Double?
      var finish: String?
      try await http.lines(request, label: label) { line in
        guard line.hasPrefix("data:") else { return }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !data.isEmpty, data != "[DONE]", let json = JSON.object(data) else { return }
        let choice = (json["choices"] as? [[String: Any]])?.first
        let delta = Self.extractText((choice?["delta"] as? [String: Any])?["content"])
        if !delta.isEmpty {
          if ttft == nil { ttft = now() - started }
          text += delta
          onDelta?(delta)
        }
        if let reason = choice?["finish_reason"] as? String { finish = reason }
      }
      return ChatStreamResult(text: text, ttftMs: ttft, totalMs: now() - started, finishReason: finish)
    }
  }

  public func complete(_ call: ChatCall, timeout: Double) async throws -> String {
    let request = request(call, stream: false, timeout: timeout)
    let (data, response) = try await http.data(request)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPStatusError(label: "chat \(call.model)", status: response.statusCode, body: String(decoding: data.prefix(2048), as: UTF8.self))
    }
    let json = JSON.object(data)
    let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
    return Self.extractText(message?["content"])
  }
}
