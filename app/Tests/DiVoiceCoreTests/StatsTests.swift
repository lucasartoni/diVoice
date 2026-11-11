import DiVoiceCore
import Foundation
import Testing

@Suite("Statistics")
struct StatsTests {
  private let totals: [String: DayTotals] = [
    "2026-11-08": DayTotals(words: 120, audioMs: 60_000, dictations: 6),
    "2026-11-07": DayTotals(words: 80, audioMs: 30_000, dictations: 4),
    "2026-11-06": DayTotals(words: 40, audioMs: 20_000, dictations: 2),
    "2026-11-01": DayTotals(words: 400, audioMs: 120_000, dictations: 10),
  ]

  @Test func timeSavedIsTypingMinusSpeakingAndNeverNegative() {
    // 120 words at 40 wpm = 180 s of typing, 60 s spoken.
    #expect(DictationStats.savedSeconds(words: 120, audioMs: 60_000, typingWPM: 40) == 120)
    #expect(DictationStats.savedSeconds(words: 5, audioMs: 60_000, typingWPM: 40) == 0)
    #expect(DictationStats.savedSeconds(words: 5, audioMs: 1000, typingWPM: 0) == 0)
  }

  @Test func summaryOfTheLastDays() throws {
    let week = DictationStats.summary(totals, today: "2026-11-08", days: 7, typingWPM: 40)
    #expect(week.words == 240)
    #expect(week.dictations == 12)
    // 180-60 + 120-30 + 60-20
    #expect(week.savedSeconds == 250)
    #expect(try #require(week.wordsPerMinute) == 240 / (110_000.0 / 60_000))
    #expect(week.streakDays == 3)

    let all = DictationStats.summary(totals, today: "2026-11-08", days: nil, typingWPM: 40)
    #expect(all.words == 640)
    let today = DictationStats.summary(totals, today: "2026-11-08", days: 1, typingWPM: 40)
    #expect(today.words == 120)
  }

  @Test func streakSurvivesUntilMidnightAndBreaksOnAGap() {
    // Nothing yet today: yesterday's streak still counts.
    #expect(DictationStats.streak(totals, today: "2026-11-09") == 3)
    // A day without dictations ends it.
    #expect(DictationStats.streak(totals, today: "2026-11-10") == 0)
    #expect(DictationStats.streak([:], today: "2026-11-08") == 0)
  }

  @Test func streakCrossesMonthAndYearBoundaries() {
    let days: [String: DayTotals] = [
      "2027-01-01": DayTotals(words: 1, audioMs: 1, dictations: 1),
      "2026-12-31": DayTotals(words: 1, audioMs: 1, dictations: 1),
      "2026-12-30": DayTotals(words: 1, audioMs: 1, dictations: 1),
    ]
    #expect(DictationStats.streak(days, today: "2027-01-01") == 3)
  }

  @Test func dayKeyFollowsTheLocalTimeZone() throws {
    // 23:30 in Rome on 8 November is 22:30 UTC: the same instant falls on different local days elsewhere.
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-08T22:30:00Z"))
    #expect(DictationStats.dayKey(instant, timeZone: try #require(TimeZone(identifier: "Europe/Rome"))) == "2026-11-08")
    #expect(DictationStats.dayKey(instant, timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))) == "2026-11-09")
    #expect(DictationStats.dayKey(instant, timeZone: try #require(TimeZone(identifier: "America/New_York"))) == "2026-11-08")
  }
}
