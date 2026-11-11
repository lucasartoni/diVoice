import AppKit
import Testing

@testable import DiVoiceKit

/// Regression test: in a menu-bar-only app, ⌘V and the right-click "Paste" must work in
/// plain and secure text fields (the API key field is a secure one).
@MainActor
@Suite(.serialized) struct MainMenuTests {
  /// Runs `body` with `text` on the general pasteboard, then puts back what was there.
  private func withPasteboard(_ text: String, _ body: () throws -> Void) rethrows {
    let pasteboard = NSPasteboard.general
    let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
    }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    defer {
      pasteboard.clearContents()
      let items = saved.map { contents -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in contents { item.setData(data, forType: type) }
        return item
      }
      if !items.isEmpty { pasteboard.writeObjects(items) }
    }
    try body()
  }

  /// A window with the field focused; returns the field editor that receives the actions.
  private func focus(_ field: NSTextField) throws -> NSTextView {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    field.frame = NSRect(x: 10, y: 20, width: 280, height: 24)
    window.contentView?.addSubview(field)
    #expect(window.makeFirstResponder(field))
    return try #require(window.firstResponder as? NSTextView)
  }

  @Test func editShortcutsAreBound() throws {
    let menu = MainMenu.make()
    let expected: [(String, Selector)] = [
      ("v", #selector(NSText.paste(_:))),
      ("c", #selector(NSText.copy(_:))),
      ("x", #selector(NSText.cut(_:))),
      ("a", #selector(NSText.selectAll(_:))),
      ("z", Selector(("undo:"))),
    ]
    for (key, action) in expected {
      let item = try #require(MainMenu.item(for: key, in: menu), "⌘\(key) is not bound")
      #expect(item.action == action)
      #expect(item.target == nil, "⌘\(key) must go to the first responder")
    }
  }

  @Test(arguments: [false, true])
  func commandVPastesIntoTextFields(secure: Bool) throws {
    try withPasteboard("sk-test-incolla-123") {
      let field = secure ? NSSecureTextField() : NSTextField()
      let editor = try focus(field)
      let paste = try #require(MainMenu.item(for: "v", in: MainMenu.make()))
      #expect(NSApplication.shared.sendAction(try #require(paste.action), to: editor, from: paste))
      field.validateEditing()
      #expect(field.stringValue == "sk-test-incolla-123")
    }
  }

  /// A ⌘V key event is handled by the main menu; with an empty menu (the old bug) nothing
  /// handles it. In a test process the app is not active, so the action itself is checked by
  /// `commandVPastesIntoTextFields`.
  @Test func commandVKeyEventIsHandledOnlyWithTheEditMenu() throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    let app = NSApplication.shared
    let previous = app.mainMenu
    defer { app.mainMenu = previous }
    app.mainMenu = NSMenu()
    #expect(app.mainMenu?.performKeyEquivalent(with: event) == false)
    app.mainMenu = MainMenu.make()
    #expect(app.mainMenu?.performKeyEquivalent(with: event) == true)
  }

  @Test(arguments: [false, true])
  func rightClickMenuOffersPaste(secure: Bool) throws {
    let field = secure ? NSSecureTextField() : NSTextField()
    let editor = try focus(field)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: NSPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0,
        windowNumber: field.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(editor.menu(for: event))
    #expect(menu.items.contains { $0.action == #selector(NSText.paste(_:)) })
  }
}
