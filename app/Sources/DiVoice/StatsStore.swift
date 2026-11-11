import Combine
import DiVoiceCore
import DiVoiceEngine
import Foundation

/// Daily dictation totals on this Mac (Application Support/DiVoice/stats.json): counts only, no text.
final class StatsStore: ObservableObject {
  static let shared = StatsStore()

  @Published private(set) var days: [String: DayTotals] = [:]
  private let url: URL
  private let ioQueue = DispatchQueue(label: "app.wibo.divoice.stats")

  /// Sample totals for the screenshots: nothing is read or written.
  init(preview days: [String: DayTotals]) {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("divoice-preview-stats.json")
    self.days = days
  }

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DiVoice", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = base.appendingPathComponent("stats.json")
    if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: DayTotals].self, from: data) {
      days = saved
    }
  }

  /// Adds a finished dictation to today's totals.
  func record(words: Int, audioMs: Int, date: Date = Date()) {
    let key = DictationStats.dayKey(date)
    days[key, default: DayTotals()] = days[key, default: DayTotals()] + DayTotals(words: words, audioMs: audioMs, dictations: 1)
    save()
  }

  /// First launch with statistics: the local history (7 days) becomes the starting totals.
  func importHistoryIfNeeded(_ history: [HistoryEntry]) {
    guard days.isEmpty, !UserDefaults.standard.bool(forKey: "statsImported") else { return }
    UserDefaults.standard.set(true, forKey: "statsImported")
    for entry in history where !entry.text.isEmpty {
      let key = DictationStats.dayKey(entry.date)
      let audioMs = Int(entry.pipelineTimings["audioMs"] ?? 0)
      days[key, default: DayTotals()] = days[key, default: DayTotals()]
        + DayTotals(words: TextTools.wordCount(entry.text), audioMs: audioMs, dictations: 1)
    }
    save()
  }

  func summary(days count: Int?, typingWPM: Int) -> StatsSummary {
    DictationStats.summary(days, today: DictationStats.dayKey(Date()), days: count, typingWPM: typingWPM)
  }

  /// Words per day for the last `count` days, oldest first.
  func recentDays(_ count: Int) -> [(day: String, words: Int)] {
    let today = DictationStats.dayKey(Date())
    return (0..<count).reversed().compactMap { offset in
      let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
      let key = offset == 0 ? today : DictationStats.dayKey(date)
      return (key, days[key]?.words ?? 0)
    }
  }

  private func save() {
    let snapshot = days
    let url = url
    ioQueue.async {
      guard let data = try? JSONEncoder().encode(snapshot) else { return }
      try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
  }
}
