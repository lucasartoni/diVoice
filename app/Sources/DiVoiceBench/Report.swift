import Foundation

/// One measured dictation.
struct SessionResult: Codable, Equatable {
  var config: String
  var clip: String
  var run: Int
  var audioMs: Int
  /// From the release (end of audio) to the final text.
  var endToResultMs: Double?
  var timings: [String: Double] = [:]
  var transcription: String?
  /// Through the organization's server: the path it chose (batch, realtime, fallbacks).
  var serverPath: String?
  /// Cleanup path, or for Scribe the stream's finish reason ("length" = cut off).
  var processing: String?
  var raw: String = ""
  var text: String = ""
  var termsFound: Int = 0
  var termsTotal: Int = 0
  var wordErrors: Int = 0
  var referenceWords: Int = 0
  /// Final text against the closest expected text: words only, then with case and punctuation.
  var cleanupErrors: Int = 0
  var cleanupWords: Int = 0
  var strictErrors: Int = 0
  var strictTokens: Int = 0
  var warnings: [String] = []
  /// A cleanup answer the guards rejected.
  var discarded: String?
  /// Scribe quality: "executed" (carried out instead of edited), "added" (numbers), "missing" (facts).
  var flags: [String] = []
  var error: String?

  /// A fallback path or a cleanup that fell back to the raw transcript.
  var fellBack: Bool {
    transcription?.hasSuffix("_fallback") == true || processing == "fast_fallback"
  }
}

enum Report {
  static let columns = [
    "Configuration", "n", "end→text p50", "p95", "transcription p50", "cleanup p50", "cleanup TTFT p50", "connect p50",
    "raw WER", "cleanup WER", "strict", "terms", "fallbacks", "errors",
  ]

  static func summaryRow(_ config: String, _ results: [SessionResult]) -> [String] {
    let ok = results.filter { $0.error == nil }
    func p(_ key: String, _ percent: Double = 50) -> String {
      ms(BenchStats.percentile(ok.compactMap { $0.timings[key] }, percent))
    }
    let total = ok.compactMap(\.endToResultMs)
    let errors = ok.reduce(0) { $0 + $1.wordErrors }
    let words = ok.reduce(0) { $0 + $1.referenceWords }
    let cleanupErrors = ok.reduce(0) { $0 + $1.cleanupErrors }
    let cleanupWords = ok.reduce(0) { $0 + $1.cleanupWords }
    let strictErrors = ok.reduce(0) { $0 + $1.strictErrors }
    let strictTokens = ok.reduce(0) { $0 + $1.strictTokens }
    let found = ok.reduce(0) { $0 + $1.termsFound }
    let terms = ok.reduce(0) { $0 + $1.termsTotal }
    return [
      config, "\(ok.count)",
      ms(BenchStats.percentile(total, 50)), ms(BenchStats.percentile(total, 95)),
      p("transcribeMs"), p("cleanupMs"), p("cleanupTtftMs"), p("upstreamConnectMs"),
      percent(errors, words), percent(cleanupErrors, cleanupWords), percent(strictErrors, strictTokens),
      terms > 0 ? "\(found)/\(terms)" : "—",
      "\(ok.filter(\.fellBack).count)",
      "\(results.count - ok.count)",
    ]
  }

  /// Cleanup WER per clip (rows) and configuration (columns), over all runs.
  static func cleanupTable(_ results: [SessionResult], configs: [String], clips: [String]) -> String {
    let rows = clips.map { clip in
      [clip] + configs.map { config in
        let ok = results.filter { $0.clip == clip && $0.config == config && $0.error == nil }
        return percent(ok.reduce(0) { $0 + $1.cleanupErrors }, ok.reduce(0) { $0 + $1.cleanupWords })
      }
    }
    return table(["Clip"] + configs, rows)
  }

  /// Median end→text per clip (rows) and configuration (columns).
  static func clipTable(_ results: [SessionResult], configs: [String], clips: [String]) -> String {
    var rows: [[String]] = []
    for clip in clips {
      let audio = results.first { $0.clip == clip }.map { String(format: "%.1f s", Double($0.audioMs) / 1000) } ?? "—"
      rows.append([clip, audio] + configs.map { config in
        ms(BenchStats.percentile(results.filter { $0.clip == clip && $0.config == config }.compactMap(\.endToResultMs), 50))
      })
    }
    return table(["Clip", "audio"] + configs, rows)
  }

  static func markdown(_ results: [SessionResult], configs: [String], clips: [String], runs: Int, date: Date) -> String {
    let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
    return """
      # divoice-bench, \(day)

      \(clips.count) clips × \(runs) runs per configuration. Audio streamed at real-time pace in 100 ms blocks; \
      times in ms from the release to the final text (paste excluded). Raw WER compares the transcript \
      before cleanup with the clip's text. Cleanup WER compares the final text with the closest expected \
      text, ignoring case and punctuation; strict also counts them. Terms are checked in the final text.

      \(table(columns, configs.map { config in summaryRow(config, results.filter { $0.config == config }) }))

      ## end→text p50 per clip

      \(clipTable(results, configs: configs, clips: clips))

      ## Cleanup WER per clip

      \(cleanupTable(results, configs: configs, clips: clips))

      """
  }

  static let scribeColumns = [
    "Configuration", "n", "first token p50", "p95", "total p50", "p95", "cut off", "executed", "added numbers", "missing facts", "chars (mean)",
    "errors",
  ]

  static func scribeRow(_ config: String, _ results: [SessionResult]) -> [String] {
    let ok = results.filter { $0.error == nil }
    func p(_ key: String, _ percent: Double) -> String { ms(BenchStats.percentile(ok.compactMap { $0.timings[key] }, percent)) }
    let chars = ok.isEmpty ? "—" : String(ok.reduce(0) { $0 + $1.text.count } / ok.count)
    return [
      config, "\(ok.count)", p("scribeTtftMs", 50), p("scribeTtftMs", 95), p("scribeMs", 50), p("scribeMs", 95),
      "\(ok.filter { $0.processing == "length" }.count)", "\(ok.filter { $0.flags.contains("executed") }.count)",
      "\(ok.filter { $0.flags.contains("added") }.count)", "\(ok.filter { $0.flags.contains("missing") }.count)", chars,
      "\(results.count - ok.count)",
    ]
  }

  static func scribeMarkdown(_ results: [SessionResult], configs: [String], tasks: [String], runs: Int, date: Date) -> String {
    let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
    return """
      # divoice-bench Scribe, \(day)

      \(tasks.count) drafts × \(runs) runs per configuration, with the app's real Scribe request. Times in ms from \
      sending the request; "cut off" counts answers that hit the length limit.

      \(table(scribeColumns, configs.map { config in scribeRow(config, results.filter { $0.config == config }) }))

      """
  }

  static func table(_ header: [String], _ rows: [[String]]) -> String {
    let lines = [header, header.map { _ in "---" }] + rows
    return lines.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
  }

  static func percent(_ errors: Int, _ total: Int) -> String {
    total > 0 ? String(format: "%.1f%%", Double(errors) / Double(total) * 100) : "—"
  }

  static func ms(_ value: Double?) -> String {
    value.map { String(Int($0.rounded())) } ?? "—"
  }
}
