import Combine
import DiVoiceCore
import Foundation

struct HistoryEntry: Codable, Identifiable {
  let id: String
  let date: Date
  let mode: String
  let appName: String?
  let category: String
  let text: String
  let raw: String
  let transcription: String
  let cleanup: String
  var totalMs: Double?
  var clientTimings: [String: Double]
  /// Pipeline timings (transcription, cleanup...). Stored as "serverTimings" for older histories.
  var pipelineTimings: [String: Double]

  enum CodingKeys: String, CodingKey {
    case id, date, mode, appName, category, text, raw, transcription, cleanup, totalMs, clientTimings
    case pipelineTimings = "serverTimings"
  }
}

/// Local history (7 days, at most 500 entries). Stays only on this Mac.
final class HistoryStore: ObservableObject {
  static let shared = HistoryStore()

  @Published private(set) var entries: [HistoryEntry] = []
  private let url: URL
  private let ioQueue = DispatchQueue(label: "app.wibo.divoice.history")

  /// Sample dictations for the screenshots: nothing is read, and nothing is written where the real history is.
  init(preview entries: [HistoryEntry]) {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("divoice-preview-history.json")
    self.entries = entries
  }

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DiVoice", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = base.appendingPathComponent("history.json")
    if let data = try? Data(contentsOf: url) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }
    prune()
  }

  var last: HistoryEntry? { entries.first }

  func add(_ entry: HistoryEntry) {
    entries.insert(entry, at: 0)
    prune()
    save()
  }

  /// Settings › History › Clear history. The statistics, which have no text, stay.
  func clear() {
    entries = []
    save()
  }

  /// Latency of the last 100 dictations (not Scribe), in milliseconds.
  var latency: (p50: Double?, p95: Double?, count: Int) {
    let values = entries.filter { $0.mode == DictationMode.dictation.rawValue }.prefix(100).compactMap(\.totalMs)
    return (Stats.percentile(values, 50), Stats.percentile(values, 95), values.count)
  }

  private func prune() {
    let limit = Date().addingTimeInterval(-7 * 86_400)
    entries = Array(entries.filter { $0.date >= limit }.prefix(500))
  }

  private func save() {
    let snapshot = entries
    let url = url
    ioQueue.async {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(snapshot) else { return }
      try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
  }
}

enum Format {
  static func seconds(_ ms: Double?) -> String {
    guard let ms else { return "—" }
    return (ms / 1000).formatted(.number.precision(.fractionLength(2))) + " s"
  }

  /// "2h 5m", "4m 30s": time saved and similar.
  static func duration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: seconds) ?? "—"
  }
}
