import Foundation

/// Totals of one local day. No text is ever stored: only counts.
public struct DayTotals: Codable, Sendable, Equatable {
  public var words: Int
  public var audioMs: Int
  public var dictations: Int

  public init(words: Int = 0, audioMs: Int = 0, dictations: Int = 0) {
    self.words = words
    self.audioMs = audioMs
    self.dictations = dictations
  }

  public static func + (a: DayTotals, b: DayTotals) -> DayTotals {
    DayTotals(words: a.words + b.words, audioMs: a.audioMs + b.audioMs, dictations: a.dictations + b.dictations)
  }
}

public struct StatsSummary: Sendable, Equatable {
  public var words: Int
  public var dictations: Int
  /// Typing the same words at the user's typing speed, minus the time spent speaking.
  public var savedSeconds: Double
  /// Words per minute of speech.
  public var wordsPerMinute: Double?
  /// Consecutive days with at least one dictation, up to today (or yesterday, if today has none yet).
  public var streakDays: Int
}

/// Statistics from daily totals keyed by local day ("yyyy-MM-dd").
public enum DictationStats {
  /// The local day of `date` in `timeZone`, as stored.
  public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// The day key `offset` days before `key`.
  static func day(_ key: String, minus offset: Int) -> String? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
      let shifted = calendar.date(byAdding: .day, value: -offset, to: date)
    else { return nil }
    return dayKey(shifted, timeZone: calendar.timeZone)
  }

  /// Seconds saved by one batch of dictations: typing time minus speaking time, never negative.
  public static func savedSeconds(words: Int, audioMs: Int, typingWPM: Int) -> Double {
    guard typingWPM > 0 else { return 0 }
    return max(0, Double(words) / Double(typingWPM) * 60 - Double(audioMs) / 1000)
  }

  /// Summary of the last `days` days up to `today` (all days when nil).
  public static func summary(_ totals: [String: DayTotals], today: String, days: Int?, typingWPM: Int) -> StatsSummary {
    let keys: [String]
    if let days {
      keys = (0..<max(0, days)).compactMap { day(today, minus: $0) }
    } else {
      keys = Array(totals.keys)
    }
    var sum = DayTotals()
    var saved = 0.0
    for key in keys {
      guard let day = totals[key] else { continue }
      sum = sum + day
      saved += savedSeconds(words: day.words, audioMs: day.audioMs, typingWPM: typingWPM)
    }
    let minutes = Double(sum.audioMs) / 60_000
    return StatsSummary(
      words: sum.words, dictations: sum.dictations, savedSeconds: saved,
      wordsPerMinute: minutes > 0 ? Double(sum.words) / minutes : nil,
      streakDays: streak(totals, today: today))
  }

  public static func streak(_ totals: [String: DayTotals], today: String) -> Int {
    func active(_ key: String?) -> Bool { key.flatMap { totals[$0] }.map { $0.dictations > 0 } ?? false }
    // A streak is still alive today until midnight even if today has no dictation yet.
    var offset = active(today) ? 0 : 1
    var count = 0
    while active(day(today, minus: offset)) {
      count += 1
      offset += 1
    }
    return count
  }
}
