import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
  case mistral
  case openai
  /// Transcription only (Scribe v2): cleanup and Scribe stay with a chat provider.
  case elevenlabs
  /// Chat only (cleanup and Scribe): any server that speaks OpenAI's chat completions, such as
  /// LiteLLM, Ollama or vLLM, at the address the user gives.
  case compatible

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .mistral: "Mistral"
    case .openai: "OpenAI"
    case .elevenlabs: "ElevenLabs"
    case .compatible: "OpenAI-compatible"
    }
  }

  public var defaultBaseURL: URL {
    switch self {
    case .mistral: URL(string: "https://api.mistral.ai")!
    case .openai: URL(string: "https://api.openai.com")!
    case .elevenlabs: URL(string: "https://api.elevenlabs.io")!
    // LiteLLM's default; the app always uses the address typed by the user.
    case .compatible: URL(string: "http://localhost:4000")!
    }
  }

  /// PCM sample rate the provider's realtime transcription expects.
  public var sampleRate: Int {
    switch self {
    case .mistral, .elevenlabs, .compatible: 16_000
    case .openai: 24_000  // OpenAI Realtime accepts only 24 kHz PCM
    }
  }

  /// Whether it has chat models, for the cleanup and Scribe.
  public var supportsChat: Bool { self != .elevenlabs }

  /// The providers that can run the whole pipeline.
  public static var chatProviders: [ProviderID] { allCases.filter(\.supportsChat) }

  /// Whether it has transcription models.
  public var supportsTranscription: Bool { self != .compatible }

  public static var transcriptionProviders: [ProviderID] { allCases.filter(\.supportsTranscription) }

  /// The providers that can run the whole pipeline by themselves.
  public static var fullProviders: [ProviderID] { allCases.filter { $0.supportsChat && $0.supportsTranscription } }

  /// The providers an organization's server can use for cleanup and Scribe.
  public static let serverChatProviders: [ProviderID] = [.mistral, .openai]

  /// The header that carries the API key: ElevenLabs uses its own, the others a bearer token.
  public var keyHeader: String? { self == .elevenlabs ? "xi-api-key" : nil }
}

/// realtime: streaming while speaking, batch only as a fallback.
/// batch: one upload at release.
/// hybrid: streaming while speaking; at release the batch wins up to `batchMaxAudioMs`
/// (more accurate and, below ~25 s, also faster), the streaming result beyond that.
public enum TranscriptionMode: String, Codable, Sendable, CaseIterable {
  case realtime
  case batch
  case hybrid
}

/// Reasoning effort levels, from least to most.
public enum ReasoningLevel: String, Codable, Sendable, CaseIterable, Comparable {
  case none, minimal, low, medium, high, xhigh, max

  public static func < (a: ReasoningLevel, b: ReasoningLevel) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }
}

/// What a chat model accepts.
public struct ChatCapabilities: Sendable, Equatable {
  /// Accepted `reasoning_effort` values; empty means the parameter must not be sent.
  public var reasoning: [ReasoningLevel]
  public var prediction: Bool
  public var temperature: Bool
  public var fastTier: Bool

  /// The accepted level closest to `wanted`, rounding up; nil when reasoning can't be set.
  public func reasoning(for wanted: ReasoningLevel) -> ReasoningLevel? {
    guard !reasoning.isEmpty else { return nil }
    if reasoning.contains(wanted) { return wanted }
    return reasoning.sorted().first { $0 > wanted } ?? reasoning.max()
  }
}

/// What a transcription model accepts.
public struct TranscriptionCapabilities: Sendable, Equatable {
  public var realtime: Bool
  public var batch: Bool
  /// OpenAI `keywords[]`; otherwise the vocabulary goes in Mistral `context_bias` or in a prompt.
  public var keywords: Bool
}

public struct ModelInfo: Sendable, Identifiable, Equatable {
  public enum Kind: Sendable, Equatable {
    case chat(ChatCapabilities)
    case transcription(TranscriptionCapabilities)
  }

  public var provider: ProviderID
  public var id: String
  public var name: String
  public var kind: Kind
  public var note: String?
}

/// Known models. Any other id can be typed by hand: it gets the provider's generic
/// capabilities and the Verify button tells whether it works.
public enum ModelCatalog {
  private static let mistralSmall = ChatCapabilities(reasoning: [.none, .high], prediction: true, temperature: true, fastTier: false)
  /// No reasoning parameter: it answers directly. Predicted outputs not verified.
  private static let mistralMedium = ChatCapabilities(reasoning: [], prediction: false, temperature: true, fastTier: false)
  private static let mistralLarge = ChatCapabilities(reasoning: [.low, .medium, .high], prediction: false, temperature: true, fastTier: false)
  private static let ministral = ChatCapabilities(reasoning: [], prediction: true, temperature: true, fastTier: false)
  private static let openAIReasoning = ChatCapabilities(
    reasoning: [.none, .low, .medium, .high, .xhigh, .max], prediction: false, temperature: false, fastTier: true)
  private static let openAIFrontier = ChatCapabilities(
    reasoning: [.low, .medium, .high, .xhigh, .max], prediction: false, temperature: false, fastTier: true)

  public static let models: [ModelInfo] = [
    // Mistral
    ModelInfo(
      provider: .mistral, id: "voxtral-mini-transcribe-realtime-3-0", name: "Voxtral Mini Transcribe Realtime 3",
      kind: .transcription(TranscriptionCapabilities(realtime: true, batch: false, keywords: false))),
    ModelInfo(
      provider: .mistral, id: "voxtral-mini-transcribe-3-0", name: "Voxtral Mini Transcribe 3",
      kind: .transcription(TranscriptionCapabilities(realtime: false, batch: true, keywords: false))),
    ModelInfo(
      provider: .mistral, id: "voxtral-small-transcribe-3-0", name: "Voxtral Small Transcribe 3",
      kind: .transcription(TranscriptionCapabilities(realtime: false, batch: true, keywords: false))),
    ModelInfo(provider: .mistral, id: "mistral-small-2603", name: "Mistral Small 4", kind: .chat(mistralSmall)),
    ModelInfo(provider: .mistral, id: "mistral-medium-2604", name: "Mistral Medium 3.5", kind: .chat(mistralMedium)),
    ModelInfo(provider: .mistral, id: "mistral-large-4-0", name: "Mistral Large 4", kind: .chat(mistralLarge)),
    ModelInfo(provider: .mistral, id: "ministral-8b-2512", name: "Ministral 8B", kind: .chat(ministral)),
    ModelInfo(provider: .mistral, id: "ministral-3b-2512", name: "Ministral 3B", kind: .chat(ministral)),
    // OpenAI
    ModelInfo(
      provider: .openai, id: "gpt-transcribe", name: "GPT Transcribe",
      kind: .transcription(TranscriptionCapabilities(realtime: true, batch: true, keywords: true)),
      note: "Realtime: transcribes after the key is released, with the audio already uploaded."),
    ModelInfo(
      provider: .openai, id: "gpt-live-transcribe", name: "GPT Live Transcribe",
      kind: .transcription(TranscriptionCapabilities(realtime: true, batch: false, keywords: true)),
      note: "Live partial text while speaking; costs about four times more."),
    ModelInfo(provider: .openai, id: "gpt-6-luna", name: "GPT-6 Luna", kind: .chat(openAIReasoning)),
    ModelInfo(provider: .openai, id: "gpt-6.1-terra", name: "GPT-6.1 Terra", kind: .chat(openAIReasoning)),
    ModelInfo(provider: .openai, id: "gpt-6.1-sol", name: "GPT-6.1 Sol", kind: .chat(openAIFrontier)),
    ModelInfo(provider: .openai, id: "gpt-5.4-mini", name: "GPT-5.4 mini", kind: .chat(
      ChatCapabilities(reasoning: [.none, .low, .medium, .high, .xhigh], prediction: false, temperature: false, fastTier: true))),
    // ElevenLabs: the vocabulary goes in `keyterms`, which cost 20% more.
    ModelInfo(
      provider: .elevenlabs, id: "scribe_v2_realtime", name: "Scribe v2 Realtime",
      kind: .transcription(TranscriptionCapabilities(realtime: true, batch: false, keywords: true))),
    ModelInfo(
      provider: .elevenlabs, id: "scribe_v2", name: "Scribe v2",
      kind: .transcription(TranscriptionCapabilities(realtime: false, batch: true, keywords: true))),
  ]

  public static func info(_ provider: ProviderID, _ id: String) -> ModelInfo? {
    models.first { $0.provider == provider && $0.id == id }
  }

  public static func chatModels(_ provider: ProviderID) -> [ModelInfo] {
    models.filter {
      if case .chat = $0.kind { return $0.provider == provider }
      return false
    }
  }

  public static func transcriptionModels(_ provider: ProviderID, realtime: Bool) -> [ModelInfo] {
    models.filter {
      if case .transcription(let caps) = $0.kind { return $0.provider == provider && (realtime ? caps.realtime : caps.batch) }
      return false
    }
  }

  /// Capabilities of a chat model, known or typed by hand.
  public static func chatCapabilities(_ provider: ProviderID, _ id: String) -> ChatCapabilities {
    if let info = info(provider, id), case .chat(let caps) = info.kind { return caps }
    switch provider {
    case .mistral:
      if id.hasPrefix("ministral") { return ministral }
      if id.hasPrefix("mistral-large-4") { return mistralLarge }
      return ChatCapabilities(reasoning: [], prediction: true, temperature: true, fastTier: false)
    case .openai:
      return ChatCapabilities(reasoning: [.none, .low, .medium, .high], prediction: false, temperature: false, fastTier: true)
    case .elevenlabs, .compatible:
      // Only what every OpenAI-compatible server accepts.
      return ChatCapabilities(reasoning: [], prediction: false, temperature: true, fastTier: false)
    }
  }

  public static func transcriptionCapabilities(_ provider: ProviderID, _ id: String) -> TranscriptionCapabilities {
    if let info = info(provider, id), case .transcription(let caps) = info.kind { return caps }
    switch provider {
    case .mistral: return TranscriptionCapabilities(realtime: id.contains("realtime"), batch: !id.contains("realtime"), keywords: false)
    case .openai: return TranscriptionCapabilities(realtime: true, batch: true, keywords: id.hasPrefix("gpt-transcribe") || id.hasPrefix("gpt-live"))
    case .elevenlabs: return TranscriptionCapabilities(realtime: id.contains("realtime"), batch: !id.contains("realtime"), keywords: true)
    case .compatible: return TranscriptionCapabilities(realtime: false, batch: false, keywords: false)
    }
  }
}

// MARK: - Settings

public struct TranscriptionSettings: Codable, Sendable, Equatable {
  public var provider: ProviderID
  public var mode: TranscriptionMode
  public var realtimeModel: String
  public var batchModel: String
  /// Mistral realtime streaming delay (80–1200 ms, or 2400).
  public var delayMs: Int
  /// In hybrid mode, audio up to this length is transcribed by the batch model.
  public var batchMaxAudioMs: Int

  public init(provider: ProviderID, mode: TranscriptionMode, realtimeModel: String, batchModel: String, delayMs: Int = 480, batchMaxAudioMs: Int = 25_000) {
    self.provider = provider
    self.mode = mode
    self.realtimeModel = realtimeModel
    self.batchModel = batchModel
    self.delayMs = delayMs
    self.batchMaxAudioMs = batchMaxAudioMs
  }

  public static func defaults(_ provider: ProviderID) -> TranscriptionSettings {
    switch provider {
    case .mistral, .compatible:
      // An OpenAI-compatible server only runs cleanup and Scribe: transcription stays with Mistral.
      TranscriptionSettings(provider: .mistral, mode: .hybrid, realtimeModel: "voxtral-mini-transcribe-realtime-3-0", batchModel: "voxtral-mini-transcribe-3-0")
    case .openai:
      // gpt-transcribe on the realtime socket: the audio is uploaded while speaking and
      // transcribed at release, so no second upload is needed.
      TranscriptionSettings(provider: .openai, mode: .realtime, realtimeModel: "gpt-transcribe", batchModel: "gpt-transcribe")
    case .elevenlabs:
      // Like Voxtral: the whole recording to the batch model at release, the stream beyond 25 s.
      TranscriptionSettings(provider: .elevenlabs, mode: .hybrid, realtimeModel: "scribe_v2_realtime", batchModel: "scribe_v2")
    }
  }
}

public struct ChatSettings: Codable, Sendable, Equatable {
  public var provider: ProviderID
  public var model: String
  /// Predicted outputs (cleanup only), when the model accepts them.
  public var prediction: Bool
  /// OpenAI `service_tier: "fast"`: faster, at twice the price.
  public var fastTier: Bool
  /// Reasoning for this role; nil: the role's own (none for cleanup, low for Scribe), rounded to
  /// what the model accepts.
  public var reasoning: ReasoningLevel?

  public init(provider: ProviderID, model: String, prediction: Bool = false, fastTier: Bool = false, reasoning: ReasoningLevel? = nil) {
    self.provider = provider
    self.model = model
    self.prediction = prediction
    self.fastTier = fastTier
    self.reasoning = reasoning
  }

  public static func cleanupDefaults(_ provider: ProviderID) -> ChatSettings {
    switch provider {
    case .mistral, .elevenlabs: ChatSettings(provider: .mistral, model: "mistral-small-2603", prediction: true)
    // Fast tier on: about 0.5 s less per dictation for twice the price of a few hundred tokens.
    case .openai: ChatSettings(provider: .openai, model: "gpt-6-luna", fastTier: true)
    // The models are the server's own: the user types the name.
    case .compatible: ChatSettings(provider: .compatible, model: "")
    }
  }

  public static func scribeDefaults(_ provider: ProviderID) -> ChatSettings {
    switch provider {
    // Medium: first word in under 1.5 s on 40 of 40 drafts, and it doesn't invent facts
    // (Small without reasoning is as fast but does; Large 4 waits 5 s or more). See docs/latency.md.
    case .mistral, .elevenlabs: ChatSettings(provider: .mistral, model: "mistral-medium-2604")
    case .openai: ChatSettings(provider: .openai, model: "gpt-6.1-sol")
    case .compatible: ChatSettings(provider: .compatible, model: "")
    }
  }
}

public struct PipelineSettings: Codable, Sendable, Equatable {
  public var transcription: TranscriptionSettings
  public var cleanup: ChatSettings
  public var scribe: ChatSettings
  /// Short, clean sentences up to this many words skip the model (0 = always use it).
  public var fastPathMaxWords: Int

  public init(transcription: TranscriptionSettings, cleanup: ChatSettings, scribe: ChatSettings, fastPathMaxWords: Int = 0) {
    self.transcription = transcription
    self.cleanup = cleanup
    self.scribe = scribe
    self.fastPathMaxWords = fastPathMaxWords
  }

  public static func defaults(_ provider: ProviderID) -> PipelineSettings {
    PipelineSettings(
      transcription: .defaults(provider),
      cleanup: .cleanupDefaults(provider),
      scribe: .scribeDefaults(provider))
  }

  /// Providers whose key is needed.
  public var providers: Set<ProviderID> {
    [transcription.provider, cleanup.provider, scribe.provider]
  }
}
