import DiVoiceEngine
import Foundation

/// One pipeline configuration to measure, written as `provider[,option...]`.
struct BenchConfig: Equatable {
  var label: String
  var pipeline: PipelineSettings
  /// Through the organization's server (--server): its models, its keys.
  var viaServer = false

  static let help = """
      server                        through the organization's server given with --server
      provider[,option...]          mistral | openai | elevenlabs, with that provider's default models
                                    (elevenlabs transcribes only: cleanup and Scribe from Mistral)
        mode=realtime|batch|hybrid  transcription mode
        stt=<model>                 transcription model, streaming and batch
        rt=<model>, batch=<model>   only one of the two
        delay=<ms>                  Mistral streaming delay
        cleanup=[provider/]<model>  cleanup model, optionally from the other provider
                                    (compatible/<model>: the server at COMPATIBLE_BASE_URL)
        scribe=[provider/]<model>   Scribe model (with --scribe)
        scribe-reasoning=<level>    Scribe's reasoning: none, low, medium, high
        prediction=on|off           predicted outputs for cleanup
        fast[=on|off]               OpenAI fast service tier for cleanup (on by default)
        fastpath=<words>            short clean sentences skip the model (0 = never)
    """

  static func parse(_ spec: String) throws -> BenchConfig {
    if spec.trimmingCharacters(in: .whitespaces).lowercased() == "server" {
      return BenchConfig(label: "server", pipeline: .defaults(.mistral), viaServer: true)
    }
    let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = parts.first, let provider = ProviderID(rawValue: first.lowercased()) else {
      throw EngineError("\(spec): a configuration starts with the provider (mistral, openai or elevenlabs)")
    }
    var pipeline = PipelineSettings.defaults(provider)
    for option in parts.dropFirst() {
      let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
      let value = pair.count > 1 ? pair[1] : nil
      func invalid() -> EngineError { EngineError("\(spec): invalid option \(option)") }
      switch (pair[0], value) {
      case ("mode", let value?):
        guard let mode = TranscriptionMode(rawValue: value) else { throw invalid() }
        pipeline.transcription.mode = mode
      case ("stt", let value?):
        pipeline.transcription.realtimeModel = value
        pipeline.transcription.batchModel = value
      case ("rt", let value?):
        pipeline.transcription.realtimeModel = value
      case ("batch", let value?):
        pipeline.transcription.batchModel = value
      case ("delay", let value?):
        guard let ms = Int(value), ms > 0 else { throw invalid() }
        pipeline.transcription.delayMs = ms
      case ("cleanup", let value?):
        let bits = value.split(separator: "/", maxSplits: 1).map(String.init)
        if bits.count == 2 {
          guard let other = ProviderID(rawValue: bits[0].lowercased()), !bits[1].isEmpty else { throw invalid() }
          pipeline.cleanup = .cleanupDefaults(other)
          pipeline.cleanup.model = bits[1]
        } else {
          pipeline.cleanup.model = value
        }
      case ("scribe", let value?):
        let bits = value.split(separator: "/", maxSplits: 1).map(String.init)
        if bits.count == 2 {
          guard let other = ProviderID(rawValue: bits[0].lowercased()), !bits[1].isEmpty else { throw invalid() }
          pipeline.scribe = .scribeDefaults(other)
          pipeline.scribe.model = bits[1]
        } else {
          pipeline.scribe.model = value
        }
      case ("scribe-reasoning", let value?):
        guard let level = ReasoningLevel(rawValue: value) else { throw invalid() }
        pipeline.scribe.reasoning = level
      case ("prediction", "on"):
        pipeline.cleanup.prediction = true
      case ("prediction", "off"):
        pipeline.cleanup.prediction = false
      case ("fast", nil), ("fast", "on"):
        pipeline.cleanup.fastTier = true
      case ("fast", "off"):
        pipeline.cleanup.fastTier = false
      case ("fastpath", let value?):
        guard let words = Int(value), words >= 0 else { throw invalid() }
        pipeline.fastPathMaxWords = words
      default:
        throw invalid()
      }
    }
    return BenchConfig(label: spec, pipeline: pipeline)
  }

  /// Providers whose key the configuration needs (none through the server).
  func providers(scribe: Bool) -> Set<ProviderID> {
    if viaServer { return [] }
    return scribe ? [pipeline.scribe.provider] : [pipeline.transcription.provider, pipeline.cleanup.provider]
  }
}
