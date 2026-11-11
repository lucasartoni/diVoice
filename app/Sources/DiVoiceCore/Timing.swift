import Foundation

/// Monotonic clock in nanoseconds (uptime, like event timestamps).
public enum MonotonicClock {
  public static func nowNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }

  /// Converts a CGEvent timestamp to uptime nanoseconds.
  ///
  /// The documentation says nanoseconds, but on some Macs the value is in ticks
  /// of `mach_absolute_time`. The interpretation closest to "now" and not in the
  /// future is chosen; if neither is plausible, the current instant is used.
  public static func eventUptimeNs(
    _ timestamp: UInt64,
    nowNs: UInt64,
    timebaseNumer: UInt32,
    timebaseDenom: UInt32
  ) -> UInt64 {
    let slack: UInt64 = 5_000_000
    let maxAge: UInt64 = 2_000_000_000
    let asTicks = timebaseDenom == 0
      ? timestamp
      : UInt64((Double(timestamp) * Double(timebaseNumer) / Double(timebaseDenom)).rounded())
    let candidates = [timestamp, asTicks].filter { $0 <= nowNs + slack && nowNs - min($0, nowNs) <= maxAge }
    guard let best = candidates.min(by: { distance($0, nowNs) < distance($1, nowNs) }) else { return nowNs }
    return min(best, nowNs)
  }

  private static func distance(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a > b ? a - b : b - a
  }
}

/// Instants of a dictation, all in uptime nanoseconds.
public struct DictationTimeline: Sendable, Equatable {
  public var pressNs: UInt64
  public var firstAudioNs: UInt64?
  public var releaseNs: UInt64?
  public var endSentNs: UInt64?
  public var resultNs: UInt64?
  public var pastePostedNs: UInt64?
  /// The target app read the text from the pasteboard.
  public var insertedNs: UInt64?

  public init(pressNs: UInt64) {
    self.pressNs = pressNs
  }

  private static func ms(_ from: UInt64?, _ to: UInt64?) -> Double? {
    guard let from, let to, to >= from else { return nil }
    return Double(to - from) / 1_000_000
  }

  /// From the key release to the inserted text (or, if the read wasn't seen, to the paste).
  public var totalMs: Double? {
    Self.ms(releaseNs, insertedNs ?? pastePostedNs)
  }

  public var metrics: [String: Double] {
    var out: [String: Double] = [:]
    out["pressToFirstAudioMs"] = Self.ms(pressNs, firstAudioNs)
    out["releaseToEndSentMs"] = Self.ms(releaseNs, endSentNs)
    out["releaseToResultMs"] = Self.ms(releaseNs, resultNs)
    out["releaseToPasteMs"] = Self.ms(releaseNs, pastePostedNs)
    out["releaseToInsertedMs"] = Self.ms(releaseNs, insertedNs)
    out["resultToInsertedMs"] = Self.ms(resultNs, insertedNs)
    return out.mapValues { ($0 * 10).rounded() / 10 }
  }
}

public enum Stats {
  /// "Nearest rank" percentile, the same one used by the backend and the bench.
  public static func percentile(_ values: [Double], _ p: Double) -> Double? {
    let sorted = values.filter { $0.isFinite }.sorted()
    guard !sorted.isEmpty else { return nil }
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
    return sorted[max(0, min(sorted.count - 1, rank))]
  }
}
