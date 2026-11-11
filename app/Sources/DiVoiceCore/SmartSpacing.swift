/// Adapts the text to where it is inserted, based on the characters before the cursor.
public enum SmartSpacing {
  public enum Insertion: String, Sendable {
    case start
    case mid
  }

  private static let sentenceEnd: Set<Character> = [".", "!", "?", "…", "\n", "\r"]
  private static let opening: Set<Character> = ["(", "[", "{", "\"", "'", "«", "“", "‘", "/", "@", "#", "\t"]
  private static let leadingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…", "»", "”", "’"]

  /// Start or middle of a sentence, looking at the text before the cursor (ignoring trailing spaces).
  public static func insertion(textBefore: String?) -> Insertion {
    guard let last = textBefore?.reversed().drop(while: { $0 == " " }).first else { return .start }
    return sentenceEnd.contains(last) ? .start : .mid
  }

  /// Adds a leading space if the cursor is right after a word or punctuation.
  public static func adjust(_ text: String, textBefore: String?) -> String {
    guard let first = text.first, let previous = textBefore?.last else { return text }
    if previous.isWhitespace || opening.contains(previous) { return text }
    if leadingPunctuation.contains(first) || first.isWhitespace { return text }
    return " " + text
  }
}
