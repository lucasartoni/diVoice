import AppKit
import DiVoiceCore
import DiVoiceEngine
import Foundation

// MARK: - What the organization's server returns

struct OrgMember: Codable, Equatable, Identifiable {
  var id: String
  var name: String
  var email: String
  var role: String
  var hideFromTeam: Bool?

  var isAdmin: Bool { role == "admin" }
}

/// This Mac's membership: cached so diVoice starts and dictates even before reaching the server.
struct Membership: Codable, Equatable {
  var server: URL
  var orgName: String
  var member: OrgMember
  var pipeline: PipelineSettings
  var leaderboardEnabled: Bool
  var refreshedAt: Date

  var isAdmin: Bool { member.isAdmin }
  var host: String { server.host ?? server.absoluteString }
}

struct InviteInfo: Decodable {
  struct Org: Decodable {
    var name: String
    var server: URL
  }

  var org: Org
  var inviter: String?
  var kind: String
  var name: String?
  var email: String?
  var needsEmail: Bool
}

struct KeyStatus: Decodable, Equatable {
  var provider: String
  /// "admin": saved from diVoice; "secret": set on the server; nil: none.
  var source: String?
  var updatedAt: Double?
}

struct AdminSettings: Decodable, Equatable {
  var name: String
  var pipeline: PipelineSettings
  var leaderboardEnabled: Bool
  var keys: [KeyStatus]
}

struct OrgInvite: Decodable, Identifiable, Equatable {
  var code: String
  var kind: String
  var role: String
  var name: String?
  var email: String?
  var emails: [String]?
  var maxUses: Int?
  var uses: Int
  var expiresAt: Double
  var url: URL

  var id: String { code }
  var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

struct MemberRow: Decodable, Identifiable, Equatable {
  var id: String
  var name: String
  var email: String
  var role: String
  var createdAt: Double
  var lastSeenAt: Double?
  var hideFromTeam: Bool

  var lastSeen: Date? { lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct ServerSummary: Decodable, Equatable {
  var words: Int
  var dictations: Int
  var savedSeconds: Double
  var wordsPerMinute: Double?
  var streakDays: Int
}

struct MyStats: Decodable {
  struct Day: Decodable, Equatable {
    var day: String
    var words: Int
  }

  var summary: ServerSummary
  var recent: [Day]
}

struct TeamRow: Decodable, Identifiable, Equatable {
  var id: String
  var name: String
  var isMe: Bool
  var words: Int
  var dictations: Int
  var savedSeconds: Double
  var wordsPerMinute: Double?
  var streakDays: Int
}

struct TeamStats: Decodable {
  var leaderboardEnabled: Bool
  var members: [TeamRow]
}

// MARK: - REST client

struct OrgError: LocalizedError {
  var status: Int
  var message: String
  var errorDescription: String? { message }
}

/// The organization server's REST API, with the member token when there is one.
struct OrgClient {
  let server: URL
  let token: String?

  private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) throws -> URLRequest {
    var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
    components.path = path
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!, timeoutInterval: 20)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let json {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    return request
  }

  @discardableResult
  func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) async throws -> Data {
    let (data, response) = try await EngineFactory.session.data(for: try request(method, path, query: query, json: json))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw OrgError(status: status, message: message ?? String(localized: "The organization's server answered with an error (\(String(status)))"))
    }
    return data
  }

  func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
    try JSONDecoder().decode(type, from: try await send("GET", path, query: query))
  }

  func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, json: Any? = nil) async throws -> T {
    try JSONDecoder().decode(type, from: try await send(method, path, json: json))
  }

  /// A value as a JSON object, for request bodies.
  static func object<T: Encodable>(_ value: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
  }
}

// MARK: - The membership

extension Notification.Name {
  /// Joined or left an organization: the engine and the microphone's sample rate may change.
  static let diVoiceOrganizationChanged = Notification.Name("app.wibo.divoice.organizationChanged")
  /// Opens a page of the settings window that's already open; the object is a `SettingsView.Page`.
  static let diVoiceShowSettingsPage = Notification.Name("app.wibo.divoice.showSettingsPage")
  /// A dictation's counts reached the organization's server: the team statistics can reload.
  static let diVoiceDictationRecorded = Notification.Name("app.wibo.divoice.dictationRecorded")
}

/// The organization this Mac belongs to, if any. Without one, diVoice is in personal mode
/// (the user's own keys); with one, dictations go through the organization's server.
/// Published state changes only on the main actor; reading it (as the dictation does) is safe
/// from the main thread, like the app's other stores.
final class OrgStore: ObservableObject {
  static let shared = OrgStore()

  @Published private(set) var membership: Membership?
  @Published private(set) var teamEntries: [VocabularyEntry] = []
  /// Something the user should know, such as having been removed from the organization.
  @Published var notice: String?

  private let defaults = UserDefaults.standard

  private init() {
    if let data = defaults.data(forKey: "organization"), let saved = try? JSONDecoder().decode(Membership.self, from: data), KeyStore.orgToken != nil {
      membership = saved
    }
    if let data = defaults.data(forKey: "organization.dictionary"), let saved = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
      teamEntries = saved
    }
  }

  /// Sample data for the screenshots: never a real server or the Keychain.
  private var previewing = false

  var token: String? { membership == nil || previewing ? nil : KeyStore.orgToken }

  var client: OrgClient? {
    guard let membership, let token else { return nil }
    return OrgClient(server: membership.server, token: token)
  }

  static func inviteInfo(_ link: InviteLink) async throws -> InviteInfo {
    try await OrgClient(server: link.server, token: nil).get(InviteInfo.self, "/v2/invites/\(link.code)")
  }

  /// Joins with an invite: the token goes to the Keychain, the settings are loaded.
  @MainActor
  func join(_ link: InviteLink, name: String, email: String?) async throws {
    struct Joined: Decodable {
      var token: String
      var member: OrgMember
    }
    var body: [String: Any] = ["code": link.code, "name": name]
    if let email { body["email"] = email }
    let joined = try await OrgClient(server: link.server, token: nil).send(Joined.self, "POST", "/v2/join", json: body)
    try await connect(server: link.server, token: joined.token)
    appLog.notice("Joined organization at \(link.server.host ?? "?", privacy: .public) as \(joined.member.role, privacy: .public)")
  }

  struct SetupStatus: Decodable, Equatable {
    var claimed: Bool
    var secretConfigured: Bool
  }

  /// Whether a newly deployed server is ready for its first admin.
  static func setupStatus(_ server: URL) async throws -> SetupStatus {
    try await OrgClient(server: server, token: nil).get(SetupStatus.self, "/v2/setup")
  }

  /// Becomes the first admin of a newly deployed server, proving the secret it was deployed with.
  @MainActor
  func create(server: URL, secret: String, orgName: String, name: String, email: String) async throws {
    struct Claimed: Decodable {
      var token: String
    }
    let body: [String: Any] = ["secret": secret, "orgName": orgName, "name": name, "email": email]
    let claimed: Claimed
    do {
      claimed = try await OrgClient(server: server, token: nil).send(Claimed.self, "POST", "/v2/setup/claim", json: body)
    } catch let error as OrgError where error.status == 403 {
      throw OrgError(
        status: 403,
        message: String(localized: "The server was deployed with a different secret. In Cloudflare, set SERVER_SECRET (DIVOICE_SECRET on servers set up before) to the secret shown here (your Worker › Settings › Variables and Secrets), then try again."))
    } catch let error as OrgError where error.status == 409 {
      throw OrgError(status: 409, message: String(localized: "This server already has an admin: ask them for an invite."))
    }
    try await connect(server: server, token: claimed.token)
    appLog.notice("Created the organization at \(server.host ?? "?", privacy: .public)")
  }

  /// After joining or creating: the token goes to the Keychain, the settings are loaded.
  @MainActor
  private func connect(server: URL, token: String) async throws {
    guard KeyStore.saveOrgToken(token) else {
      throw OrgError(status: 0, message: String(localized: "diVoice couldn't save the organization's token in the Keychain"))
    }
    let me = try await OrgClient(server: server, token: token).get(Me.self, "/v2/me")
    apply(me, server: server)
    await refreshDictionary()
    NotificationCenter.default.post(name: .diVoiceOrganizationChanged, object: nil)
  }

  private struct Me: Decodable {
    struct Org: Decodable {
      var name: String
    }

    var member: OrgMember
    var org: Org
    var pipeline: PipelineSettings
    var leaderboardEnabled: Bool
  }

  @MainActor
  private func apply(_ me: Me, server: URL) {
    let updated = Membership(
      server: server, orgName: me.org.name, member: me.member, pipeline: me.pipeline, leaderboardEnabled: me.leaderboardEnabled,
      refreshedAt: Date())
    let samplerateChanged = membership?.pipeline.transcription.provider != updated.pipeline.transcription.provider
    membership = updated
    if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: "organization") }
    if samplerateChanged { NotificationCenter.default.post(name: .diVoiceOrganizationChanged, object: nil) }
  }

  /// Reloads settings and the team dictionary. A revoked token ends the membership.
  @MainActor
  func refresh() async {
    guard let client else { return }
    do {
      apply(try await client.get(Me.self, "/v2/me"), server: client.server)
      await refreshDictionary()
    } catch let error as OrgError where error.status == 401 {
      let name = membership?.orgName ?? ""
      leave()
      notice = String(localized: "You are no longer a member of \(name). diVoice is back to personal mode.")
    } catch {
      appLog.error("Organization refresh failed: \(errorMessage(error), privacy: .public)")
    }
  }

  @MainActor
  private func refreshDictionary() async {
    struct Team: Decodable {
      var team: [VocabularyEntry]
    }
    guard let client, let team = try? await client.get(Team.self, "/v2/dictionary") else { return }
    teamEntries = team.team
    if let data = try? JSONEncoder().encode(team.team) { defaults.set(data, forKey: "organization.dictionary") }
  }

  /// Back to personal mode on this Mac. The member stays in the organization until an admin removes them.
  @MainActor
  func leave() {
    KeyStore.removeOrgToken()
    membership = nil
    teamEntries = []
    defaults.removeObject(forKey: "organization")
    defaults.removeObject(forKey: "organization.dictionary")
    NotificationCenter.default.post(name: .diVoiceOrganizationChanged, object: nil)
  }

  @MainActor
  func setHideFromTeam(_ hide: Bool) async throws {
    guard let client else { return }
    try await client.send("PATCH", "/v2/me", json: ["hideFromTeam": hide])
    membership?.member.hideFromTeam = hide
  }

  /// After the admin changes settings: the members' apps pick them up at their next refresh.
  @MainActor
  func adopt(_ settings: AdminSettings) {
    guard var updated = membership else { return }
    updated.orgName = settings.name
    updated.pipeline = settings.pipeline
    updated.leaderboardEnabled = settings.leaderboardEnabled
    let me = Me(member: updated.member, org: .init(name: settings.name), pipeline: settings.pipeline, leaderboardEnabled: settings.leaderboardEnabled)
    apply(me, server: updated.server)
  }

  /// Shows a sample membership without saving anything (screenshots).
  @MainActor
  func setPreview(_ membership: Membership?, teamEntries: [VocabularyEntry]) {
    previewing = true
    self.membership = membership
    self.teamEntries = teamEntries
  }

  /// The team's terms first, then the member's own; the same term once.
  func vocabulary(personal: [VocabularyEntry]) -> [VocabularyEntry] {
    var seen = Set<String>()
    return (teamEntries.filter(\.enabled) + personal).filter { seen.insert($0.term.lowercased()).inserted }
  }
}

// MARK: - Finding the invite

/// The invite a colleague downloaded diVoice from. The server names invite downloads
/// "diVoice (Org) [host code].dmg" and macOS lists open disk images by name, so diVoice finds
/// the invite without reading any file. It needs the disk image to be still open: opened from
/// it, or dragged to Applications and opened right away. (macOS no longer exposes where a
/// download came from, and Safari doesn't record it on the file.)
enum InviteDetector {
  static func fromDiskImages(bundleURL: URL = Bundle.main.bundleURL) -> InviteLink? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info", "-plist"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let images = info["images"] as? [[String: Any]]
    else { return nil }
    // The disk image diVoice runs from first, then any other one with an invite.
    let path = bundleURL.path
    let candidates = images.sorted { a, b in contains(a, path) && !contains(b, path) }
    for image in candidates {
      guard let imagePath = image["image-path"] as? String else { continue }
      if let link = InviteLink.parse(diskImageName: (imagePath as NSString).lastPathComponent) { return link }
    }
    return nil
  }

  private static func contains(_ image: [String: Any], _ path: String) -> Bool {
    let entities = image["system-entities"] as? [[String: Any]] ?? []
    return entities.contains { ($0["mount-point"] as? String).map { path.hasPrefix($0 + "/") } ?? false }
  }

  private static let handledKey = "handledInvites"

  /// Each invite is offered once: declining or joining doesn't bring it back at the next launch.
  static func isHandled(_ link: InviteLink) -> Bool {
    (UserDefaults.standard.stringArray(forKey: handledKey) ?? []).contains(link.code)
  }

  static func markHandled(_ link: InviteLink) {
    var handled = UserDefaults.standard.stringArray(forKey: handledKey) ?? []
    guard !handled.contains(link.code) else { return }
    handled.append(link.code)
    UserDefaults.standard.set(Array(handled.suffix(50)), forKey: handledKey)
  }
}

/// A draft in the user's mail app with the invite: the user sends it, diVoice sends nothing.
enum InviteMail {
  static func draft(to emails: [String], orgName: String, link: URL, from sender: String) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.queryItems = [
      URLQueryItem(name: "bcc", value: emails.joined(separator: ",")),
      URLQueryItem(name: "subject", value: String(localized: "Join \(orgName) on diVoice")),
      URLQueryItem(
        name: "body",
        value: [
          String(localized: "Hi,"),
          String(localized: "I'm inviting you to \(orgName) on diVoice, voice dictation for the Mac: hold Fn, speak, and the text appears where you're typing."),
          String(localized: "Open this link to download diVoice and join: \(link.absoluteString)"),
          sender,
        ].joined(separator: "\n\n")),
    ]
    return components.url
  }
}
