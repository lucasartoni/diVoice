import Foundation

/// A dictionary entry: the correct spelling of a term and the wrong forms it gets transcribed as.
public struct VocabularyEntry: Codable, Sendable, Identifiable, Equatable, Hashable {
  public enum Scope: String, Codable, Sendable { case team, personal }
  public enum Source: String, Codable, Sendable { case seed, manual, learned }

  public var id: String
  public var term: String
  /// Wrong forms, lowercased.
  public var aliases: [String]
  public var note: String?
  public var scope: Scope
  public var source: Source
  public var enabled: Bool
  public var usageCount: Int

  public init(
    id: String = UUID().uuidString.lowercased(),
    term: String,
    aliases: [String] = [],
    note: String? = nil,
    scope: Scope = .personal,
    source: Source = .manual,
    enabled: Bool = true,
    usageCount: Int = 0
  ) {
    self.id = id
    self.term = term
    self.aliases = aliases
    self.note = note
    self.scope = scope
    self.source = source
    self.enabled = enabled
    self.usageCount = usageCount
  }
}

/// How the dictionary is used in the pipeline: bias for transcription, list for prompts,
/// deterministic replacement of known wrong forms.
public enum Vocabulary {
  private static func sourcePriority(_ source: VocabularyEntry.Source) -> Int {
    switch source {
    case .manual: 0
    case .seed: 1
    case .learned: 2
    }
  }

  /// Manual entries first, then seed, then learned; more used first; personal before team.
  static func byPriority(_ a: VocabularyEntry, _ b: VocabularyEntry) -> Bool {
    let sa = sourcePriority(a.source), sb = sourcePriority(b.source)
    if sa != sb { return sa < sb }
    if a.usageCount != b.usageCount { return a.usageCount > b.usageCount }
    let pa = a.scope == .personal ? 0 : 1, pb = b.scope == .personal ? 0 : 1
    if pa != pb { return pa < pb }
    return a.term.localizedCompare(b.term) == .orderedAscending
  }

  private static func prioritized(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
    entries.filter(\.enabled).sorted(by: byPriority)
  }

  /// Terms to bias the transcription towards, by priority and within a budget.
  public static func bias(_ entries: [VocabularyEntry], maxEntries: Int = 150, maxCharacters: Int = 3000) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    var characters = 0
    for entry in prioritized(entries) {
      let key = entry.term.lowercased()
      if seen.contains(key) { continue }
      let length = entry.term.utf16.count
      if out.count >= maxEntries || characters + length > maxCharacters { break }
      seen.insert(key)
      out.append(entry.term)
      characters += length
    }
    return out
  }

  /// The dictionary as a readable list for the prompts.
  public static func promptList(_ entries: [VocabularyEntry], maxEntries: Int = 150) -> String {
    var seen = Set<String>()
    var lines: [String] = []
    for entry in prioritized(entries) {
      let key = entry.term.lowercased()
      if seen.contains(key) || lines.count >= maxEntries { continue }
      seen.insert(key)
      var line = "- \(entry.term)"
      if let note = entry.note, !note.isEmpty { line += " (\(note))" }
      let aliases = entry.aliases.filter { $0.lowercased() != key }
      if !aliases.isEmpty { line += " — may be transcribed as: \(aliases.joined(separator: ", "))" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  private static func normalizedKey(_ text: String) -> String {
    TextTools.collapseWhitespace(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  /// A term or alias as a pattern that tolerates any whitespace between its words.
  private static func flexiblePattern(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .map { TextTools.escape(String($0)) }
      .joined(separator: "\\s+")
  }

  private static let before = "(?<![\\p{L}\\p{N}])"
  private static let after = "(?![\\p{L}\\p{N}])"

  /// Replaces known wrong forms with the correct spelling: one pass, longest aliases first,
  /// Unicode word boundaries, case insensitive.
  public static func applyAliases(_ text: String, _ entries: [VocabularyEntry]) -> String {
    var map: [String: String] = [:]
    for entry in entries where entry.enabled {
      for alias in entry.aliases {
        let key = normalizedKey(alias)
        if key.isEmpty || alias == entry.term || map[key] != nil { continue }
        map[key] = entry.term
      }
    }
    guard !map.isEmpty, !text.isEmpty else { return text }
    let alternatives = map.keys
      .sorted { $0.utf16.count > $1.utf16.count }
      .map(flexiblePattern)
      .joined(separator: "|")
    let regex = TextTools.regex("\(before)(?:\(alternatives))\(after)", ignoreCase: true)
    return TextTools.replace(regex, in: text) { match in map[normalizedKey(match)] ?? match }
  }

  /// Ids of the entries whose exact spelling appears in the text.
  public static func termsUsed(_ text: String, _ entries: [VocabularyEntry]) -> [String] {
    entries.filter(\.enabled).compactMap { entry in
      let regex = TextTools.regex("\(before)\(flexiblePattern(entry.term))\(after)")
      return TextTools.matches(regex, text) ? entry.id : nil
    }
  }
}
