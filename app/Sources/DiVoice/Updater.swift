import Foundation
import os
#if canImport(Sparkle)
import Sparkle
#endif

let appLog = Logger(subsystem: "app.wibo.divoice", category: "app")

/// Automatic updates with Sparkle, from the public GitHub Releases (SUFeedURL in Info.plist).
///
/// No credentials are ever sent with update requests. Every update is checked twice: EdDSA
/// signature (public key in Info.plist) and Developer ID signature of the same team. That's
/// why macOS keeps the microphone and Accessibility permissions after an update.
final class Updater: NSObject {
  private let settings: AppSettings

  #if canImport(Sparkle)
  private var controller: SPUStandardUpdaterController!
  #endif

  init(settings: AppSettings) {
    self.settings = settings
    super.init()
    #if canImport(Sparkle)
    controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    controller.updater.httpHeaders = [:]
    controller.startUpdater()
    #endif
  }

  var isAvailable: Bool {
    #if canImport(Sparkle)
    return Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    #else
    return false
    #endif
  }

  var canCheckForUpdates: Bool {
    #if canImport(Sparkle)
    return isAvailable && controller.updater.canCheckForUpdates
    #else
    return false
    #endif
  }

  func checkForUpdates() {
    #if canImport(Sparkle)
    controller.checkForUpdates(nil)
    #endif
  }
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    appLog.notice("Update available: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    appLog.notice("Installing update \(item.displayVersionString, privacy: .public)")
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    appLog.error("Update aborted: \(error.localizedDescription, privacy: .public)")
  }
}

extension Updater: SPUStandardUserDriverDelegate {
  /// diVoice lives in the menu bar: Sparkle must not steal focus on periodic checks.
  var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
