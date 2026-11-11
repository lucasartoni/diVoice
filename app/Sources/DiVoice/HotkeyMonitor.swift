import AppKit
import CoreGraphics
import DiVoiceCore

/// Global event tap on a dedicated thread: recognizes Fn, Ctrl+Fn and the alternate key.
///
/// The callback must stay extremely fast (it slows down the whole keyboard): it only runs the
/// state machine and sends the actions to the main thread. Esc during recording is
/// swallowed; all other events pass through unchanged.
final class HotkeyMonitor {
  /// Marks the events we post ourselves (Cmd+V) so we don't intercept them.
  static let syntheticEventMarker: Int64 = 0x4456_4F49

  var onAction: ((HotkeyAction) -> Void)?
  /// The system disabled the tap: a key release may have been lost.
  var onReset: (() -> Void)?

  private let lock = NSLock()
  private var machine: HotkeyStateMachine
  private var tap: CFMachPort?
  private var runLoop: CFRunLoop?
  private var timebase = mach_timebase_info_data_t()

  init(triggers: [HotkeyTrigger]) {
    machine = HotkeyStateMachine(triggers: triggers)
    mach_timebase_info(&timebase)
  }

  var isRunning: Bool { tap != nil }

  func setTriggers(_ triggers: [HotkeyTrigger]) {
    lock.lock()
    machine.triggers = triggers
    machine.reset()
    lock.unlock()
  }

  /// Requires the Accessibility permission; returns false if it is missing.
  @discardableResult
  func start() -> Bool {
    if tap != nil { return true }
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: hotkeyTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return false }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    let thread = Thread { [weak self] in
      let runLoop = CFRunLoopGetCurrent()
      self?.runLoop = runLoop
      CFRunLoopAddSource(runLoop, source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
    }
    thread.name = "diVoice.hotkeys"
    thread.qualityOfService = .userInteractive
    thread.start()
    return true
  }

  func stop() {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let runLoop { CFRunLoopStop(runLoop) }
    tap = nil
    runLoop = nil
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      lock.lock()
      let wasHolding = machine.isHolding
      machine.reset()
      lock.unlock()
      if wasHolding { DispatchQueue.main.async { self.onReset?() } }
      return Unmanaged.passUnretained(event)
    case .keyDown, .flagsChanged:
      break
    default:
      return Unmanaged.passUnretained(event)
    }

    if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let timestamp = MonotonicClock.eventUptimeNs(
      event.timestamp,
      nowNs: MonotonicClock.nowNs(),
      timebaseNumer: timebase.numer,
      timebaseDenom: timebase.denom
    )
    let keyEvent: KeyEvent = type == .flagsChanged
      ? .flagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
      : .keyDown(keyCode: keyCode, flags: flags, timestamp: timestamp)

    lock.lock()
    let actions = machine.handle(keyEvent)
    lock.unlock()
    guard !actions.isEmpty else { return Unmanaged.passUnretained(event) }

    DispatchQueue.main.async {
      for action in actions { self.onAction?(action) }
    }
    return actions.contains(.cancel(.escape)) ? nil : Unmanaged.passUnretained(event)
  }
}

private func hotkeyTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
