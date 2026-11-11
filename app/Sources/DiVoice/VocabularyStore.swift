import Combine
import DiVoiceEngine
import Foundation

/// The personal dictionary, saved on this Mac (Application Support/DiVoice/dictionary.json).
final class VocabularyStore: ObservableObject {
  static let shared = VocabularyStore()

  @Published private(set) var entries: [VocabularyEntry] = []
  private let url: URL
  private let ioQueue = DispatchQueue(label: "app.wibo.divoice.dictionary")

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DiVoice", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = base.appendingPathComponent("dictionary.json")
    if let data = try? Data(contentsOf: url) {
      entries = (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
    }
  }

  /// Sample entries for the screenshots: nothing is read or written.
  init(preview entries: [VocabularyEntry]) {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("divoice-preview-dictionary.json")
    self.entries = entries
  }

  /// Validation rules of a dictionary entry.
  static func clean(term: String) -> String? {
    let value = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return (1...80).contains(value.count) ? value : nil
  }

  static func clean(aliases: [String]) -> [String] {
    var out: [String] = []
    for alias in aliases {
      let value = alias.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
      if (1...80).contains(value.count), !out.contains(value) { out.append(value) }
    }
    return Array(out.prefix(20))
  }

  /// Adds an entry, or merges the aliases into the existing one with the same term.
  @discardableResult
  func add(term: String, aliases: [String] = [], note: String? = nil, source: VocabularyEntry.Source = .manual) -> VocabularyEntry? {
    guard let term = Self.clean(term: term) else { return nil }
    let aliases = Self.clean(aliases: aliases)
    let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = entries.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) {
      entries[index].aliases = Self.clean(aliases: entries[index].aliases + aliases)
      if let note, !note.isEmpty { entries[index].note = String(note.prefix(200)) }
      save()
      return entries[index]
    }
    let entry = VocabularyEntry(
      term: term, aliases: aliases, note: note.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }, scope: .personal, source: source)
    entries.append(entry)
    entries.sort { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    save()
    return entry
  }

  func update(_ entry: VocabularyEntry) {
    guard let index = entries.firstIndex(where: { $0.id == entry.id }), let term = Self.clean(term: entry.term) else { return }
    var updated = entry
    updated.term = term
    updated.aliases = Self.clean(aliases: entry.aliases)
    entries[index] = updated
    save()
  }

  func remove(_ ids: Set<String>) {
    entries.removeAll { ids.contains($0.id) }
    save()
  }

  /// Counts the entries that appeared in a dictation: the most used get priority in the bias.
  func recordUsage(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    DispatchQueue.main.async {
      for id in ids {
        if let index = self.entries.firstIndex(where: { $0.id == id }) { self.entries[index].usageCount += 1 }
      }
      self.save()
    }
  }

  private func save() {
    let snapshot = entries
    let url = url
    ioQueue.async {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard let data = try? encoder.encode(snapshot) else { return }
      try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
  }
}
