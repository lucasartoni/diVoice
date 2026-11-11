import AppKit
import SwiftUI

/// diVoice's look: a warm light background, white and very rounded cards with a thin border
/// and a light shadow, pill labels with an icon, the selected option in a black pill, grey
/// secondary text and a single orange accent for important states (recording). Each colour
/// has its dark-mode counterpart.
enum Theme {
  static let background = Color(light: 0xF6F4F0, dark: 0x1B1A18)
  static let sidebar = Color(light: 0xEFECE7, dark: 0x161514)
  static let card = Color(light: 0xFFFFFF, dark: 0x262522)
  static let border = Color(light: 0xE6E1DA, dark: 0x3A3834)
  /// Pills and selector tracks.
  static let fill = Color(light: 0xF1EEE9, dark: 0x302E2B)
  /// The selected option: black on light, white on dark.
  static let selected = Color(light: 0x1C1B19, dark: 0xF4F2EE)
  static let onSelected = Color(light: 0xFFFFFF, dark: 0x1C1B19)
  static let accent = Color(light: 0xF08A00, dark: 0xFF9F1C)
  static let positive = Color(light: 0x23925A, dark: 0x4CC27A)
  static let cardRadius: CGFloat = 18
}

extension Color {
  /// A colour that follows the window's light or dark appearance.
  init(light: UInt32, dark: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
          alpha: 1)
      })
  }
}

extension View {
  /// White card: very rounded, thin border, light shadow.
  func card(radius: CGFloat = Theme.cardRadius) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Theme.card)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
    )
    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
  }
}

/// A titled group of settings in a white card.
struct CardSection<Content: View>: View {
  var title: LocalizedStringKey?
  @ViewBuilder var content: Content

  init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
      }
      VStack(alignment: .leading, spacing: 12) { content }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
  }
}

/// A scrolling page of cards on the warm background.
struct CardPage<Content: View>: View {
  @ViewBuilder var content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) { content }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
  }
}

/// A small label in a pill, with an icon.
struct Pill: View {
  var icon: String?
  var text: Text
  var tint: Color = .secondary

  init(_ text: LocalizedStringKey, icon: String? = nil, tint: Color = .secondary) {
    self.text = Text(text)
    self.icon = icon
    self.tint = tint
  }

  init(verbatim: String, icon: String? = nil, tint: Color = .secondary) {
    self.text = Text(verbatim: verbatim)
    self.icon = icon
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: 5) {
      if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
      text.font(.system(size: 11.5, weight: .medium))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background(Capsule().fill(Theme.fill))
  }
}

/// A row: label (and an optional detail) on the left, the control on the right.
struct CardRow<Control: View>: View {
  var title: LocalizedStringKey
  var detail: LocalizedStringKey?
  @ViewBuilder var control: Control

  init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.detail = detail
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13))
        if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      }
      Spacer(minLength: 8)
      control
    }
  }
}

/// A choice among a few options: the selected one in a black pill.
struct PillPicker<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(value: Value, label: LocalizedStringKey)]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(options.enumerated()), id: \.offset) { _, option in
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.label)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.onSelected : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Theme.selected : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(Capsule().fill(Theme.fill))
    .animation(.easeOut(duration: 0.15), value: selection)
  }
}

/// The main action: a black pill (white in dark mode).
struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PrimaryButtonBody(configuration: configuration)
  }

  private struct PrimaryButtonBody: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.onSelected)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.selected.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
    }
  }
}

/// A secondary action: a white pill with a thin border.
struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Capsule().fill(configuration.isPressed ? Theme.fill : Theme.card))
      .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
      .padding(1)
  }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
  static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
  static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// Granted, missing or a warning, as a small pill.
struct StatusPill: View {
  let ok: Bool
  var warning = false

  var body: some View {
    if ok {
      Pill("Granted", icon: "checkmark", tint: Theme.positive)
    } else if warning {
      Pill("Check", icon: "exclamationmark", tint: Theme.accent)
    } else {
      Pill("Missing", icon: "circle", tint: Theme.accent)
    }
  }
}

/// On/off: a black track when on (white in dark mode), light grey when off, white knob.
struct PillSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    PillSwitch(configuration: configuration)
  }

  private struct PillSwitch: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      HStack(spacing: 8) {
        configuration.label
        Capsule()
          .fill(configuration.isOn ? Theme.selected : Theme.fill)
          .overlay(Capsule().strokeBorder(Theme.border, lineWidth: configuration.isOn ? 0 : 1))
          .frame(width: 38, height: 22)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(configuration.isOn ? Theme.onSelected : Color.white)
              .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
              .padding(2.5)
          }
          .opacity(enabled ? 1 : 0.4)
          .animation(.easeOut(duration: 0.15), value: configuration.isOn)
          .onTapGesture { configuration.isOn.toggle() }
          .accessibilityElement()
          .accessibilityAddTraits(.isButton)
          .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
      }
    }
  }
}

extension ToggleStyle where Self == PillSwitchStyle {
  static var pill: PillSwitchStyle { PillSwitchStyle() }
}
