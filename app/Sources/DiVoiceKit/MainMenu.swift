import AppKit

/// The app's main menu.
///
/// diVoice lives in the menu bar and never shows a menu bar of its own, but AppKit still
/// routes keyboard shortcuts through `NSApp.mainMenu`: without an Edit menu, ⌘V, ⌘C, ⌘X,
/// ⌘A and ⌘Z do nothing in text fields (for example the API key field).
public enum MainMenu {
  public static func make(appName: String = "diVoice") -> NSMenu {
    let main = NSMenu()

    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: String(localized: "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    main.addItem(submenu: appMenu, title: appName)

    let edit = NSMenu(title: String(localized: "Edit"))
    edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    main.addItem(submenu: edit, title: edit.title)

    let window = NSMenu(title: String(localized: "Window"))
    window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    main.addItem(submenu: window, title: window.title)
    return main
  }

  /// The item that handles a ⌘-shortcut, as AppKit would find it.
  public static func item(for key: String, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if let submenu = item.submenu, let found = Self.item(for: key, in: submenu) { return found }
      if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
    }
    return nil
  }
}

private extension NSMenu {
  func addItem(submenu: NSMenu, title: String) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    addItem(item)
  }
}
