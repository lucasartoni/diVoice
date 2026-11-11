import AppKit
import DiVoiceCore
import Security
import SwiftUI

/// Creating an organization: a secret generated here, a diServer deployed on the user's
/// Cloudflare account with its Deploy button, then the first admin claimed with that secret.
final class CreateOrgModel: ObservableObject {
  static let deployURL = URL(string: "https://deploy.workers.cloudflare.com/?url=https://github.com/tommasoseita/diServer/tree/main/deploy")!

  enum Status: Equatable {
    case unchecked, checking, ready, claimed, noSecret
    case unreachable(String)
  }

  let secret: String
  @Published var serverText = ""
  @Published var orgName = ""
  @Published var name = NSFullUserName()
  @Published var email = ""
  @Published var revealed = false
  @Published private(set) var copied = false
  @Published private(set) var status: Status = .unchecked
  @Published private(set) var creating = false
  @Published private(set) var error: String?

  /// `secret` is for previews; otherwise the one saved earlier, or a new one.
  init(secret: String? = nil) {
    if let secret {
      self.secret = secret
    } else if let saved = KeyStore.setupSecret {
      self.secret = saved
    } else {
      let generated = Self.newSecret()
      KeyStore.saveSetupSecret(generated)
      self.secret = generated
    }
  }

  /// 36 random bytes as base64url: 48 characters, safe to paste anywhere.
  static func newSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 36)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  var masked: String { String(repeating: "•", count: 12) + secret.suffix(4) }
  var server: URL? { InviteLink.serverAddress(serverText) }

  var canCreate: Bool {
    status == .ready && !creating && !orgName.trimmingCharacters(in: .whitespaces).isEmpty
      && !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@")
  }

  func copySecret() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(secret, forType: .string)
    copied = true
  }

  /// Preview states for the screenshots.
  func setPreview(server: String, status: Status, copied: Bool) {
    serverText = server
    self.status = status
    self.copied = copied
  }

  @MainActor
  func check() async {
    guard let server else {
      status = serverText.trimmingCharacters(in: .whitespaces).isEmpty ? .unchecked : .unreachable(String(localized: "That isn't a server address."))
      return
    }
    status = .checking
    do {
      let setup = try await OrgStore.setupStatus(server)
      status = setup.claimed ? .claimed : (setup.secretConfigured ? .ready : .noSecret)
    } catch let error as OrgError where error.status == 404 {
      // Cloudflare answers "error code: 1042" until a new workers.dev address is live.
      status = .unreachable(String(localized: "No server answers at this address yet. A new Cloudflare address can take up to an hour to work: check it's the one Cloudflare showed, and try again later."))
    } catch {
      status = .unreachable(error.localizedDescription)
    }
  }

  @MainActor
  func create() async -> Bool {
    guard let server, canCreate else { return false }
    creating = true
    error = nil
    defer { creating = false }
    do {
      try await OrgStore.shared.create(
        server: server, secret: secret, orgName: orgName.trimmingCharacters(in: .whitespaces),
        name: name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))
      KeyStore.removeSetupSecret()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}

struct CreateOrgView: View {
  @ObservedObject var model: CreateOrgModel
  let onCreated: () -> Void
  let onCancel: () -> Void
  /// False for the screenshots, which show the whole page.
  var scrolls = true

  private var serverReady: Bool { model.status == .ready }

  var body: some View {
    if scrolls {
      ScrollView { content }
        .frame(width: 560, height: 700)
        .background(Theme.background)
    } else {
      content.frame(width: 560).background(Theme.background)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Pill("diVoice", icon: "waveform")
        Text("Create an organization").font(.system(size: 22, weight: .bold))
        Text(
          "Your team gets diVoice with nothing to set up: your server holds the AI keys and the models you choose, and colleagues join with a link. It runs on your own Cloudflare account and takes about ten minutes."
        )
        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, 4)

      SetupStep(
        title: "1. Copy your server's secret",
        detail: "Cloudflare asks for it as SERVER_SECRET. It encrypts your team's AI keys: also keep a copy in your password manager.",
        ok: model.copied
      ) {
        HStack {
          Pill(verbatim: model.revealed ? model.secret : model.masked, icon: "key.fill")
            .textSelection(.enabled)
          Spacer()
          Button(model.revealed ? "Hide" : "Show") { model.revealed.toggle() }.buttonStyle(.secondary)
          Button(model.copied ? "Copied" : "Copy") { model.copySecret() }.buttonStyle(.secondary)
        }
        .padding(.top, 2)
      }

      SetupStep(
        title: "2. Deploy the server",
        detail: "Sign in to Cloudflare (the Workers Paid plan is needed), paste the secret, and click Deploy. Cloudflare creates the server, its database, and a GitHub repository that receives its updates.",
        ok: serverReady
      ) {
        Button {
          NSWorkspace.shared.open(CreateOrgModel.deployURL)
        } label: {
          Label("Open Deploy to Cloudflare", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.secondary)
        .padding(.top, 2)
      }

      SetupStep(
        title: "3. Your server's address",
        detail: "Cloudflare shows it when the deploy finishes, for example https://diserver.acme.workers.dev.",
        ok: serverReady
      ) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            TextField("", text: $model.serverText, prompt: Text(verbatim: "https://diserver.acme.workers.dev"))
              .textFieldStyle(.roundedBorder)
              .onSubmit { Task { await model.check() } }
            Button("Check") { Task { await model.check() } }
              .buttonStyle(.secondary)
              .disabled(model.server == nil || model.status == .checking)
          }
          statusLine
        }
        .padding(.top, 2)
      }

      SetupStep(
        title: "4. You and your organization",
        detail: "You become its first admin. Then you'll save the AI key and invite your team from Settings › Organization.",
        ok: model.canCreate
      ) {
        VStack(alignment: .leading, spacing: 10) {
          CardRow("Organization") {
            TextField("", text: $model.orgName, prompt: Text(verbatim: "Acme")).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
          }
          CardRow("Your name") {
            TextField("", text: $model.name).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
          }
          CardRow("Your work email") {
            TextField("", text: $model.email, prompt: Text("name@company.com")).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
          }
        }
        .padding(.top, 4)
      }

      if let error = model.error {
        Pill(verbatim: error, icon: "exclamationmark.triangle", tint: Theme.accent)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Not now") { onCancel() }.buttonStyle(.secondary)
        Spacer()
        if model.creating { ProgressView().controlSize(.small) }
        Button("Create organization") {
          Task { if await model.create() { onCreated() } }
        }
        .buttonStyle(.primary)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canCreate)
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 28)
    .padding(.top, 36)
    .padding(.bottom, 24)
  }

  @ViewBuilder private var statusLine: some View {
    switch model.status {
    case .unchecked:
      EmptyView()
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking the server…").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    case .ready:
      Pill("Ready for its first admin", icon: "checkmark.circle")
    case .claimed:
      Pill("This server already has an admin: ask them for an invite.", icon: "person.crop.circle.badge.exclamationmark", tint: Theme.accent)
    case .noSecret:
      Pill("SERVER_SECRET isn't set on this server yet.", icon: "key", tint: Theme.accent)
    case .unreachable(let message):
      Pill(verbatim: message, icon: "exclamationmark.triangle", tint: Theme.accent)
    }
  }
}
