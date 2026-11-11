import DiVoiceCore
import DiVoiceEngine
import SwiftUI

/// Joining an organization from an invite: one confirmation, with the name from macOS and,
/// for a team link, the email.
final class JoinModel: ObservableObject {
  let link: InviteLink
  @Published private(set) var info: InviteInfo?
  @Published private(set) var loadError: String?
  @Published var name = NSFullUserName()
  @Published var email = ""
  @Published private(set) var joining = false
  @Published private(set) var joinError: String?

  init(link: InviteLink, preview: InviteInfo? = nil) {
    self.link = link
    info = preview
    if let name = preview?.name { self.name = name }
  }

  @MainActor
  func load() async {
    do {
      let info = try await OrgStore.inviteInfo(link)
      self.info = info
      if let name = info.name { self.name = name }
    } catch {
      loadError = error.localizedDescription
    }
  }

  var canJoin: Bool {
    guard let info, !joining, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    return !info.needsEmail || email.contains("@")
  }

  @MainActor
  func join() async -> Bool {
    guard let info else { return false }
    joining = true
    joinError = nil
    defer { joining = false }
    do {
      try await OrgStore.shared.join(
        link, name: name.trimmingCharacters(in: .whitespaces), email: info.needsEmail ? email.trimmingCharacters(in: .whitespaces) : nil)
      InviteDetector.markHandled(link)
      return true
    } catch {
      joinError = error.localizedDescription
      return false
    }
  }
}

struct JoinView: View {
  @ObservedObject var model: JoinModel
  let onJoined: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Pill("diVoice", icon: "waveform")
      if let info = model.info {
        VStack(alignment: .leading, spacing: 6) {
          Text("Join \(info.org.name)?").font(.system(size: 22, weight: .bold))
          Text(
            info.inviter.map { String(localized: "\($0) invited you to \(info.org.name) on diVoice.") }
              ?? String(localized: "You're invited to \(info.org.name) on diVoice.")
          )
          .font(.system(size: 13))
        }
        VStack(alignment: .leading, spacing: 12) {
          CardRow("Your name") {
            TextField("", text: $model.name).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
          }
          if info.needsEmail {
            Divider()
            CardRow("Your work email") {
              TextField("", text: $model.email, prompt: Text("name@company.com")).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
            }
          } else if let email = info.email {
            Divider()
            CardRow("Email") { Pill(verbatim: email, icon: "envelope") }
          }
          Divider()
          CardRow("Server") { Pill(verbatim: model.link.server.host ?? "", icon: "server.rack") }
        }
        .padding(16)
        .card()
        Text(
          "Your dictations will go through \(model.link.server.host ?? ""), your organization's server, which also holds its AI keys. Your statistics never include what you dictate."
        )
        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let error = model.joinError {
          Pill(verbatim: error, icon: "exclamationmark.triangle", tint: Theme.accent)
        }
        HStack {
          Button("Not now") { onCancel() }.buttonStyle(.secondary)
          Spacer()
          if model.joining { ProgressView().controlSize(.small) }
          Button("Join") {
            Task { if await model.join() { onJoined() } }
          }
          .buttonStyle(.primary)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canJoin)
        }
      } else if let error = model.loadError {
        Text("This invite can't be used").font(.system(size: 22, weight: .bold))
        Text(error).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Close") { onCancel() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
      } else {
        HStack {
          ProgressView().controlSize(.small)
          Text("Opening the invite…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 36)
    .padding(.bottom, 24)
    .frame(width: 500)
    .background(Theme.background)
    .task { if model.info == nil, model.loadError == nil { await model.load() } }
  }
}

/// "Join a team" in the first launch, for whoever has the link but didn't come from it.
struct PasteInviteView: View {
  let onLink: (InviteLink) -> Void
  @State private var text = ""

  private var link: InviteLink? { InviteLink.parse(text) }

  var body: some View {
    HStack {
      TextField("Paste the invite link", text: $text)
        .textFieldStyle(.roundedBorder)
        .onSubmit { if let link { onLink(link) } }
      Button("Continue") { if let link { onLink(link) } }
        .disabled(link == nil)
    }
  }
}
