import DiVoiceEngine
import Foundation

/// Builds the engine's provider clients for personal use: direct calls with the user's keys.
enum EngineFactory {
  enum Missing: LocalizedError {
    case key(ProviderID)
    case server

    var errorDescription: String? {
      switch self {
      case .key(let provider): String(localized: "Add your \(provider.displayName) API key in diVoice's settings")
      case .server: String(localized: "Add your OpenAI-compatible server's address in diVoice's settings")
      }
    }
  }

  /// One session for every call: connections stay warm between dictations.
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpMaximumConnectionsPerHost = 6
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  static let http = URLSessionHTTPClient(session: session)
  static let connector = URLSessionWebSocketConnector(session: session)

  static func endpoint(_ provider: ProviderID) throws -> ProviderEndpoint {
    guard let key = KeyStore.key(provider) else { throw Missing.key(provider) }
    if provider == .compatible {
      guard let server = AppSettings.shared.compatibleServer else { throw Missing.server }
      return .compatible(server, apiKey: key)
    }
    return .direct(provider, apiKey: key)
  }

  static func transcription(_ settings: TranscriptionSettings) throws -> TranscriptionService {
    ProviderClients.transcription(settings.provider, endpoint: try endpoint(settings.provider), http: http, connector: connector)
  }

  static func chat(_ settings: ChatSettings) throws -> ChatService {
    ProviderClients.chat(settings.provider, endpoint: try endpoint(settings.provider), http: http)
  }

  static func services(_ pipeline: PipelineSettings) throws -> DictationServices {
    DictationServices(
      transcription: try transcription(pipeline.transcription),
      cleanup: try chat(pipeline.cleanup),
      scribe: try chat(pipeline.scribe))
  }

  /// Providers used by the pipeline whose key is not saved.
  static func missingKeys(_ pipeline: PipelineSettings) -> [ProviderID] {
    ProviderID.allCases.filter { pipeline.providers.contains($0) && !KeyStore.hasKey($0) }
  }

  // MARK: Personal or organization

  /// The pipeline dictations run with: the organization's models when this Mac belongs to one.
  static func activePipeline(_ settings: AppSettings) -> PipelineSettings {
    if let membership = OrgStore.shared.membership { return RelayServices.clientPipeline(membership.pipeline) }
    return settings.pipeline
  }

  /// Whether the pipeline uses an OpenAI-compatible server whose address is still to add.
  static func missingServer(_ settings: AppSettings) -> Bool {
    OrgStore.shared.membership == nil && settings.pipeline.providers.contains(.compatible) && settings.compatibleServer == nil
  }

  /// Keys still to add: none with an organization, whose server holds them.
  static func activeMissingKeys(_ settings: AppSettings) -> [ProviderID] {
    OrgStore.shared.membership == nil ? missingKeys(settings.pipeline) : []
  }

  struct Dictation {
    var pipeline: PipelineSettings
    var services: DictationServices
    /// The organization's connection: the controller sends the counts and closes it.
    var relay: RelayConnection?
  }

  enum OrgMissing: LocalizedError {
    case token

    var errorDescription: String? {
      String(localized: "diVoice lost the organization's token: join again with an invite")
    }
  }

  static func dictation(_ settings: AppSettings, sessionId: String) throws -> Dictation {
    let store = OrgStore.shared
    guard let membership = store.membership else {
      return Dictation(pipeline: settings.pipeline, services: try services(settings.pipeline), relay: nil)
    }
    guard let token = store.token else { throw OrgMissing.token }
    let pipeline = RelayServices.clientPipeline(membership.pipeline)
    let relay = RelayConnection.open(server: membership.server, token: token, connector: connector)
    return Dictation(
      pipeline: pipeline, services: RelayServices.services(pipeline, relay: relay, server: membership.server, sessionId: sessionId),
      relay: relay)
  }

  /// Verify through the organization's server: a session that isn't counted in the statistics.
  static func verifyServices(sessionId: String) throws -> (pipeline: PipelineSettings, services: DictationServices, relay: RelayConnection)? {
    let store = OrgStore.shared
    guard let membership = store.membership else { return nil }
    guard let token = store.token else { throw OrgMissing.token }
    let pipeline = RelayServices.clientPipeline(membership.pipeline)
    let relay = RelayConnection.open(server: membership.server, token: token, connector: connector)
    let services = RelayServices.services(pipeline, relay: relay, server: membership.server, sessionId: sessionId, purpose: .verify)
    return (pipeline, services, relay)
  }
}
