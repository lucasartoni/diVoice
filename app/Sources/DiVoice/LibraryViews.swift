import Charts
import DiVoiceCore
import DiVoiceEngine
import SwiftUI

/// Settings › Dictionary: terms diVoice should always spell right, and how they get misheard.
struct DictionaryView: View {
  @ObservedObject var store: VocabularyStore
  @ObservedObject var org = OrgStore.shared
  @State private var term = ""
  @State private var aliases = ""
  @State private var note = ""
  @State private var editing: VocabularyEntry?

  private static func aliasList(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  var body: some View {
    CardPage {
      Text("Names, brands and terms with their correct spelling. Wrong forms are replaced automatically; the terms also guide the transcription.")
        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      CardSection("Add a term") {
        HStack {
          TextField("", text: $term, prompt: Text("Term (e.g. Zentrix)")).textFieldStyle(.roundedBorder).labelsHidden().frame(minWidth: 130)
          TextField("", text: $aliases, prompt: Text("Heard as (comma separated)")).textFieldStyle(.roundedBorder).labelsHidden()
            .frame(minWidth: 180)
          TextField("", text: $note, prompt: Text("Note")).textFieldStyle(.roundedBorder).labelsHidden()
          Button("Add") { add() }
            .buttonStyle(.primary)
            .disabled(VocabularyStore.clean(term: term) == nil)
        }
        .onSubmit { add() }
      }
      CardSection("Your terms") {
        if store.entries.isEmpty {
          ContentUnavailableView("No terms yet", systemImage: "character.book.closed", description: Text("Add names and terms that diVoice gets wrong."))
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
          Table(store.entries) {
            TableColumn("Term") { Text($0.term).bold() }.width(min: 100, ideal: 130)
            TableColumn("Heard as") { Text($0.aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
            TableColumn("Note") { Text($0.note ?? "").foregroundStyle(.secondary) }
            TableColumn("Uses") { Text("\($0.usageCount)").monospacedDigit() }.width(40)
            TableColumn("") { entry in
              HStack(spacing: 4) {
                Button { editing = entry } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                Button { store.remove([entry.id]) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
              }
            }
            .width(48)
          }
          .scrollContentBackground(.hidden)
          .frame(minHeight: 240)
        }
      }
      if let membership = org.membership, !org.teamEntries.isEmpty {
        CardSection("From \(membership.orgName)'s dictionary") {
          FlowPills(terms: org.teamEntries.filter(\.enabled).map(\.term))
        }
      }
    }
    .sheet(item: $editing) { entry in
      EntryEditor(entry: entry) { updated in store.update(updated) }
    }
  }

  private func add() {
    guard VocabularyStore.clean(term: term) != nil else { return }
    store.add(term: term, aliases: Self.aliasList(aliases), note: note)
    term = ""
    aliases = ""
    note = ""
  }
}

/// Terms as pills, wrapping onto new lines.
struct FlowPills: View {
  let terms: [String]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(terms, id: \.self) { Pill(verbatim: $0, icon: "character.book.closed") }
    }
  }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 500
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private struct EntryEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var entry: VocabularyEntry
  let onSave: (VocabularyEntry) -> Void
  @State private var aliases = ""

  var body: some View {
    Form {
      TextField("Term", text: $entry.term)
      TextField("Heard as (comma separated)", text: $aliases)
      TextField("Note", text: Binding(get: { entry.note ?? "" }, set: { entry.note = $0.isEmpty ? nil : $0 }))
      Toggle("Enabled", isOn: $entry.enabled)
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .onAppear { aliases = entry.aliases.joined(separator: ", ") }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          entry.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
          onSave(entry)
          dismiss()
        }
        .disabled(VocabularyStore.clean(term: entry.term) == nil)
      }
    }
  }
}

/// Settings › Statistics: computed on this Mac from daily totals, without any text.
struct StatsView: View {
  @ObservedObject var store: StatsStore
  @ObservedObject var settings: AppSettings
  @State private var period = 7

  private var periodDays: Int? { period == 0 ? nil : period }

  var body: some View {
    let summary = store.summary(days: periodDays, typingWPM: settings.typingWPM)
    CardPage {
      PillPicker(selection: $period, options: [(1, "Today"), (7, "7 days"), (30, "30 days"), (0, "All time")])
      HStack(spacing: 12) {
        StatTile(title: "Words dictated", value: summary.words.formatted())
        StatTile(title: "Time saved", value: Format.duration(summary.savedSeconds))
        StatTile(title: "Words per minute", value: summary.wordsPerMinute.map { Int($0.rounded()).formatted() } ?? "—")
        StatTile(title: "Day streak", value: summary.streakDays.formatted())
      }
      CardSection("Last 14 days") {
        Chart(store.recentDays(14), id: \.day) { day in
          BarMark(x: .value("Day", String(day.day.suffix(5))), y: .value("Words", day.words))
            .foregroundStyle(Theme.selected.opacity(0.85))
            .cornerRadius(4)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 170)
      }
      CardSection {
        Stepper(value: $settings.typingWPM, in: 10...150, step: 5) {
          Text("Your typing speed: \(String(settings.typingWPM)) words per minute").font(.system(size: 13))
        }
        Text("Time saved = typing the same words at your typing speed, minus the time spent speaking. Statistics stay on this Mac and never include what you dictated.")
          .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

}
