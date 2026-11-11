import DiVoiceEngine
import Foundation
import Testing

@testable import DiVoiceBench

@Suite("Bench")
struct BenchTests {
  @Test func defaultConfigurationIsTheProviderDefaults() throws {
    let config = try BenchConfig.parse("openai")
    #expect(config.pipeline == .defaults(.openai))
    #expect(config.providers(scribe: false) == [.openai])
    let server = try BenchConfig.parse("server")
    #expect(server.viaServer)
    #expect(server.providers(scribe: false).isEmpty)
    #expect(config.pipeline.cleanup.fastTier)
    #expect(!(try BenchConfig.parse("openai,fast=off").pipeline.cleanup.fastTier))
  }

  @Test func optionsChangeThePipeline() throws {
    let config = try BenchConfig.parse("openai,mode=hybrid,stt=gpt-live-transcribe,cleanup=mistral/mistral-small-2603,fastpath=6")
    #expect(config.pipeline.transcription.mode == .hybrid)
    #expect(config.pipeline.transcription.realtimeModel == "gpt-live-transcribe")
    #expect(config.pipeline.transcription.batchModel == "gpt-live-transcribe")
    #expect(config.pipeline.cleanup.provider == .mistral)
    #expect(config.pipeline.cleanup.model == "mistral-small-2603")
    #expect(config.pipeline.fastPathMaxWords == 6)
    #expect(config.providers(scribe: false) == [.openai, .mistral])
    #expect(config.providers(scribe: true) == [.openai])

    let mistral = try BenchConfig.parse("mistral, mode=realtime, delay=240, prediction=off")
    #expect(mistral.pipeline.transcription.mode == .realtime)
    #expect(mistral.pipeline.transcription.delayMs == 240)
    #expect(!mistral.pipeline.cleanup.prediction)
    #expect(try BenchConfig.parse("openai,fast").pipeline.cleanup.fastTier)
  }

  @Test(arguments: ["", "whisper", "mistral,mode=fast", "mistral,delay=-1", "openai,fast=yes", "openai,cleanup=acme/x", "mistral,turbo"])
  func invalidConfigurationsAreRejected(_ spec: String) {
    #expect(throws: EngineError.self) { try BenchConfig.parse(spec) }
  }

  @Test func wordErrorsIgnoreCaseAndPunctuation() {
    #expect(BenchStats.wordErrors(reference: "Ci vediamo domani alle dieci.", hypothesis: "ci vediamo domani, alle dieci") == (0, 5))
    #expect(BenchStats.wordErrors(reference: "Ci vediamo domani alle dieci.", hypothesis: "Ci vediamo domani alle 10.") == (1, 5))
    #expect(BenchStats.wordErrors(reference: "Ho appena mandato la proposta", hypothesis: "Atena mandato la proposta") == (2, 5))
    #expect(BenchStats.wordErrors(reference: "Ottimo lavoro", hypothesis: "") == (2, 2))
  }

  @Test func termsNeedTheirExactSpellingAsAWholeWord() {
    #expect(BenchStats.contains("La proposta di Zentrix.", term: "Zentrix"))
    #expect(BenchStats.contains("Zentrix, poi Orbix", term: "Orbix"))
    #expect(!BenchStats.contains("la proposta di zentrix", term: "Zentrix"))
    #expect(!BenchStats.contains("ZentrixAI", term: "Zentrix"))
    #expect(BenchStats.contains("file index.ts (v2)", term: "index.ts"))
  }

  @Test func percentilesUseTheNearestRank() {
    let values: [Double] = [900, 100, 500, 300, 700]
    #expect(BenchStats.percentile(values, 50) == 500)
    #expect(BenchStats.percentile(values, 95) == 900)
    #expect(BenchStats.percentile([42], 50) == 42)
    #expect(BenchStats.percentile([], 50) == nil)
  }

  @Test func wavDataChunkIsFoundAfterOtherChunks() throws {
    func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    let samples: [UInt8] = [1, 2, 3, 4]
    var bytes: [UInt8] = Array("RIFF".utf8)
    bytes += le32(4 + 8 + 4 + 8 + samples.count)
    bytes += Array("WAVE".utf8)
    bytes += Array("LIST".utf8)
    bytes += le32(3)
    bytes += [9, 9, 9, 0]  // odd-sized chunk, padded
    bytes += Array("data".utf8)
    bytes += le32(samples.count)
    bytes += samples
    let wav = Data(bytes)
    #expect(try Clips.pcmData(wav: wav) == Data(samples))
    #expect(throws: EngineError.self) { try Clips.pcmData(wav: Data("not a wav".utf8)) }
  }

  @Test func builtInClipsAreNeutralAndConsistent() {
    #expect(Set(Clips.builtIn.map(\.id)).count == Clips.builtIn.count)
    for clip in Clips.builtIn {
      #expect(!clip.expected.isEmpty, "\(clip.id)")
      for term in clip.terms {
        #expect(BenchStats.contains(clip.text, term: term), "\(clip.id): \(term)")
        for expected in clip.expected { #expect(BenchStats.contains(expected, term: term), "\(clip.id): \(term)") }
      }
    }
    #expect(Clips.builtIn.contains { $0.id.contains("mixed") })
  }

  @Test func strictTokensKeepCaseAndPunctuation() {
    #expect(BenchStats.strictTokens("Ciao, ti confermo: alle 16:00.") == ["Ciao", ",", "ti", "confermo", ":", "alle", "16", ":", "00", "."])
    #expect(BenchStats.strictTokens("we're \"on\" track") == ["we", "'", "re", "\"", "on", "\"", "track"])
  }

  @Test func cleanupIsComparedWithTheClosestExpectedText() throws {
    let expected = ["Ci vediamo domani alle 10.", "Ci vediamo domani alle 10:00.", "Ci vediamo domani alle dieci."]
    #expect(try #require(BenchStats.bestErrors(expected, "Ci vediamo domani alle dieci.", tokens: BenchStats.words)) == (0, 5))
    #expect(try #require(BenchStats.bestErrors(expected, "ci vediamo domani alle 10:00", tokens: BenchStats.words)) == (0, 6))
    let strict = try #require(BenchStats.bestErrors(expected, "ci vediamo domani alle 10", tokens: BenchStats.strictTokens))
    #expect(strict == (2, 6))  // capital C and the final period
    #expect(BenchStats.bestErrors([], "x", tokens: BenchStats.words) == nil)
  }

  @Test func expectedTextIsAStringOrAList() throws {
    let json = Data(#"[{"id":"a","text":"Uno.","expected":"Uno!"},{"id":"b","text":"Due.","expected":["Due.","2."]},{"id":"c","text":"Tre."}]"#.utf8)
    let clips = try JSONDecoder().decode([Clip].self, from: json)
    #expect(clips.map(\.expected) == [["Uno!"], ["Due.", "2."], []])
    #expect(Clip(id: "d", text: "Quattro.", terms: []).expected == ["Quattro."])
  }

  @Test func scribeQualityFlags() throws {
    func task(_ id: String) throws -> ScribeTask { try #require(ScribeTask.all.first { $0.id == id }) }
    let prompt = try task("it-prompt-email")
    #expect(prompt.flags(for: "Scrivi un'email breve e cordiale a Marco per spostare a giovedì la call di domani.") == [])
    #expect(prompt.flags(for: "Ciao Marco, possiamo spostare la call di domani a giovedì? Grazie!") == ["executed"])
    let question = try task("it-question-db")
    #expect(question.flags(for: "Per un'app piccola che potrebbe crescere, conviene Postgres o SQLite?") == [])
    #expect(question.flags(for: "Postgres e SQLite vanno bene entrambi: per un'app piccola parti con SQLite.") == ["executed"])
    let message = try task("it-personal")
    #expect(message.flags(for: "Sara, stasera arriverei tardi, verso le dieci: facciamo sabato? Dimmi tu.") == [])
    #expect(message.flags(for: "Sara, stasera arrivo alle 22:30: facciamo sabato?") == ["added", "missing"])
    let code = try task("it-prompt-code")
    #expect(code.flags(for: "```python\ndef media(xs): ...\n```") == ["executed", "missing"])
    let translation = try task("sel-translate")
    #expect(translation.flags(for: "Hi all, tomorrow's meeting moved to 3:00 pm. Bring the Kestrel numbers.") == [])
    #expect(ScribeTask.all.filter { $0.kind != .rewrite }.count == 20)
    #expect(Set(ScribeTask.all.map(\.id)).count == ScribeTask.all.count)
  }

  @Test func reportSummarizesSuccessfulSessions() {
    var ok = SessionResult(config: "mistral", clip: "01", run: 1, audioMs: 2000, endToResultMs: 800)
    ok.timings = ["transcribeMs": 400, "cleanupMs": 350]
    ok.termsFound = 1
    ok.termsTotal = 2
    ok.wordErrors = 1
    ok.referenceWords = 10
    var fallback = ok
    fallback.endToResultMs = 1200
    fallback.transcription = "realtime_fallback"
    let failed = SessionResult(config: "mistral", clip: "02", run: 1, audioMs: 3000, error: "HTTP 500")
    let row = Report.summaryRow("mistral", [ok, fallback, failed])
    #expect(row == ["mistral", "2", "800", "1200", "400", "350", "—", "—", "10.0%", "—", "—", "2/4", "1", "1"])
    #expect(row.count == Report.columns.count)
  }
}
