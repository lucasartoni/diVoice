import Foundation
import Testing

@testable import DiVoiceEngine

private let entries = [entry("Zentrix", aliases: ["centrix"])]
private let raw = "ehm allora domani presentiamo centrix al cliente e poi ehm facciamo il punto"

private func request(_ settings: ChatSettings = .cleanupDefaults(.mistral), fastPathMaxWords: Int = 0, category: AppCategory = .workChat, appName: String? = "Slack", text: String = raw) -> Cleanup.Request {
  Cleanup.Request(
    raw: text, entries: entries, category: category, style: "diretto", appName: appName, insertion: .start,
    cacheKey: "u1", settings: settings, fastPathMaxWords: fastPathMaxWords)
}

private func client(_ http: FakeHTTP, _ provider: ProviderID = .mistral) -> ChatCompletionsClient {
  ChatCompletionsClient(provider: provider, endpoint: .direct(provider, apiKey: "k"), http: http)
}

@Suite struct CleanupTests {
  @Test func skipsTheModelForShortCleanSentences() {
    #expect(!Cleanup.needsModel("ci vediamo domani alle dieci", fastPathMaxWords: 12))
  }

  @Test func usesTheModelForLongSentencesFillersCorrectionsAndPunctuation() {
    #expect(Cleanup.needsModel("uno due tre quattro cinque sei sette otto nove dieci undici dodici tredici", fastPathMaxWords: 12))
    #expect(Cleanup.needsModel("ehm ci vediamo domani", fastPathMaxWords: 12))
    #expect(Cleanup.needsModel("alle tre anzi alle quattro", fastPathMaxWords: 12))
    #expect(Cleanup.needsModel("ciao virgola come stai", fastPathMaxWords: 12))
    #expect(Cleanup.needsModel("ci ci vediamo domani", fastPathMaxWords: 12))
    #expect(Cleanup.needsModel("ci vediamo domani", fastPathMaxWords: 0))
  }

  @Test func fastCleanAppliesAliasesAndCapitalizes() {
    #expect(Cleanup.fastClean("  la demo di centrix  ", entries: entries, category: .workChat) == "La demo di Zentrix")
  }

  @Test func fastCleanDropsTheFinalPeriodInPersonalChats() {
    #expect(Cleanup.fastClean("arrivo tra poco.", entries: entries, category: .personalChat) == "Arrivo tra poco")
    #expect(Cleanup.fastClean("arrivo tra poco...", entries: entries, category: .personalChat) == "Arrivo tra poco...")
    #expect(Cleanup.fastClean("arrivo tra poco.", entries: entries, category: .email) == "Arrivo tra poco.")
  }

  @Test func fastCleanKeepsLowercaseMidSentence() {
    #expect(Cleanup.fastClean("e poi centrix", entries: entries, category: .docs, insertion: .mid) == "e poi Zentrix")
  }

  @Test func mistralCallUsesPredictionNoReasoningAndCacheKey() async throws {
    let http = FakeHTTP(pieces: ["Domani presentiamo ", "centrix al cliente e poi facciamo il punto."])
    let result = await Cleanup.run(request(), chat: client(http))
    #expect(result.path == .llm)
    #expect(result.text == "Domani presentiamo Zentrix al cliente e poi facciamo il punto.")
    let call = try #require(http.requests.first)
    #expect(call.url == "https://api.mistral.ai/v1/chat/completions")
    #expect(call.headers["Authorization"] == "Bearer k")
    let body = call.json
    #expect(body["model"] as? String == "mistral-small-2603")
    #expect(body["stream"] as? Bool == true)
    #expect(body["temperature"] as? Double == 0)
    #expect(body["reasoning_effort"] as? String == "none")
    #expect(body["max_tokens"] as? Int == raw.utf16.count / 2 + 64)
    #expect((body["prediction"] as? [String: String]) == ["type": "content", "content": raw])
    #expect(body["prompt_cache_key"] as? String == "divoice-cleanup-u1")
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages[0]["content"]?.contains("- Zentrix") == true)
    #expect(messages[1]["content"]?.contains("Slack (Work chat)") == true)
    #expect(messages[1]["content"]?.contains(raw) == true)
  }

  @Test func openAICallUsesItsOwnParameters() async throws {
    let http = FakeHTTP(pieces: ["Domani presentiamo Zentrix al cliente e poi facciamo il punto."])
    var settings = ChatSettings.cleanupDefaults(.openai)
    settings.prediction = true
    settings.fastTier = true
    _ = await Cleanup.run(request(settings), chat: client(http, .openai))
    let call = try #require(http.requests.first)
    #expect(call.url == "https://api.openai.com/v1/chat/completions")
    let body = call.json
    #expect(body["model"] as? String == "gpt-6-luna")
    #expect(body["reasoning_effort"] as? String == "none")
    #expect(body["max_completion_tokens"] as? Int == raw.utf16.count / 2 + 64)
    #expect(body["max_tokens"] == nil)
    // Not accepted by the model: never sent, even when asked for.
    #expect(body["temperature"] == nil)
    #expect(body["prediction"] == nil)
    #expect(body["service_tier"] as? String == "fast")
  }

  @Test func readsContentBlocksAndStripsQuotes() async {
    let http = FakeHTTP(pieces: ["\"Domani presentiamo Zentrix al cliente e poi facciamo il punto.\""])
    http.contentBlocks = true
    let result = await Cleanup.run(request(category: .other, appName: nil), chat: client(http))
    #expect(result.text == "Domani presentiamo Zentrix al cliente e poi facciamo il punto.")
  }

  @Test func fallsBackWhenTheModelFailsOrAnswersOffTopic() async {
    let failing = FakeHTTP()
    failing.status = 500
    let failed = await Cleanup.run(request(category: .other), chat: client(failing))
    #expect(failed.path == .fastFallback)
    #expect(failed.error?.contains("HTTP 500") == true)
    #expect(failed.text.contains("Zentrix"))

    let chatty = FakeHTTP(pieces: [String(repeating: "Certo! Ecco una proposta dettagliata per la presentazione al cliente. ", count: 6)])
    let offTopic = await Cleanup.run(request(category: .other), chat: client(chatty))
    #expect(offTopic.path == .fastFallback)
  }

  @Test func doesNotCallTheModelForShortSentences() async {
    let http = FakeHTTP(pieces: ["x"])
    let result = await Cleanup.run(request(fastPathMaxWords: 12, category: .other, text: "ci vediamo da centrix"), chat: client(http))
    #expect(result.path == .fast)
    #expect(result.text == "Ci vediamo da Zentrix")
    #expect(http.requests.isEmpty)
  }

  @Test func noReasoningForMinistral() async throws {
    let http = FakeHTTP(pieces: ["Domani presentiamo Zentrix al cliente e poi facciamo il punto."])
    _ = await Cleanup.run(request(ChatSettings(provider: .mistral, model: "ministral-8b-2512")), chat: client(http))
    let body = try #require(http.requests.first).json
    #expect(body["reasoning_effort"] == nil)
    #expect(body["prediction"] == nil)
  }

  @Test func reasoningLevelRoundsUpToWhatTheModelAccepts() {
    let large = ModelCatalog.chatCapabilities(.mistral, "mistral-large-4-0")
    #expect(large.reasoning(for: .none) == .low)
    let sol = ModelCatalog.chatCapabilities(.openai, "gpt-6.1-sol")
    #expect(sol.reasoning(for: .none) == .low)
    #expect(ModelCatalog.chatCapabilities(.mistral, "ministral-3b-2512").reasoning(for: .low) == nil)
  }

  @Test func classifierLearnsOnlyTermsTakenFromTheCorrection() async throws {
    // It streams and reads the JSON leniently: an organization's server relays only streams.
    let http = FakeHTTP(pieces: ["```json\n", #"{"vocabulary":true,"#, #""term":"Zentrix"}"#, "\n```"])
    let chat = client(http)
    let term = try await CorrectionClassifier.learnedTerm(
      original: "centrix", corrected: "Zentrix", sentence: "La demo di Zentrix", settings: .cleanupDefaults(.mistral), chat: chat)
    #expect(term == "Zentrix")
    let body = try #require(http.requests.first).json
    #expect(body["response_format"] == nil)
    #expect(body["stream"] as? Bool == true)

    http.pieces = [#"{"vocabulary":true,"term":"Altro"}"#]
    let invented = try await CorrectionClassifier.learnedTerm(
      original: "centrix", corrected: "Zentrix", sentence: nil, settings: .cleanupDefaults(.mistral), chat: chat)
    #expect(invented == nil)
  }
}
