/// Mode of a voice session.
public enum DictationMode: String, Codable, Sendable {
  case dictation
  case scribe
}

/// CGEventFlags bits used here, without depending on CoreGraphics.
public enum EventFlag {
  public static let control: UInt64 = 0x0004_0000
  public static let secondaryFn: UInt64 = 0x0080_0000
  /// "Device dependent" bits that tell the right key from the left one.
  public static let rightCommand: UInt64 = 0x0000_0010
  public static let rightOption: UInt64 = 0x0000_0040
}

public enum KeyCode {
  public static let function: UInt16 = 63
  public static let rightCommand: UInt16 = 54
  public static let rightOption: UInt16 = 61
  public static let escape: UInt16 = 53
}

/// A modifier key that starts dictation while held down.
public struct HotkeyTrigger: Equatable, Hashable, Sendable {
  public let id: String
  public let keyCode: UInt16
  /// Flag bit present while the key is pressed.
  public let pressedMask: UInt64

  public init(id: String, keyCode: UInt16, pressedMask: UInt64) {
    self.id = id
    self.keyCode = keyCode
    self.pressedMask = pressedMask
  }

  public static let fn = HotkeyTrigger(id: "fn", keyCode: KeyCode.function, pressedMask: EventFlag.secondaryFn)
  public static let rightCommand = HotkeyTrigger(id: "rightCommand", keyCode: KeyCode.rightCommand, pressedMask: EventFlag.rightCommand)
  public static let rightOption = HotkeyTrigger(id: "rightOption", keyCode: KeyCode.rightOption, pressedMask: EventFlag.rightOption)

  public static let all: [HotkeyTrigger] = [.fn, .rightCommand, .rightOption]

  public static func byID(_ id: String) -> HotkeyTrigger? {
    all.first { $0.id == id }
  }
}

public enum KeyEvent: Equatable, Sendable {
  /// A modifier changed. `timestamp` in uptime nanoseconds.
  case flagsChanged(keyCode: UInt16, flags: UInt64, timestamp: UInt64)
  case keyDown(keyCode: UInt16, flags: UInt64, timestamp: UInt64)
}

public enum CancelReason: Equatable, Sendable {
  /// Press shorter than the threshold: a tap, not a dictation.
  case tooShort
  /// Another key pressed together: it was a shortcut (Fn+arrow, ⌘+C...).
  case otherKey
  case escape
}

public enum HotkeyAction: Equatable, Sendable {
  case start(DictationMode, timestamp: UInt64)
  case modeChanged(DictationMode)
  case stop(DictationMode, timestamp: UInt64, heldNs: UInt64)
  case cancel(CancelReason)
}

/// Push-to-talk state machine.
///
/// - Fn (or the alternate key) pressed: recording starts.
/// - Ctrl pressed before or during the press: the session becomes Scribe.
/// - Release after at least `minHoldNs`: stop. Earlier: cancelled as a tap.
/// - A non-modifier key during the press: cancelled (it was a shortcut).
public struct HotkeyStateMachine: Sendable {
  public var triggers: [HotkeyTrigger]
  public var minHoldNs: UInt64

  private enum State: Sendable {
    case idle
    case holding(trigger: HotkeyTrigger, start: UInt64, mode: DictationMode)
    /// Cancelled: only the key release is awaited.
    case suppressed(trigger: HotkeyTrigger)
  }

  private var state: State = .idle

  public init(triggers: [HotkeyTrigger], minHoldNs: UInt64 = 150_000_000) {
    self.triggers = triggers
    self.minHoldNs = minHoldNs
  }

  public var isHolding: Bool {
    if case .holding = state { return true }
    return false
  }

  public mutating func reset() {
    state = .idle
  }

  public mutating func handle(_ event: KeyEvent) -> [HotkeyAction] {
    switch event {
    case let .flagsChanged(keyCode, flags, timestamp):
      return flagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
    case let .keyDown(keyCode, _, _):
      guard case let .holding(trigger, _, _) = state else { return [] }
      state = .suppressed(trigger: trigger)
      return [.cancel(keyCode == KeyCode.escape ? .escape : .otherKey)]
    }
  }

  private mutating func flagsChanged(keyCode: UInt16, flags: UInt64, timestamp: UInt64) -> [HotkeyAction] {
    let controlDown = flags & EventFlag.control != 0

    if let trigger = triggers.first(where: { $0.keyCode == keyCode }) {
      let pressed = flags & trigger.pressedMask != 0
      switch state {
      case .idle where pressed:
        let mode: DictationMode = controlDown ? .scribe : .dictation
        state = .holding(trigger: trigger, start: timestamp, mode: mode)
        return [.start(mode, timestamp: timestamp)]
      case let .holding(current, start, mode) where current == trigger && !pressed:
        state = .idle
        let held = timestamp > start ? timestamp - start : 0
        return held < minHoldNs ? [.cancel(.tooShort)] : [.stop(mode, timestamp: timestamp, heldNs: held)]
      case let .suppressed(current) where current == trigger && !pressed:
        state = .idle
        return []
      default:
        break
      }
    }

    // Ctrl added during the press: switch to Scribe (no going back).
    if case let .holding(trigger, start, mode) = state, mode == .dictation, controlDown {
      state = .holding(trigger: trigger, start: start, mode: .scribe)
      return [.modeChanged(.scribe)]
    }
    return []
  }
}
