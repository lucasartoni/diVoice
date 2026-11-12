import AppKit
import DiVoiceCore
import DiVoiceEngine
import SwiftUI

/// `DiVoice --render-screens <folder>`: draws each screen offscreen to PNG, light and dark, for
/// design reviews. The organization, team and invite use sample data, the personal key is a
/// placeholder; nothing is sent to a server and nothing is saved.
enum ScreenRenderer {
  static func runIfRequested() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--render-screens"), index + 1 < arguments.count else { return }
    let folder = URL(fileURLWithPath: arguments[index + 1])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    MainActor.assumeIsolated { render(into: folder) }
    exit(0)
  }

  @MainActor
  private static func render(into folder: URL) {
    let settings = AppSettings.shared
    let setup = SetupModel(settings: settings, previewKeys: [.mistral: "••••1234"])
    let org = OrgStore.shared

    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      func save<V: View>(_ name: String, _ view: V, size: NSSize, backdrop: Bool = false) {
        let content = backdrop ? AnyView(view.background(Backdrop())) : AnyView(view)
        snapshot(content, size: size, appearance: appearance, to: folder.appendingPathComponent("\(name)-\(suffix).png"))
      }

      // The overlay, in each state, over a neutral backdrop.
      for (name, phase, mode, locked) in overlayStates {
        let model = OverlayModel()
        model.phase = phase
        model.mode = mode
        model.lockedKey = locked ? HotkeyTrigger.fn.id : nil
        model.levels = (0..<OverlayModel.bars).map { Float(0.15 + 0.6 * abs(sin(Double($0) * 0.7))) }
        save("overlay-\(name)", OverlayView(model: model), size: NSSize(width: 440, height: 84), backdrop: true)
      }

      // Personal mode.
      org.setPreview(nil, teamEntries: [])
      save("onboarding-personal", OnboardingView(model: setup, settings: settings, onInvite: { _ in }, onDone: {}), size: NSSize(width: 600, height: 700))
      save("onboarding-team", OnboardingView(model: setup, settings: settings, usage: .team, onInvite: { _ in }, onDone: {}), size: NSSize(width: 600, height: 700))
      for page in [SettingsView.Page.general, .models, .style, .dictionary, .history, .statistics, .latency] {
        // The history and style pages show samples, never this Mac's dictations or instructions.
        save(
          "settings-\(page)",
          SettingsView(
            settings: settings, setup: setup, history: page == .history ? sampleHistory : HistoryStore.shared, page: page,
            vocabulary: sampleDictionary, stats: sampleStats)
            .environment(\.stylePreview, sampleStyle)
            .environment(\.learningPreview, LearningStore(preview: ["email": "- Greets with “Hi Name,” on its own line.\n- Signs “Ada”."])),
          size: NSSize(width: 860, height: 640))
      }

      // The whole Style page, for the sections below the fold.
      save(
        "style-full",
        StyleView(settings: settings, preview: sampleStyle, learning: LearningStore(preview: ["email": "- Greets with “Hi Name,” on its own line.\n- Signs “Ada”."]))
          .background(Theme.background),
        size: NSSize(width: 660, height: 1_700))

      // An organization (sample data).
      org.setPreview(sampleMembership, teamEntries: sampleTeamTerms)
      save(
        "settings-team",
        SettingsView(settings: settings, setup: setup, history: HistoryStore.shared, page: .team)
          .environment(\.teamPreview, sampleTeam),
        size: NSSize(width: 860, height: 640))
      save(
        "settings-organization",
        SettingsView(settings: settings, setup: setup, history: HistoryStore.shared, page: .organization)
          .environment(\.adminPreview, sampleAdmin()),
        size: NSSize(width: 860, height: 640))
      save("settings-models-organization", SettingsView(settings: settings, setup: setup, history: HistoryStore.shared, page: .models), size: NSSize(width: 860, height: 640))
      // A sample name, not the Mac user's: these images end up in the public docs.
      let joinModel = JoinModel(link: sampleLink, preview: sampleInvite)
      joinModel.name = "Grace Hopper"
      save("join", JoinView(model: joinModel, onJoined: {}, onCancel: {}), size: NSSize(width: 500, height: 0))
      // A made-up secret, never saved: the real one is generated when the window opens.
      let createModel = CreateOrgModel(secret: "sample-secret-not-real-0000000000000000000000Ab12")
      createModel.setPreview(server: "https://diserver.acme.workers.dev", status: .ready, copied: true)
      createModel.orgName = "Acme"
      createModel.name = "Ada Lovelace"
      createModel.email = "ada@acme.example"
      save("create-organization", CreateOrgView(model: createModel, onCreated: {}, onCancel: {}, scrolls: false), size: NSSize(width: 560, height: 0))
      org.setPreview(nil, teamEntries: [])
    }
  }

  private static let overlayStates: [(String, OverlayModel.Phase, DictationMode, Bool)] = [
    ("recording", .recording, .dictation, false),
    ("recording-scribe", .recording, .scribe, false),
    ("recording-hands-free", .recording, .dictation, true),
    ("recording-scribe-hands-free", .recording, .scribe, true),
    ("transcribing", .processing, .dictation, false),
    ("scribe-rewriting", .processing, .scribe, false),
    ("copied", .info("Text copied: press ⌘V"), .dictation, false),
    ("error", .error("Microphone not available"), .dictation, false),
  ]

  // MARK: Sample data

  private static let sampleLink = InviteLink(server: URL(string: "https://divoice.acme.example")!, code: "AbCdEfGh12_-xyZ0")

  private static let sampleMembership = Membership(
    server: URL(string: "https://divoice.acme.example")!, orgName: "Acme",
    member: OrgMember(id: "me", name: "Ada Lovelace", email: "ada@acme.example", role: "admin", hideFromTeam: false),
    pipeline: .defaults(.mistral), leaderboardEnabled: true, refreshedAt: Date())

  private static let sampleDictionary = VocabularyStore(preview: [
    VocabularyEntry(term: "Zentrix", aliases: ["centrix", "zen trix"], note: "Product", usageCount: 42),
    VocabularyEntry(term: "Kestrel", aliases: ["castrel"], note: "Analytics dashboard", usageCount: 17),
    VocabularyEntry(term: "Ada Lovelace", aliases: ["ada love lace"], note: "Colleague", usageCount: 9),
    VocabularyEntry(term: "Orbix", aliases: ["orbics", "or bix"], usageCount: 6),
    VocabularyEntry(term: "PostgreSQL", aliases: ["postgres sequel"], note: "Database", usageCount: 3),
  ])

  private static let sampleStats: StatsStore = {
    let words = [180, 420, 0, 310, 560, 640, 220, 0, 380, 710, 530, 460, 820, 390]
    var days: [String: DayTotals] = [:]
    for (offset, count) in words.enumerated() where count > 0 {
      let date = Calendar.current.date(byAdding: .day, value: offset - 13, to: Date()) ?? Date()
      days[DictationStats.dayKey(date)] = DayTotals(words: count, audioMs: count * 420, dictations: max(1, count / 22))
    }
    return StatsStore(preview: days)
  }()

  private static let sampleStyle = StylePreferences(
    tones: ["email": "formal"],
    instructions: ["email": "I use “Lei” with clients, and I sign “Ada”."],
    rules: [AppRule(kind: .website, value: "kestrel", name: "kestrel", category: .docs)])

  private static let sampleHistory: HistoryStore = {
    func entry(_ minutesAgo: Double, _ mode: DictationMode, _ app: String, _ category: AppCategory, _ text: String, _ raw: String) -> HistoryEntry {
      HistoryEntry(
        id: UUID().uuidString.lowercased(), date: Date().addingTimeInterval(-minutesAgo * 60), mode: mode.rawValue, appName: app,
        category: category.rawValue, text: text, raw: raw, transcription: "batch", cleanup: "llm", totalMs: 980, clientTimings: [:],
        pipelineTimings: [:])
    }
    return HistoryStore(preview: [
      entry(
        4, .dictation, "Mail", .email,
        "Hi Grace,\n\nthanks for the demo yesterday. Could you send me the Kestrel figures by Friday, so we can review them on Monday?\n\nBest,\nAda",
        "hi Grace so thanks for the demo yesterday um could you send me the Kestrel figures by Friday so we can review them on Monday best Ada"),
      entry(
        38, .scribe, "Slack", .workChat,
        "Let's move the Orbix review to Thursday at 3 pm: the new build isn't ready yet.",
        "so the Orbix review let's move it because the new build isn't ready yet so Thursday at three"),
      entry(95, .dictation, "Notes", .docs, "Ask Ada about the PostgreSQL migration plan.", "ask Ada about the PostgreSQL migration plan"),
    ])
  }()

  private static let sampleTeamTerms = ["Zentrix", "Kestrel", "Orbix", "Nimbly"].map { VocabularyEntry(term: $0, scope: .team, source: .seed) }

  private static var sampleInvite: InviteInfo {
    let json = #"{"org":{"name":"Acme","server":"https://divoice.acme.example"},"inviter":"Ada Lovelace","kind":"team","name":null,"email":null,"needsEmail":true}"#
    return try! JSONDecoder().decode(InviteInfo.self, from: Data(json.utf8))
  }

  private static var sampleTeam: (MyStats, TeamStats) {
    let mine = MyStats(
      summary: ServerSummary(words: 4_820, dictations: 212, savedSeconds: 5_460, wordsPerMinute: 142, streakDays: 6),
      recent: [])
    let rows = [
      TeamRow(id: "1", name: "Bob Rossi", isMe: false, words: 6_310, dictations: 260, savedSeconds: 7_020, wordsPerMinute: 151, streakDays: 9),
      TeamRow(id: "me", name: "Ada Lovelace", isMe: true, words: 4_820, dictations: 212, savedSeconds: 5_460, wordsPerMinute: 142, streakDays: 6),
      TeamRow(id: "2", name: "Carla Bianchi", isMe: false, words: 2_150, dictations: 98, savedSeconds: 2_310, wordsPerMinute: 128, streakDays: 0),
    ]
    return (mine, TeamStats(leaderboardEnabled: true, members: rows))
  }

  @MainActor
  private static func sampleAdmin() -> AdminModel {
    let model = AdminModel()
    model.settings = AdminSettings(
      name: "Acme", pipeline: .defaults(.mistral), leaderboardEnabled: true,
      keys: [KeyStatus(provider: "mistral", source: "admin", updatedAt: 0), KeyStatus(provider: "openai", source: nil, updatedAt: nil)])
    model.draft = .defaults(.mistral)
    model.members = [
      MemberRow(id: "me", name: "Ada Lovelace", email: "ada@acme.example", role: "admin", createdAt: 0, lastSeenAt: nil, hideFromTeam: false),
      MemberRow(id: "1", name: "Bob Rossi", email: "bob@acme.example", role: "member", createdAt: 0, lastSeenAt: nil, hideFromTeam: false),
      MemberRow(id: "2", name: "Carla Bianchi", email: "carla@acme.example", role: "member", createdAt: 0, lastSeenAt: nil, hideFromTeam: true),
    ]
    model.invites = [
      OrgInvite(
        code: "AbCdEfGh12_-xyZ0", kind: "team", role: "member", name: nil, email: nil, emails: nil, maxUses: nil, uses: 2,
        expiresAt: (Date().timeIntervalSince1970 + 5 * 86_400) * 1000, url: URL(string: "https://divoice.acme.example/i/AbCdEfGh12_-xyZ0")!)
    ]
    model.team = sampleTeamTerms
    return model
  }

  // MARK: Drawing

  /// A neutral desktop-like backdrop behind the overlay.
  private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
      LinearGradient(
        colors: scheme == .dark ? [Color(white: 0.16), Color(white: 0.22)] : [Color(white: 0.86), Color(white: 0.93)],
        startPoint: .top, endPoint: .bottom)
    }
  }

  /// Drawn as the active window, as the user sees it (switches and fields in their active colours).
  private final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
  }

  @MainActor
  /// A height of 0 means the view's own height, as the window would size to it.
  private static func snapshot(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
    var size = size
    if size.height == 0 {
      let measure = NSHostingView(rootView: view.frame(width: size.width))
      measure.appearance = NSAppearance(named: appearance)
      size.height = measure.fittingSize.height
    }
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = RenderWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.contentView = hosting
    window.orderFront(nil)
    window.makeKey()
    // Let SwiftUI lay out and run its first updates.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    hosting.layoutSubtreeIfNeeded()
    hosting.display()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
  }
}

// MARK: - Preview data for the screenshots

private struct TeamPreviewKey: EnvironmentKey {
  static let defaultValue: (MyStats, TeamStats)? = nil
}

private struct StylePreviewKey: EnvironmentKey {
  static let defaultValue: StylePreferences? = nil
}

private struct LearningPreviewKey: EnvironmentKey {
  static let defaultValue: LearningStore? = nil
}

private struct AdminPreviewKey: EnvironmentKey {
  static let defaultValue: AdminModel? = nil
}

extension EnvironmentValues {
  /// Sample preferences for the Style page (screenshots).
  var stylePreview: StylePreferences? {
    get { self[StylePreviewKey.self] }
    set { self[StylePreviewKey.self] = newValue }
  }

  /// Sample learned preferences for the Style page (screenshots).
  var learningPreview: LearningStore? {
    get { self[LearningPreviewKey.self] }
    set { self[LearningPreviewKey.self] = newValue }
  }

  /// Sample statistics for the Team page (screenshots).
  var teamPreview: (MyStats, TeamStats)? {
    get { self[TeamPreviewKey.self] }
    set { self[TeamPreviewKey.self] = newValue }
  }

  /// A filled admin panel (screenshots).
  var adminPreview: AdminModel? {
    get { self[AdminPreviewKey.self] }
    set { self[AdminPreviewKey.self] = newValue }
  }
}
