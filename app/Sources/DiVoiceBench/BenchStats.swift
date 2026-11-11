import Foundation

enum BenchStats {
  /// Nearest-rank percentile; nil without values.
  static func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  /// Lowercased words without punctuation, for comparing a transcript with the clip's text.
  static func words(_ text: String) -> [String] {
    let scalars = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return String(scalars).split(separator: " ").map(String.init)
  }

  /// Words with their case, and each punctuation mark as a token of its own: the strict
  /// comparison also counts capitals and punctuation.
  static func strictTokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var word = ""
    for character in text {
      if character.isLetter || character.isNumber {
        word.append(character)
        continue
      }
      if !word.isEmpty { tokens.append(word); word = "" }
      if character.isPunctuation || character.isSymbol { tokens.append(String(character)) }
    }
    if !word.isEmpty { tokens.append(word) }
    return tokens
  }

  /// Word-level edit distance between the reference and the transcript, and the reference length.
  static func wordErrors(reference: String, hypothesis: String) -> (errors: Int, words: Int) {
    editDistance(words(reference), words(hypothesis))
  }

  /// The comparison with the closest acceptable reference (lowest error rate).
  static func bestErrors(
    _ references: [String], _ hypothesis: String, tokens: (String) -> [String]
  ) -> (errors: Int, words: Int)? {
    let hyp = tokens(hypothesis)
    return references.map { editDistance(tokens($0), hyp) }.filter { $0.words > 0 }
      .min { Double($0.errors) / Double($0.words) < Double($1.errors) / Double($1.words) }
  }

  static func editDistance(_ ref: [String], _ hyp: [String]) -> (errors: Int, words: Int) {
    guard !ref.isEmpty else { return (hyp.count, 0) }
    var previous = Array(0...hyp.count)
    for i in 1...ref.count {
      var current = [i] + Array(repeating: 0, count: hyp.count)
      for j in stride(from: 1, through: hyp.count, by: 1) {
        let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
        current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
      }
      previous = current
    }
    return (previous[hyp.count], ref.count)
  }

  /// The term with its exact spelling, not inside a longer word.
  static func contains(_ text: String, term: String) -> Bool {
    let pattern = "(?<!\\p{L})\(NSRegularExpression.escapedPattern(for: term))(?!\\p{L})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
