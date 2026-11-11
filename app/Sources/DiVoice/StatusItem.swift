import AppKit

/// Icon and menu in the menu bar.
final class StatusItemController: NSObject, NSMenuDelegate {
  var onPasteLast: (() -> Void)?
  var onOpenSettings: (() -> Void)?
  var onOpenHistory: (() -> Void)?
  var onOpenSetup: (() -> Void)?
  var onCheckForUpdates: (() -> Void)?
  var canCheckForUpdates: (() -> Bool)?
  /// Status line at the top of the menu, computed every time it opens.
  var statusLine: (() -> String)?

  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let history: HistoryStore

  init(history: HistoryStore) {
    self.history = history
    super.init()
    setRecording(false)
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
  }

  func setRecording(_ recording: Bool) {
    let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "diVoice")
    image?.isTemplate = true
    item.button?.image = image
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(disabled(statusLine?() ?? "diVoice"))

    let latency = history.latency
    if let last = history.last {
      let count = latency.count.formatted()
      menu.addItem(disabled(String(localized: "Last: \(Format.seconds(last.totalMs)) · median \(Format.seconds(latency.p50)) over \(count)")))
    }
    menu.addItem(.separator())

    let paste = action(String(localized: "Paste last dictation"), #selector(pasteLast))
    paste.isEnabled = history.last != nil
    menu.addItem(paste)
    menu.addItem(action(String(localized: "History…"), #selector(openHistory)))
    menu.addItem(.separator())
    menu.addItem(action(String(localized: "Settings…"), #selector(openSettings), key: ","))
    menu.addItem(action(String(localized: "Setup and permissions…"), #selector(openSetup)))
    let updates = action(String(localized: "Check for Updates…"), #selector(checkForUpdates))
    updates.isEnabled = canCheckForUpdates?() ?? false
    menu.addItem(updates)
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    menu.addItem(disabled(String(localized: "Version \(version)")))
    menu.addItem(.separator())
    menu.addItem(action(String(localized: "Quit diVoice"), #selector(quit), key: "q"))
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func pasteLast() { onPasteLast?() }
  @objc private func openSettings() { onOpenSettings?() }
  @objc private func openHistory() { onOpenHistory?() }
  @objc private func openSetup() { onOpenSetup?() }
  @objc private func checkForUpdates() { onCheckForUpdates?() }
  @objc private func quit() { NSApp.terminate(nil) }
}
