import Testing
@testable import DiVoiceCore

private let ms: UInt64 = 1_000_000
private let fnDown = EventFlag.secondaryFn
private let ctrl = EventFlag.control

private func fn(_ pressed: Bool, at t: UInt64, extra: UInt64 = 0) -> KeyEvent {
  .flagsChanged(keyCode: KeyCode.function, flags: (pressed ? fnDown : 0) | extra, timestamp: t * ms)
}

@Suite("Hotkey state machine")
struct HotkeyTests {
  @Test func heldFnStartsAndStopsDictation() {
    var m = HotkeyStateMachine(triggers: [.fn])
    #expect(m.handle(fn(true, at: 1000)) == [.start(.dictation, timestamp: 1000 * ms)])
    #expect(m.isHolding)
    #expect(m.handle(fn(false, at: 2500)) == [.stop(.dictation, timestamp: 2500 * ms, heldNs: 1500 * ms)])
    #expect(!m.isHolding)
  }

  @Test func shortTapIsCancelled() {
    var m = HotkeyStateMachine(triggers: [.fn])
    _ = m.handle(fn(true, at: 1000))
    #expect(m.handle(fn(false, at: 1100)) == [.cancel(.tooShort)])
    // Right after, it can start again.
    #expect(m.handle(fn(true, at: 1200)) == [.start(.dictation, timestamp: 1200 * ms)])
  }

  @Test func ctrlPlusFnStartsScribe() {
    var m = HotkeyStateMachine(triggers: [.fn])
    // Ctrl pressed before Fn.
    _ = m.handle(.flagsChanged(keyCode: 59, flags: ctrl, timestamp: 900 * ms))
    #expect(m.handle(fn(true, at: 1000, extra: ctrl)) == [.start(.scribe, timestamp: 1000 * ms)])
    #expect(m.handle(fn(false, at: 2000, extra: ctrl)) == [.stop(.scribe, timestamp: 2000 * ms, heldNs: 1000 * ms)])
  }

  @Test func ctrlAddedDuringPressSwitchesToScribe() {
    var m = HotkeyStateMachine(triggers: [.fn])
    _ = m.handle(fn(true, at: 1000))
    #expect(m.handle(.flagsChanged(keyCode: 59, flags: fnDown | ctrl, timestamp: 1300 * ms)) == [.modeChanged(.scribe)])
    // Releasing Ctrl doesn't go back to dictation, and the switch isn't repeated.
    #expect(m.handle(.flagsChanged(keyCode: 59, flags: fnDown, timestamp: 1400 * ms)) == [])
    #expect(m.handle(.flagsChanged(keyCode: 59, flags: fnDown | ctrl, timestamp: 1500 * ms)) == [])
    #expect(m.handle(fn(false, at: 2000)) == [.stop(.scribe, timestamp: 2000 * ms, heldNs: 1000 * ms)])
  }

  @Test func anotherKeyCancelsAndIgnoresTheRelease() {
    var m = HotkeyStateMachine(triggers: [.fn])
    _ = m.handle(fn(true, at: 1000))
    // Fn+left arrow (Home)
    #expect(m.handle(.keyDown(keyCode: 123, flags: fnDown, timestamp: 1200 * ms)) == [.cancel(.otherKey)])
    #expect(m.handle(.keyDown(keyCode: 123, flags: fnDown, timestamp: 1300 * ms)) == [])
    #expect(m.handle(fn(false, at: 3000)) == [])
    #expect(!m.isHolding)
  }

  @Test func escCancels() {
    var m = HotkeyStateMachine(triggers: [.fn])
    _ = m.handle(fn(true, at: 1000))
    #expect(m.handle(.keyDown(keyCode: KeyCode.escape, flags: fnDown, timestamp: 1500 * ms)) == [.cancel(.escape)])
  }

  @Test func keysOutsideAPressDoNothing() {
    var m = HotkeyStateMachine(triggers: [.fn])
    #expect(m.handle(.keyDown(keyCode: 0, flags: 0, timestamp: 1)) == [])
    #expect(m.handle(fn(false, at: 10)) == [])
    #expect(m.handle(.flagsChanged(keyCode: 56, flags: 0x20000, timestamp: 20 * ms)) == [])
  }

  @Test func rightCommandAsAlternateKey() {
    var m = HotkeyStateMachine(triggers: [.fn, .rightCommand])
    let rightDown: UInt64 = 0x0010_0000 | EventFlag.rightCommand
    #expect(m.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightDown, timestamp: 1000 * ms)) == [.start(.dictation, timestamp: 1000 * ms)])
    // Fn pressed in the meantime doesn't start a second session.
    #expect(m.handle(fn(true, at: 1100, extra: rightDown)) == [])
    _ = m.handle(fn(false, at: 1150, extra: rightDown))
    #expect(m.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: 0, timestamp: 2000 * ms)) == [.stop(.dictation, timestamp: 2000 * ms, heldNs: 1000 * ms)])
  }

  @Test func leftCommandStartsNothing() {
    var m = HotkeyStateMachine(triggers: [.rightCommand])
    let leftDown: UInt64 = 0x0010_0000 | 0x08
    #expect(m.handle(.flagsChanged(keyCode: 55, flags: leftDown, timestamp: 1000 * ms)) == [])
    // Right ⌘ pressed while the left one is down: the right bit counts.
    #expect(m.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: leftDown | EventFlag.rightCommand, timestamp: 1100 * ms)) == [.start(.dictation, timestamp: 1100 * ms)])
    #expect(m.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: leftDown, timestamp: 1500 * ms)) == [.stop(.dictation, timestamp: 1500 * ms, heldNs: 400 * ms)])
  }

  @Test func rightCommandPlusKeyIsAShortcut() {
    var m = HotkeyStateMachine(triggers: [.rightCommand])
    let rightDown: UInt64 = 0x0010_0000 | EventFlag.rightCommand
    _ = m.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightDown, timestamp: 1000 * ms))
    #expect(m.handle(.keyDown(keyCode: 8, flags: rightDown, timestamp: 1050 * ms)) == [.cancel(.otherKey)])
  }

  @Test func backwardsTimestampGivesZeroDuration() {
    var m = HotkeyStateMachine(triggers: [.fn], minHoldNs: 0)
    _ = m.handle(fn(true, at: 2000))
    #expect(m.handle(fn(false, at: 1000)) == [.stop(.dictation, timestamp: 1000 * ms, heldNs: 0)])
  }
}
