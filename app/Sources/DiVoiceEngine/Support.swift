import DiVoiceCore
import Foundation

/// Milliseconds on a monotonic clock. Injected so tests can control time.
public typealias EngineClock = @Sendable () -> Double

public enum EngineClocks {
  public static let monotonic: EngineClock = { Double(MonotonicClock.nowNs()) / 1_000_000 }
}

/// An error with a message meant for logs and for the user.
public struct EngineError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = TextTools.redactSecrets(message)
  }

  public var errorDescription: String? { message }
  public var description: String { message }
}

/// A non-2xx HTTP response from a provider.
public struct HTTPStatusError: Error, LocalizedError, Sendable {
  public let label: String
  public let status: Int
  public let body: String

  public var errorDescription: String? {
    let detail = Self.providerMessage(body) ?? TextTools.collapseWhitespace(body)
    return TextTools.redactSecrets("\(label): HTTP \(status) \(detail.prefix(300))").trimmingCharacters(in: .whitespaces)
  }

  /// The message in a provider's JSON error body: OpenAI `error.message`, Mistral `message` or `detail`.
  static func providerMessage(_ body: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
    if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
    for key in ["error", "message", "detail"] {
      if let message = object[key] as? String { return message }
    }
    return nil
  }
}

/// The message of any error, without Foundation's long prefixes when we wrote it ourselves.
public func errorMessage(_ error: Error) -> String {
  if let error = error as? LocalizedError, let description = error.errorDescription { return description }
  return error.localizedDescription
}

/// A value delivered once and awaited by any number of tasks. Waiters stop on cancellation.
final class OneShot<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

  /// Returns false if a result was already delivered.
  @discardableResult
  func fulfill(_ result: Result<Value, Error>) -> Bool {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return false
    }
    self.result = result
    let pending = waiters
    waiters = [:]
    lock.unlock()
    for continuation in pending.values { continuation.resume(with: result) }
    return true
  }

  var isFulfilled: Bool {
    lock.withLock { result != nil }
  }

  func value() async throws -> Value {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
        lock.lock()
        if let result {
          lock.unlock()
          continuation.resume(with: result)
        } else if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[id] = continuation
          lock.unlock()
        }
      }
    } onCancel: {
      lock.lock()
      let continuation = waiters.removeValue(forKey: id)
      lock.unlock()
      continuation?.resume(throwing: CancellationError())
    }
  }
}

/// Runs `operation` with a deadline; the operation is cancelled when the deadline passes.
func withTimeout<T: Sendable>(
  _ seconds: Double,
  _ label: String,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      throw EngineError("\(label): timeout after \(Int(seconds * 1000)) ms")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw CancellationError() }
    return first
  }
}

/// Mutable state shared with `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }

  var current: Value {
    lock.withLock { value }
  }
}
