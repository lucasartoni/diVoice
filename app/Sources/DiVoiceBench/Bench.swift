import DiVoiceCore
import DiVoiceEngine
import Foundation

let usage = """
  divoice-bench: dictation latency and accuracy, measured with the app's own engine.

  usage: scripts/bench.sh [--config SPEC]... [--runs N] [--clips DIR] [--only ID,...] [--scribe]
                          [--server URL --token-file FILE] [--out FILE.md] [--verbose]

  Each clip is streamed at real-time pace in 100 ms blocks, as the microphone would, then the
  dictation ends; times run from the release to the final text (paste excluded). One untimed
  dictation per configuration warms the connections first, as in daily use.

  --config SPEC  repeatable; default: mistral and openai, each with its default models
  \(BenchConfig.help)
  --runs N       rounds over all the clips (default 2)
  --clips DIR    clips.json, plus <id>.wav recordings, instead of the built-in synthetic clips
  --only IDS     only these clip ids, comma separated
  --scribe       measure Scribe instead of dictations: first token, total, cut-off answers, and
                 quality flags (carried out instead of edited, added numbers, lost facts)
  --models       list the chat models each provider offers to your key, then stop
  --server URL   the organization's server, for the "server" configuration
  --token-file F a member token for --server (or DIVOICE_TOKEN). Sessions count as Verify:
                 they never reach the team's statistics
  --out FILE     also write the report there (Markdown), and the raw results next to it (JSON)
  --verbose      print the transcripts

  Keys: the ones saved in diVoice (macOS asks whether divoice-bench may read them), otherwise
  MISTRAL_API_KEY / OPENAI_API_KEY. Keys and tokens are never printed.
  """

struct Options {
  var configs: [BenchConfig] = []
  var runs = 2
  var clipsFolder: URL?
  var only: [String] = []
  var out: URL?
  var verbose = false
  var scribe = false
  var listModels = false
  var server: URL?
  var tokenFile: URL?

  /// nil for --help.
  static func parse(_ arguments: [String]) throws -> Options? {
    var options = Options()
    var rest = arguments[...]
    func value(_ flag: String) throws -> String {
      guard let next = rest.popFirst() else { throw EngineError("\(flag) needs a value") }
      return next
    }
    while let flag = rest.popFirst() {
      switch flag {
      case "--config": options.configs.append(try BenchConfig.parse(try value(flag)))
      case "--runs":
        guard let runs = Int(try value(flag)), runs > 0 else { throw EngineError("--runs needs a positive number") }
        options.runs = runs
      case "--clips": options.clipsFolder = URL(fileURLWithPath: try value(flag))
      case "--only": options.only = try value(flag).split(separator: ",").map(String.init)
      case "--out": options.out = URL(fileURLWithPath: try value(flag))
      case "--verbose", "-v": options.verbose = true
      case "--scribe": options.scribe = true
      case "--models": options.listModels = true
      case "--server":
        guard let server = URL(string: try value(flag)).flatMap(InviteLink.serverRoot) else {
          throw EngineError("--server needs an https address")
        }
        options.server = server
      case "--token-file": options.tokenFile = URL(fileURLWithPath: try value(flag))
      case "--help", "-h": return nil
      default: throw EngineError("unknown option \(flag) (see --help)")
      }
    }
    if options.configs.isEmpty {
      options.configs = try ["mistral", "openai"].map(BenchConfig.parse)
    }
    if options.configs.contains(where: \.viaServer), options.server == nil {
      throw EngineError("the server configuration needs --server")
    }
    return options
  }
}

/// Saved next to the Markdown report with --out.
struct SavedRun: Codable {
  var date: Date
  var runs: Int
  var clips: [String]
  var configs: [String: PipelineSettings]
  var results: [SessionResult]
}

struct Bench: Sendable {
  let endpoints: [ProviderID: ProviderEndpoint]
  let http: URLSessionHTTPClient
  let connector: URLSessionWebSocketConnector
  let vocabulary: [VocabularyEntry]
  let server: URL?
  let token: String?
  /// Like the app's per-install key: the cleanup prompt prefix stays cached between dictations.
  let cacheKey = UUID().uuidString.lowercased()
  /// The context the old Worker bench used: a chat app.
  let context = DictationContext(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "bench")

  func services(_ pipeline: PipelineSettings) -> DictationServices {
    let transcription = pipeline.transcription.provider
    let cleanup = endpoints[pipeline.cleanup.provider].map { ProviderClients.chat(pipeline.cleanup.provider, endpoint: $0, http: http) }
    let scribe = endpoints[pipeline.scribe.provider].map { ProviderClients.chat(pipeline.scribe.provider, endpoint: $0, http: http) }
    return DictationServices(
      transcription: ProviderClients.transcription(
        transcription, endpoint: endpoints[transcription] ?? .direct(transcription, apiKey: ""), http: http, connector: connector),
      cleanup: cleanup ?? scribe!, scribe: scribe ?? cleanup!)
  }

  /// Services for one session: direct, or through the organization's server (counted as Verify).
  private func session(_ config: BenchConfig, chatOnly: Bool) async -> (DictationServices, RelayConnection?) {
    guard config.viaServer, let server, let token else { return (services(config.pipeline), nil) }
    let sessionId = UUID().uuidString.lowercased()
    let relay = RelayConnection.open(server: server, token: token, connector: connector)
    if chatOnly { await relay.start(sessionId: sessionId, sampleRate: nil, language: nil, vocabulary: [], purpose: .verify) }
    return (RelayServices.services(config.pipeline, relay: relay, server: server, sessionId: sessionId, purpose: .verify), relay)
  }

  private static func serverTimings(_ relay: RelayConnection, into result: inout SessionResult) async {
    if let transcript = await relay.transcriptResult {
      result.serverPath = transcript.path
      if let ms = transcript.timings["transcribeMs"] { result.timings["serverTranscribeMs"] = ms }
    }
    for (key, value) in await relay.lastChatTimings {
      result.timings["server" + key.prefix(1).uppercased() + key.dropFirst()] = value
    }
    await relay.close()
  }

  /// One dictation as the app does it: streaming opened at the key press, audio at real-time
  /// pace, then the release.
  func measure(_ config: BenchConfig, _ clip: Clip, pcm: Data, run: Int) async -> SessionResult {
    let rate = DictationRun.sampleRate(for: config.pipeline)
    var result = SessionResult(config: config.label, clip: clip.id, run: run, audioMs: pcm.count * 1000 / (rate * 2))
    let request = DictationRequest(
      mode: .dictation, context: context, language: clip.dictationLanguage, vocabulary: vocabulary, cacheKey: cacheKey)
    let (services, relay) = await session(config, chatOnly: false)
    let dictation = DictationRun(request: request, settings: config.pipeline, services: services)
    let block = rate * 2 / 10
    let clock = ContinuousClock()
    do {
      await dictation.start()
      let start = clock.now
      var blocks = 0
      for offset in stride(from: 0, to: pcm.count, by: block) {
        try await Task.sleep(until: start + .milliseconds(100 * blocks), clock: .continuous)
        try await dictation.append(pcm.subdata(in: offset..<min(offset + block, pcm.count)))
        blocks += 1
      }
      try await Task.sleep(until: start + .milliseconds(100 * blocks), clock: .continuous)
      let released = clock.now
      let output = try await dictation.finish()
      result.endToResultMs = Self.milliseconds(clock.now - released)
      result.timings = output.timings
      result.transcription = output.transcription.rawValue
      result.processing = output.processing.rawValue
      result.raw = output.raw
      result.text = output.text
      result.warnings = output.warnings
      result.discarded = output.discardedCleanup
      result.termsTotal = clip.terms.count
      result.termsFound = clip.terms.filter { BenchStats.contains(output.text, term: $0) }.count
      if !clip.text.isEmpty {
        (result.wordErrors, result.referenceWords) = BenchStats.wordErrors(reference: clip.text, hypothesis: output.raw)
      }
      if let cleanup = BenchStats.bestErrors(clip.expected, output.text, tokens: BenchStats.words) {
        (result.cleanupErrors, result.cleanupWords) = cleanup
      }
      if let strict = BenchStats.bestErrors(clip.expected, output.text, tokens: BenchStats.strictTokens) {
        (result.strictErrors, result.strictTokens) = strict
      }
    } catch {
      await dictation.cancel()
      result.error = errorMessage(error)
    }
    if let relay { await Self.serverTimings(relay, into: &result) }
    return result
  }

  /// One Scribe draft: the app's real request, timed from sending it.
  func measureScribe(_ config: BenchConfig, _ task: ScribeTask, run: Int) async -> SessionResult {
    var result = SessionResult(config: config.label, clip: task.id, run: run, audioMs: 0)
    let (services, relay) = await session(config, chatOnly: true)
    let input = Prompts.ScribeInput(
      userName: "Ada Lovelace", appName: task.appName, windowTitle: nil, category: task.category,
      style: Categories.style(for: task.category), dictionary: Vocabulary.promptList(vocabulary), instruction: task.instruction,
      selectedText: task.selectedText)
    do {
      let stream = try await services.scribe.stream(Scribe.call(input, settings: config.pipeline.scribe), timeout: 90, onDelta: nil)
      result.endToResultMs = stream.totalMs
      if let ttft = stream.ttftMs { result.timings["scribeTtftMs"] = ttft }
      result.timings["scribeMs"] = stream.totalMs
      result.processing = stream.finishReason ?? "?"
      result.text = stream.text
      result.flags = task.flags(for: stream.text)
    } catch {
      result.error = errorMessage(error)
    }
    if let relay { await Self.serverTimings(relay, into: &result) }
    return result
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
  }
}

@main
enum DiVoiceBench {
  static func main() async {
    do {
      guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(usage)
        return
      }
      try await run(options)
    } catch {
      FileHandle.standardError.write(Data("divoice-bench: \(errorMessage(error))\n".utf8))
      exit(1)
    }
  }

  /// The organization's models, from the server: the "server" configuration uses them.
  static func serverPipeline(_ server: URL, token: String, session: URLSession) async throws -> PipelineSettings {
    struct Me: Decodable { var pipeline: PipelineSettings }
    var request = URLRequest(url: server.appendingPathComponent("v2/me"))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw EngineError("the server refused the token (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
    }
    return try JSONDecoder().decode(Me.self, from: data).pipeline
  }

  static func run(_ options: Options) async throws {
    var options = options
    if options.listModels { options.scribe = true }
    var clips = try options.clipsFolder.map(Clips.load) ?? Clips.builtIn
    if !options.only.isEmpty { clips = clips.filter { options.only.contains($0.id) } }
    let tasks = options.only.isEmpty ? ScribeTask.all : ScribeTask.all.filter { options.only.contains($0.id) }
    guard options.scribe ? !tasks.isEmpty : !clips.isEmpty else { throw EngineError("nothing to run") }

    // Keys and token first, so any macOS prompt comes before the measurements.
    var endpoints: [ProviderID: ProviderEndpoint] = [:]
    for provider in ProviderID.allCases where options.configs.contains(where: { $0.providers(scribe: options.scribe).contains(provider) }) {
      guard let key = Keys.key(provider) else {
        throw EngineError("no \(provider.displayName) key: set \(provider.rawValue.uppercased())_API_KEY or save it in diVoice")
      }
      endpoints[provider] = .direct(provider, apiKey: key)
    }

    // One session for everything, as in the app: connections stay warm between dictations.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpMaximumConnectionsPerHost = 6
    let session = URLSession(configuration: configuration)

    if options.listModels {
      for (provider, endpoint) in endpoints.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        var request = URLRequest(url: provider.defaultBaseURL.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        let models = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? [])
          .compactMap { $0["id"] as? String }.sorted()
        print("\(provider.displayName): \(models.joined(separator: ", "))")
      }
      return
    }

    var token: String?
    if let server = options.server, options.configs.contains(where: \.viaServer) {
      let fromFile = options.tokenFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
      guard let value = (fromFile ?? ProcessInfo.processInfo.environment["DIVOICE_TOKEN"])?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else { throw EngineError("the server configuration needs --token-file or DIVOICE_TOKEN") }
      token = value
      let pipeline = RelayServices.clientPipeline(try await serverPipeline(server, token: value, session: session))
      options.configs = options.configs.map { $0.viaServer ? BenchConfig(label: $0.label, pipeline: pipeline, viaServer: true) : $0 }
    }

    let terms = clips.flatMap(\.terms).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    let bench = Bench(
      endpoints: endpoints, http: URLSessionHTTPClient(session: session), connector: URLSessionWebSocketConnector(session: session),
      vocabulary: terms.map { VocabularyEntry(term: $0) }, server: options.server, token: token)

    let results = options.scribe ? await runScribe(bench, options, tasks) : try await runDictations(bench, options, clips)
    let labels = options.configs.map(\.label)
    let report =
      options.scribe
      ? Report.scribeMarkdown(results, configs: labels, tasks: tasks.map(\.id), runs: options.runs, date: Date())
      : Report.markdown(results, configs: labels, clips: clips.map(\.id), runs: options.runs, date: Date())
    print("\n" + report)
    if let out = options.out {
      try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(report.utf8).write(to: out)
      let saved = SavedRun(
        date: Date(), runs: options.runs, clips: options.scribe ? tasks.map(\.id) : clips.map(\.id),
        configs: Dictionary(uniqueKeysWithValues: options.configs.map { ($0.label, $0.pipeline) }), results: results)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(saved).write(to: out.deletingPathExtension().appendingPathExtension("json"))
      print("Saved \(out.path) and the raw results next to it.")
    }
  }

  static func runDictations(_ bench: Bench, _ options: Options, _ clips: [Clip]) async throws -> [SessionResult] {
    // Audio for every clip at every sample rate in use.
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("divoice-bench")
    var audio: [String: Data] = [:]
    for rate in Set(options.configs.map { DictationRun.sampleRate(for: $0.pipeline) }) {
      for clip in clips { audio["\(clip.id)@\(rate)"] = try Clips.pcm(clip, sampleRate: rate, cache: cache) }
    }
    func pcm(_ clip: Clip, _ config: BenchConfig) -> Data {
      audio["\(clip.id)@\(DictationRun.sampleRate(for: config.pipeline))"]!
    }

    let audioSeconds = clips.reduce(0) { $0 + pcm($1, options.configs[0]).count } / (DictationRun.sampleRate(for: options.configs[0].pipeline) * 2)
    print("\(clips.count) clips (\(audioSeconds) s of audio) × \(options.runs) runs × \(options.configs.count) configurations")
    for config in options.configs {
      print("warming up \(config.label)…")
      _ = await bench.measure(config, clips[0], pcm: pcm(clips[0], config), run: 0)
    }

    let width = max(18, clips.map(\.id.count).max() ?? 0)
    let configWidth = max(10, options.configs.map(\.label.count).max() ?? 0)
    var results: [SessionResult] = []
    for run in 1...options.runs {
      for clip in clips {
        for config in options.configs {
          let result = await bench.measure(config, clip, pcm: pcm(clip, config), run: run)
          results.append(result)
          print(line(result, run: run, of: options.runs, width: width, configWidth: configWidth))
          if options.verbose, result.error == nil {
            print("      raw:      \(result.raw)")
            print("      text:     \(result.text)")
            if result.cleanupErrors > 0, let expected = clip.expected.first { print("      expected: \(expected)") }
            if let discarded = result.discarded { print("      discarded: \(discarded)") }
          }
        }
      }
    }
    return results
  }

  static func runScribe(_ bench: Bench, _ options: Options, _ tasks: [ScribeTask]) async -> [SessionResult] {
    print("\(tasks.count) Scribe drafts × \(options.runs) runs × \(options.configs.count) configurations")
    for config in options.configs {
      print("warming up \(config.label)…")
      _ = await bench.measureScribe(config, tasks[0], run: 0)
    }
    let configWidth = max(10, options.configs.map(\.label.count).max() ?? 0)
    var results: [SessionResult] = []
    for run in 1...options.runs {
      for task in tasks {
        for config in options.configs {
          let result = await bench.measureScribe(config, task, run: run)
          results.append(result)
          let head = "\(run)/\(options.runs)  \(pad(task.id, 9))  \(pad(config.label, configWidth))"
          if let error = result.error {
            print("\(head)  ERROR \(error)")
            continue
          }
          var parts = [
            "first token \(Report.ms(result.timings["scribeTtftMs"])) ms", "total \(Report.ms(result.endToResultMs)) ms",
            "end: \(result.processing ?? "?")", "\(result.text.count) chars",
          ]
          if !result.flags.isEmpty { parts.append("⚠︎ \(result.flags.joined(separator: ", "))") }
          if let headers = result.timings["serverHeadersMs"] { parts.append("server: provider headers \(Report.ms(headers)) ms") }
          print("\(head)  \(parts.joined(separator: "  "))")
          if options.verbose { print("      \(result.text.replacingOccurrences(of: "\n", with: " ⏎ "))") }
        }
      }
    }
    return results
  }

  static func line(_ result: SessionResult, run: Int, of runs: Int, width: Int, configWidth: Int) -> String {
    let head = "\(run)/\(runs)  \(pad(result.clip, width))  \(pad(result.config, configWidth))"
    if let error = result.error { return "\(head)  ERROR \(error)" }
    var parts = ["\(pad(Report.ms(result.endToResultMs), 5, left: true)) ms"]
    parts.append("transcription \(Report.ms(result.timings["transcribeMs"])) \(result.serverPath ?? result.transcription ?? "")")
    parts.append("cleanup \(Report.ms(result.timings["cleanupMs"])) \(result.processing ?? "")")
    if let headers = result.timings["serverHeadersMs"] {
      parts.append("server: transcription \(Report.ms(result.timings["serverTranscribeMs"])), provider headers \(Report.ms(headers))")
    }
    if result.termsTotal > 0 { parts.append("terms \(result.termsFound)/\(result.termsTotal)") }
    if !result.warnings.isEmpty { parts.append("⚠︎ \(result.warnings.joined(separator: "; "))") }
    return "\(head)  \(parts.joined(separator: "  "))"
  }

  static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - text.count))
    return left ? fill + text : text + fill
  }
}
