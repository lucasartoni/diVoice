import AppKit
import DiVoiceEngine
import SwiftUI
import UniformTypeIdentifiers

extension AppCategory {
  /// The name the settings and the history show.
  var title: String {
    switch self {
    case .email: String(localized: "Email")
    case .workChat: String(localized: "Work chat")
    case .personalChat: String(localized: "Personal chat")
    case .docs: String(localized: "Documents and notes")
    case .code: String(localized: "Code and AI assistants")
    case .other: String(localized: "Other apps")
    }
  }

  var examples: String {
    switch self {
    case .email: String(localized: "Mail, Outlook, Gmail, Spark")
    case .workChat: String(localized: "Slack, Teams, Google Chat, Linear")
    case .personalChat: String(localized: "Messages, WhatsApp, Telegram, Discord")
    case .docs: String(localized: "Notes, Notion, Word, Google Docs")
    case .code: String(localized: "Editors, terminals, Claude, ChatGPT")
    case .other: String(localized: "Everything else")
    }
  }

  fileprivate var instructionsExample: String {
    switch self {
    case .email: String(localized: "For example: I use “Lei” with clients, and I sign “Ada”.")
    case .workChat: String(localized: "For example: short sentences, no emoji.")
    case .personalChat: String(localized: "For example: I write “ok” in lowercase.")
    default: String(localized: "For example: headings in sentence case.")
    }
  }
}

extension Tone {
  var title: String {
    switch id {
    case "formal": String(localized: "Formal")
    case "cordial": String(localized: "Cordial")
    case "direct": String(localized: "Direct")
    case "professional": String(localized: "Professional")
    case "informal": String(localized: "Informal")
    case "natural": String(localized: "Natural")
    case "polished": String(localized: "Polished")
    case "notes": String(localized: "Notes")
    default: id
    }
  }
}

/// Settings › Style: the tone and the user's own instructions for each kind of app, and the
/// apps and websites they assign to one.
struct StyleView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject private var learning: LearningStore
  /// Sample preferences for the screenshots: nothing is saved.
  private let preview: Bool
  @State private var local: StylePreferences
  @State private var newCategory: AppCategory = .email
  @State private var website = ""

  init(settings: AppSettings, preview: StylePreferences? = nil, learning: LearningStore? = nil) {
    self.settings = settings
    self.preview = preview != nil
    _local = State(initialValue: preview ?? StylePreferences())
    _learning = ObservedObject(wrappedValue: learning ?? .shared)
  }

  private var style: Binding<StylePreferences> {
    preview ? $local : $settings.style
  }

  var body: some View {
    CardPage {
      Text("diVoice recognizes the app you're writing in and adapts the text to it. Choose the tone for each kind of app, and add your own instructions: they apply to dictation and to Scribe.")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ForEach(Categories.adjustable, id: \.self) { category in
        CardSection(LocalizedStringKey(category.title)) {
          HStack(alignment: .center, spacing: 12) {
            Text(verbatim: category.examples).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            PillPicker(selection: tone(category), options: (Categories.tones[category] ?? []).map { ($0.id, LocalizedStringKey($0.title)) })
          }
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            Text("Your instructions").font(.system(size: 13))
            TextField("", text: instructions(category), prompt: Text(verbatim: category.instructionsExample), axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .lineLimit(2...4)
          }
        }
      }
      rules
      learned
    }
  }

  private var learned: some View {
    CardSection("Learned from your corrections") {
      CardRow(
        "Learn from my corrections",
        detail: "When you fix a dictated text, diVoice learns: names go into your dictionary, and after a few corrections in a kind of app it notes how you like to write there. The corrections stay on this Mac for 7 days."
      ) {
        Toggle("", isOn: $settings.learnFromCorrections).toggleStyle(.pill).labelsHidden()
      }
      ForEach(Categories.adjustable, id: \.self) { category in
        let text = learning.learned[category.rawValue]
        if text != nil || learning.waiting(category) > 0 {
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(verbatim: category.title).font(.system(size: 13))
              Spacer()
              if text != nil { Button("Forget") { learning.forget(category) }.buttonStyle(.secondary) }
            }
            if text != nil {
              TextField("", text: learnedText(category), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            } else {
              Text("\(learning.waiting(category).formatted()) of \(StyleLearning.batch.formatted()) corrections collected")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func learnedText(_ category: AppCategory) -> Binding<String> {
    Binding(get: { learning.learned[category.rawValue] ?? "" }, set: { learning.setLearned($0, for: category) })
  }

  private var rules: some View {
    CardSection("Apps and websites") {
      Text("diVoice recognizes most apps by itself. Assign the others to a kind of app, or a website by a word of its window title.")
        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ForEach(style.wrappedValue.rules) { rule in
        HStack(spacing: 10) {
          icon(rule).resizable().frame(width: 18, height: 18)
          Text(verbatim: rule.name).font(.system(size: 13))
          Text(rule.kind == .app ? "App" : "Website").font(.system(size: 11.5)).foregroundStyle(.secondary)
          Spacer()
          categoryPicker(ruleCategory(rule.id))
          Button {
            style.wrappedValue.rules.removeAll { $0.id == rule.id }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Remove")
        }
        Divider()
      }
      HStack(spacing: 8) {
        categoryPicker($newCategory)
        Button("Add app…") { addApp() }.buttonStyle(.secondary)
        TextField("", text: $website, prompt: Text("Title word, e.g. hubspot"))
          .textFieldStyle(.roundedBorder)
          .onSubmit { addWebsite() }
        Button("Add website") { addWebsite() }
          .buttonStyle(.secondary)
          .disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func categoryPicker(_ selection: Binding<AppCategory>) -> some View {
    Picker("", selection: selection) {
      ForEach(AppCategory.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
    }
    .labelsHidden()
    .fixedSize()
  }

  private func icon(_ rule: AppRule) -> Image {
    if rule.kind == .app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.value) {
      return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
    return Image(systemName: rule.kind == .app ? "app" : "globe")
  }

  private func tone(_ category: AppCategory) -> Binding<String> {
    Binding(
      get: { style.wrappedValue.tone(for: category) ?? "" },
      set: { id in
        // The default tone is stored as no choice: a later default follows the app.
        style.wrappedValue.tones[category.rawValue] = id == Categories.defaultTone[category] ? nil : id
      })
  }

  private func instructions(_ category: AppCategory) -> Binding<String> {
    Binding(
      get: { style.wrappedValue.instructions[category.rawValue] ?? "" },
      set: { text in
        let trimmed = String(text.prefix(StylePreferences.maxInstructions))
        style.wrappedValue.instructions[category.rawValue] = trimmed.isEmpty ? nil : trimmed
      })
  }

  private func ruleCategory(_ id: UUID) -> Binding<AppCategory> {
    Binding(
      get: { style.wrappedValue.rules.first { $0.id == id }?.category ?? .other },
      set: { category in
        guard let index = style.wrappedValue.rules.firstIndex(where: { $0.id == id }) else { return }
        style.wrappedValue.rules[index].category = category
      })
  }

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = String(localized: "Choose")
    guard panel.runModal() == .OK, let url = panel.url, let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
    let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    style.wrappedValue.rules.removeAll { $0.kind == .app && $0.value == bundleId }
    style.wrappedValue.rules.append(AppRule(kind: .app, value: bundleId, name: name, category: newCategory))
  }

  private func addWebsite() {
    let word = website.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !word.isEmpty else { return }
    style.wrappedValue.rules.removeAll { $0.kind == .website && $0.value == word }
    style.wrappedValue.rules.append(AppRule(kind: .website, value: word, name: word, category: newCategory))
    website = ""
  }
}
