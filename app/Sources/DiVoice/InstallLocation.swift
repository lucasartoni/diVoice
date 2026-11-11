import AppKit

/// Checks that diVoice runs from a stable folder, usually /Applications.
///
/// Opened straight from the DMG, or from Downloads without moving it with the Finder, macOS
/// runs it from a temporary read-only copy ("App Translocation") and Sparkle can't update it.
/// Better to say so now than to find out at the first missed update.
enum InstallLocation {
  static var problem: String? {
    let path = Bundle.main.bundlePath
    if path.hasPrefix("/Volumes/") {
      return String(localized: "diVoice is running from the installation disk.")
    }
    if path.contains("/AppTranslocation/") {
      return String(localized: "macOS is running diVoice from a temporary copy, because it wasn't moved to the Applications folder.")
    }
    return nil
  }

  /// Copies diVoice to the Applications folder and opens the copy, quitting this one: for
  /// colleagues who opened it straight from the disk image after an invite. False if it can't
  /// (for example without permission to write to Applications).
  static func moveToApplications() -> Bool {
    let destination = URL(fileURLWithPath: "/Applications/diVoice.app")
    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.trashItem(at: destination, resultingItemURL: nil)
      }
      try fileManager.copyItem(at: Bundle.main.bundleURL, to: destination)
    } catch {
      appLog.error("Move to Applications failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
    appLog.notice("Moved to /Applications, reopening")
    // Opens the copy once this process has quit.
    let reopen = Process()
    reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
    reopen.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(destination.path)\""]
    do {
      try reopen.run()
    } catch {
      return false
    }
    NSApp.terminate(nil)
    return true
  }

  /// True if the user chooses to quit to move the app.
  static func warnIfNeeded() -> Bool {
    guard let problem else { return false }
    appLog.error("Location not suitable for updates: \(Bundle.main.bundlePath, privacy: .public)")
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Move diVoice to the Applications folder")
    alert.informativeText = problem + " " + String(localized: "This way diVoice can't receive updates.") + "\n\n"
      + String(localized: "Quit, open the diVoice disk (or the Downloads folder), drag diVoice onto the Applications icon and open it again from the Applications folder.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Quit"))
    alert.addButton(withTitle: String(localized: "Continue anyway"))
    return alert.runModal() == .alertFirstButtonReturn
  }
}
