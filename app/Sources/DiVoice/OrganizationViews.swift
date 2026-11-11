import AppKit
import Charts
import DiVoiceCore
import DiVoiceEngine
import SwiftUI

// MARK: - Team

/// Settings › Team, with an organization: your statistics (from every Mac you use) and the leaderboard.
struct TeamView: View {
  @ObservedObject var org: OrgStore
  @ObservedObject var settings: AppSettings
  @State private var period = 7
  @State private var mine: MyStats?
  @State private var team: TeamStats?
  @State private var error: String?
  @State private var hide = false

  private var days: String { period == 0 ? "all" : String(period) }
  /// Sample data for the screenshots: nothing is loaded from the server.
  private let preview: Bool

  init(org: OrgStore, settings: AppSettings, preview: (MyStats, TeamStats)? = nil) {
    self.org = org
    self.settings = settings
    self.preview = preview != nil
    _mine = State(initialValue: preview?.0)
    _team = State(initialValue: preview?.1)
  }

  var body: some View {
    CardPage {
      PillPicker(selection: $period, options: [(1, "Today"), (7, "7 days"), (30, "30 days"), (0, "All time")])

      HStack(spacing: 12) {
        StatTile(title: "Words dictated", value: mine.map { $0.summary.words.formatted() } ?? "—")
        StatTile(title: "Time saved", value: mine.map { Format.duration($0.summary.savedSeconds) } ?? "—")
        StatTile(title: "Words per minute", value: mine?.summary.wordsPerMinute.map { Int($0.rounded()).formatted() } ?? "—")
        StatTile(title: "Day streak", value: mine.map { $0.summary.streakDays.formatted() } ?? "—")
      }

      if let team, team.leaderboardEnabled {
        CardSection("Leaderboard") {
          VStack(spacing: 0) {
            ForEach(Array(team.members.enumerated()), id: \.element.id) { index, row in
              if index > 0 { Divider() }
              HStack(spacing: 12) {
                Text(verbatim: String(index + 1)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                  .frame(width: 18)
                Text(row.name).font(.system(size: 13, weight: row.isMe ? .semibold : .regular))
                if row.isMe { Pill("You") }
                Spacer()
                Pill(verbatim: row.words.formatted(), icon: "text.word.spacing")
                Pill(verbatim: Format.duration(row.savedSeconds), icon: "clock")
                Pill(verbatim: row.wordsPerMinute.map { String(Int($0.rounded())) } ?? "—", icon: "speedometer")
                Pill(verbatim: String(row.streakDays), icon: "flame", tint: row.streakDays > 0 ? Theme.accent : .secondary)
              }
              .padding(.vertical, 8)
            }
          }
        }
      } else if team != nil {
        Text("Your organization's admin turned the leaderboard off: only you see your statistics.")
          .font(.system(size: 12.5)).foregroundStyle(.secondary)
      }

      CardSection {
        CardRow(
          "Hide me from the team",
          detail: "Hidden, you don't appear in the leaderboard and nobody else sees your statistics. Statistics count words and time, never what you dictate."
        ) {
          Toggle("", isOn: $hide).toggleStyle(.pill).labelsHidden()
        }
      }
      .onChange(of: hide) { _, value in
        guard !preview, value != (org.membership?.member.hideFromTeam ?? false) else { return }
        Task { @MainActor in
          do {
            try await org.setHideFromTeam(value)
            await load()
          } catch {
            self.error = error.localizedDescription
          }
        }
      }
      if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.accent) }
    }
    .task(id: period) { if !preview { await load() } }
    // The settings window stays open across uses: reload after each dictation and when it comes back.
    .onReceive(NotificationCenter.default.publisher(for: .diVoiceDictationRecorded)) { _ in
      if !preview, org.membership != nil { Task { await load() } }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if !preview, org.membership != nil { Task { await load() } }
    }
    .onAppear { hide = org.membership?.member.hideFromTeam ?? false }
  }

  @MainActor
  private func load() async {
    guard let client = org.client else { return }
    let query = [URLQueryItem(name: "today", value: DictationStats.dayKey(Date())), URLQueryItem(name: "days", value: days)]
    do {
      mine = try await client.get(MyStats.self, "/v2/stats/me", query: query)
      team = try await client.get(TeamStats.self, "/v2/stats/team", query: query)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct StatTile: View {
  let title: LocalizedStringKey
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 22, weight: .bold).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .card(radius: 16)
  }
}

// MARK: - Organization

/// Settings › Organization: for everyone, the membership; for admins, the panel.
struct OrganizationView: View {
  @ObservedObject var org: OrgStore
  let membership: Membership
  @State private var confirmLeave = false

  var preview: AdminModel?

  var body: some View {
    CardPage {
      CardSection("Organization") {
        CardRow("Name") { Text(membership.orgName).font(.system(size: 13, weight: .semibold)) }
        Divider()
        CardRow("Server") { Pill(verbatim: membership.host, icon: "server.rack") }
        Divider()
        CardRow("You") { Text(verbatim: "\(membership.member.name) · \(membership.member.email)").foregroundStyle(.secondary) }
        Divider()
        CardRow("Role") { membership.isAdmin ? Pill("Admin", icon: "crown") : Pill("Member", icon: "person") }
        Divider()
        Button("Leave the organization on this Mac…", role: .destructive) { confirmLeave = true }.buttonStyle(.secondary)
      }
      if membership.isAdmin {
        AdminSections(org: org, preview: preview)
      }
    }
    .confirmationDialog("Leave \(membership.orgName) on this Mac?", isPresented: $confirmLeave) {
      Button("Leave", role: .destructive) { org.leave() }
    } message: {
      Text("diVoice goes back to personal mode, with your own API keys. To come back you'll need a new invite.")
    }
  }
}

/// The admin's tools: provider keys, models, invites, members, team dictionary, leaderboard.
final class AdminModel: ObservableObject {
  @Published var settings: AdminSettings?
  @Published var draft: PipelineSettings?
  @Published var members: [MemberRow] = []
  @Published var invites: [OrgInvite] = []
  @Published var team: [VocabularyEntry] = []
  @Published var keyInput: [ProviderID: String] = [:]
  @Published var message: String?
  @Published var error: String?
  @Published var busy = false

  private var client: OrgClient? { OrgStore.shared.client }

  @MainActor
  func load() async {
    guard let client else { return }
    struct Members: Decodable { var members: [MemberRow] }
    struct Invites: Decodable { var invites: [OrgInvite] }
    struct Team: Decodable { var team: [VocabularyEntry] }
    do {
      let settings = try await client.get(AdminSettings.self, "/v2/admin/settings")
      self.settings = settings
      if draft == nil { draft = settings.pipeline }
      members = try await client.get(Members.self, "/v2/admin/members").members
      invites = try await client.get(Invites.self, "/v2/admin/invites").invites
      team = try await client.get(Team.self, "/v2/dictionary").team
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  @MainActor
  private func run(_ work: @escaping (OrgClient) async throws -> Void) {
    guard let client else { return }
    busy = true
    Task { @MainActor in
      do {
        try await work(client)
        error = nil
      } catch {
        self.error = error.localizedDescription
      }
      busy = false
      await load()
    }
  }

  @MainActor
  func saveKey(_ provider: ProviderID) {
    let key = (keyInput[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    keyInput[provider] = ""
    run { client in
      try await client.send("PUT", "/v2/admin/keys/\(provider.rawValue)", json: ["key": key])
      self.message = String(localized: "\(provider.displayName) key saved on the server.")
    }
  }

  @MainActor
  func removeKey(_ provider: ProviderID) {
    run { client in try await client.send("DELETE", "/v2/admin/keys/\(provider.rawValue)") }
  }

  @MainActor
  func save(_ changes: [String: Any]) {
    run { client in
      let settings = try await client.send(AdminSettings.self, "PATCH", "/v2/admin/settings", json: changes)
      self.settings = settings
      self.draft = settings.pipeline
      OrgStore.shared.adopt(settings)
      self.message = String(localized: "Saved: members get the change at their next dictation.")
    }
  }

  @MainActor
  func savePipeline() {
    guard let draft else { return }
    save(["pipeline": OrgClient.object(draft)])
  }

  /// A team link, copied: reuses one that is still valid.
  @MainActor
  func copyTeamLink() {
    run { client in
      let existing = self.invites.first { $0.kind == "team" && $0.emails == nil && $0.role == "member" }
      let invite: OrgInvite
      if let existing {
        invite = existing
      } else {
        struct Created: Decodable { var invite: OrgInvite }
        invite = try await client.send(Created.self, "POST", "/v2/admin/invites", json: ["kind": "team"]).invite
      }
      Self.copy(invite.url)
      self.message = String(
        localized: "Team link copied. It works for anyone who has it until \(invite.expires.formatted(date: .abbreviated, time: .omitted)).")
    }
  }

  /// A link for these addresses only, in a draft in the mail app.
  @MainActor
  func emailInvite(_ emails: [String], orgName: String) {
    run { client in
      struct Created: Decodable { var invite: OrgInvite }
      let invite = try await client.send(Created.self, "POST", "/v2/admin/invites", json: ["kind": "team", "emails": emails]).invite
      if let mail = InviteMail.draft(to: emails, orgName: orgName, link: invite.url, from: NSFullUserName()) {
        NSWorkspace.shared.open(mail)
      }
      self.message = String(localized: "Email ready in your mail app: check it and send it.")
    }
  }

  @MainActor
  func personalInvite(name: String, email: String, admin: Bool) {
    run { client in
      struct Created: Decodable { var invite: OrgInvite }
      let invite = try await client.send(
        Created.self, "POST", "/v2/admin/invites", json: ["kind": "personal", "name": name, "email": email, "role": admin ? "admin" : "member"]
      ).invite
      Self.copy(invite.url)
      self.message = String(localized: "Personal link for \(name) copied: it works once.")
    }
  }

  @MainActor
  func revoke(_ invite: OrgInvite) {
    run { client in try await client.send("DELETE", "/v2/admin/invites/\(invite.code)") }
  }

  @MainActor
  func setRole(_ member: MemberRow, admin: Bool) {
    run { client in try await client.send("PATCH", "/v2/admin/members/\(member.id)", json: ["role": admin ? "admin" : "member"]) }
  }

  @MainActor
  func remove(_ member: MemberRow) {
    run { client in try await client.send("DELETE", "/v2/admin/members/\(member.id)") }
  }

  @MainActor
  func addTerm(_ term: String, aliases: [String]) {
    run { client in try await client.send("POST", "/v2/dictionary", json: ["term": term, "aliases": aliases]) }
  }

  @MainActor
  func removeTerm(_ entry: VocabularyEntry) {
    run { client in try await client.send("DELETE", "/v2/dictionary/\(entry.id)") }
  }

  static func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
}

struct AdminSections: View {
  @ObservedObject var org: OrgStore
  @StateObject private var model: AdminModel
  private let preview: Bool

  init(org: OrgStore, preview: AdminModel? = nil) {
    self.org = org
    _model = StateObject(wrappedValue: preview ?? AdminModel())
    self.preview = preview != nil
  }
  @State private var emails = ""
  @State private var personalName = ""
  @State private var personalEmail = ""
  @State private var personalAdmin = false
  @State private var term = ""
  @State private var aliases = ""
  @State private var orgName = ""

  private var emailList: [String] {
    emails.split(whereSeparator: { ",; \n".contains($0) }).map(String.init).filter { $0.contains("@") }
  }

  /// The providers the server knows, from its key list: ElevenLabs only once diServer supports it.
  private var serverProviders: [ProviderID] {
    let known = model.settings?.keys.compactMap { ProviderID(rawValue: $0.provider) } ?? []
    return known.isEmpty ? ProviderID.chatProviders : ProviderID.allCases.filter(known.contains)
  }

  var body: some View {
    Group {
      if let message = model.message {
        Pill(verbatim: message, icon: "checkmark", tint: Theme.positive)
      }
      if let error = model.error {
        Pill(verbatim: error, icon: "exclamationmark.triangle", tint: Theme.accent)
      }

      CardSection("Invite") {
        CardRow("Team link", detail: "Anyone with the link joins, for 7 days. Paste it in your team's chat.") {
          Button {
            model.copyTeamLink()
          } label: {
            Label("Copy team link", systemImage: "link")
          }
          .buttonStyle(.primary)
        }
        Divider()
        HStack {
          TextField("", text: $emails, prompt: Text("Email addresses, separated by commas"))
            .textFieldStyle(.roundedBorder).labelsHidden()
          Button("Create email") {
            model.emailInvite(emailList, orgName: org.membership?.orgName ?? "")
            emails = ""
          }
          .buttonStyle(.secondary)
          .disabled(emailList.isEmpty)
        }
        DisclosureGroup("Personal link") {
          TextField("", text: $personalName, prompt: Text("Name")).textFieldStyle(.roundedBorder).labelsHidden()
          TextField("", text: $personalEmail, prompt: Text("Email")).textFieldStyle(.roundedBorder).labelsHidden()
          Toggle("Admin", isOn: $personalAdmin)
          Button("Copy personal link") {
            model.personalInvite(name: personalName, email: personalEmail, admin: personalAdmin)
            personalName = ""
            personalEmail = ""
            personalAdmin = false
          }
          .buttonStyle(.secondary)
          .disabled(personalName.trimmingCharacters(in: .whitespaces).isEmpty || !personalEmail.contains("@"))
          Text("Works once, with name and email already filled in. Also to reconnect a member on a new Mac.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        ForEach(model.invites) { invite in
          HStack {
            Pill(
              verbatim: invite.kind == "personal"
                ? (invite.name ?? invite.email ?? "") : (invite.emails?.joined(separator: ", ") ?? String(localized: "Team link")),
              icon: invite.kind == "personal" ? "person" : "link")
            Spacer()
            Text("until \(invite.expires.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button("Copy") { AdminModel.copy(invite.url) }.buttonStyle(.secondary)
            Button("Revoke") { model.revoke(invite) }.buttonStyle(.secondary)
          }
        }
      }

      CardSection("Members") {
        ForEach(model.members) { member in
          HStack {
            VStack(alignment: .leading) {
              Text(member.name).bold()
              Text(member.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.hideFromTeam { Pill("Hidden from the team", icon: "eye.slash") }
            if member.role == "admin" { Pill("Admin", icon: "crown") } else { Pill("Member", icon: "person") }
            Menu {
              if member.role == "admin" {
                Button("Make member") { model.setRole(member, admin: false) }
              } else {
                Button("Make admin") { model.setRole(member, admin: true) }
              }
              Button("Remove from the organization", role: .destructive) { model.remove(member) }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(member.id == org.membership?.member.id)
          }
        }
      }

      CardSection("AI provider keys") {
        ForEach(serverProviders) { provider in
          let status = model.settings?.keys.first { $0.provider == provider.rawValue }
          LabeledContent(provider.displayName) {
            if let source = status?.source {
              HStack {
                Pill(
                  verbatim: source == "admin" ? String(localized: "Saved on the server") : String(localized: "Set as a server secret"),
                  icon: "lock.fill", tint: Theme.positive)
                if source == "admin" { Button("Remove") { model.removeKey(provider) }.buttonStyle(.secondary) }
              }
            }
          }
          HStack {
            SecureField(
              "", text: Binding(get: { model.keyInput[provider] ?? "" }, set: { model.keyInput[provider] = $0 }),
              prompt: Text(status?.source == nil ? "Paste the \(provider.displayName) API key" : "Paste a new \(provider.displayName) key to replace it"))
              .textFieldStyle(.roundedBorder).labelsHidden()
              .onSubmit { model.saveKey(provider) }
            Button("Save") { model.saveKey(provider) }
              .buttonStyle(.primary)
              .disabled((model.keyInput[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        Text("Keys are encrypted on your organization's server and never shown again, not even to admins. Members never receive them.")
          .font(.system(size: 11.5)).foregroundStyle(.secondary)
      }

      if model.draft != nil {
        PipelineSections(
          pipeline: Binding(get: { model.draft ?? .defaults(.mistral) }, set: { model.draft = $0 }), setup: nil,
          transcriptionProviders: [.mistral] + (serverProviders.contains(.elevenlabs) ? [.elevenlabs] : []))
        HStack {
          Button("Save models") { model.savePipeline() }
            .buttonStyle(.primary)
            .disabled(model.draft == model.settings?.pipeline)
          Text("Then check them with Verify in the Models tab.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
      }

      CardSection("Team dictionary") {
        HStack {
          TextField("", text: $term, prompt: Text("Term (e.g. Zentrix)")).textFieldStyle(.roundedBorder).labelsHidden()
          TextField("", text: $aliases, prompt: Text("Heard as (comma separated)")).textFieldStyle(.roundedBorder).labelsHidden()
          Button("Add") {
            model.addTerm(term, aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            term = ""
            aliases = ""
          }
          .buttonStyle(.primary)
          .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ForEach(model.team) { entry in
          HStack {
            Text(entry.term).bold()
            Text(entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { model.removeTerm(entry) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
          }
        }
        Text("Everyone's dictation spells these right. Members also keep their own dictionary.")
          .font(.system(size: 11.5)).foregroundStyle(.secondary)
      }

      CardSection("Team") {
        if let settings = model.settings {
          HStack {
            TextField("", text: $orgName, prompt: Text("Organization name")).textFieldStyle(.roundedBorder).labelsHidden()
            Button("Rename") { model.save(["name": orgName]) }
              .buttonStyle(.secondary)
              .disabled(orgName.trimmingCharacters(in: .whitespaces).isEmpty || orgName == settings.name)
          }
          .onAppear { orgName = settings.name }
          Divider()
          CardRow("Leaderboard", detail: "Off, members see only their own statistics.") {
            Toggle("", isOn: Binding(get: { settings.leaderboardEnabled }, set: { model.save(["leaderboardEnabled": $0]) }))
              .toggleStyle(.pill).labelsHidden()
          }
        }
      }
    }
    .disabled(model.busy)
    .task { if !preview { await model.load() } }
  }
}
