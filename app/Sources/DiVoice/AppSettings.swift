import Combine
import DiVoiceCore
import DiVoiceEngine
import Foundation

/// User preferences, in UserDefaults. API keys live in the Keychain (KeyStore).
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  /// Dictation languages offered in the settings ("auto" = automatic detection).
  static let languages = ["it", "en", "es", "fr", "de", "pt", "auto"]

  private let defaults = UserDefaults.standard

  /// Providers and models for transcription, cleanup and Scribe.
  @Published var pipeline: PipelineSettings { didSet { save(pipeline, "pipeline") } }
  /// Two-letter code or "auto".
  @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
  @Published var fnEnabled: Bool { didSet { defaults.set(fnEnabled, forKey: "fnEnabled") } }
  /// "rightCommand", "rightOption" or "none": for external keyboards without Fn.
  @Published var alternativeTrigger: String { didSet { defaults.set(alternativeTrigger, forKey: "alternativeTrigger") } }
  /// Core Audio UID of the microphone; empty = the system one.
  @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
  @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
  @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
  @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
  /// Typing speed used to estimate the time saved.
  @Published var typingWPM: Int { didSet { defaults.set(typingWPM, forKey: "typingWPM") } }
  /// Settings › Style: tones, own instructions and app rules.
  @Published var style: StylePreferences { didSet { save(style, "style") } }
  /// Read the conversation and the text around the cursor at the start of a dictation.
  @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: "useScreenContext") } }
  /// Learn names and writing preferences from what the user corrects after an insertion.
  @Published var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }

  private init() {
    defaults.register(defaults: [
      "language": Self.systemLanguage,
      "fnEnabled": true,
      "alternativeTrigger": "rightCommand",
      "microphoneUID": "",
      "playSounds": true,
      "restoreClipboard": true,
      "onboardingCompleted": false,
      "typingWPM": 40,
      "useScreenContext": true,
      "learnFromCorrections": true,
    ])
    var pipeline = Self.load(PipelineSettings.self, "pipeline", defaults) ?? .defaults(.mistral)
    pipeline.transcription = pipeline.transcription.upgradingDefaults()
    self.pipeline = pipeline
    language = defaults.string(forKey: "language") ?? Self.systemLanguage
    fnEnabled = defaults.bool(forKey: "fnEnabled")
    alternativeTrigger = defaults.string(forKey: "alternativeTrigger") ?? "rightCommand"
    microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
    playSounds = defaults.bool(forKey: "playSounds")
    restoreClipboard = defaults.bool(forKey: "restoreClipboard")
    onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
    typingWPM = defaults.integer(forKey: "typingWPM")
    style = Self.load(StylePreferences.self, "style", defaults) ?? StylePreferences()
    useScreenContext = defaults.bool(forKey: "useScreenContext")
    learnFromCorrections = defaults.bool(forKey: "learnFromCorrections")
  }

  /// The Mac's language if diVoice offers it, otherwise automatic detection.
  private static var systemLanguage: String {
    let code = String((Locale.preferredLanguages.first ?? "").prefix(2))
    return languages.contains(code) ? code : "auto"
  }

  var triggers: [HotkeyTrigger] {
    var triggers: [HotkeyTrigger] = []
    if fnEnabled { triggers.append(.fn) }
    if let alternative = HotkeyTrigger.byID(alternativeTrigger) { triggers.append(alternative) }
    return triggers
  }

  /// Uses one provider for everything, with its default models.
  func useProvider(_ provider: ProviderID) {
    pipeline = .defaults(provider)
  }

  private func save<T: Encodable>(_ value: T, _ key: String) {
    if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
  }

  private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
    defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
}
