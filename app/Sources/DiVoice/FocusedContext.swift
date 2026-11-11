import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DiVoiceCore
import DiVoiceEngine

struct CapturedContext {
  var context: DictationContext
  /// Up to 3 characters before the cursor; "" at the start of the field; nil if unreadable.
  var textBefore: String?
  var secureInput: Bool
  /// The focused field and its app, to see what the user corrects after the insertion.
  var field: AXUIElement?
  var pid: pid_t?
  /// Names on screen, for the transcription's vocabulary.
  var screenNames: [String] = []
  /// Characters of context read from the screen, and how long it took (diagnostics, no text).
  var screenChars = 0
  var screenMs: Double = 0
}

/// Reads the active app, window, selection and the text around the cursor via Accessibility.
/// Each read has a short timeout and the screen has an overall budget, so a hung or huge app
/// doesn't slow down dictation.
enum FocusedContextReader {
  private static let timeout: Float = 0.15
  /// The screen around the field: a budget for the whole walk.
  private static let screenBudget: TimeInterval = 0.15
  private static let maxNodes = 1_500

  static func capture(app: NSRunningApplication?, readScreen: Bool) -> CapturedContext {
    var context = DictationContext(bundleId: app?.bundleIdentifier, appName: app?.localizedName)
    var textBefore: String?
    var field: AXUIElement?
    var screenText: String?
    var longBefore: String?
    let secure = IsSecureEventInputEnabled()
    let started = Date()

    if let app {
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(appElement, timeout)
      if readScreen, !secure { WebAccessibility.enable(appElement, app: app) }
      if let window = element(appElement, kAXFocusedWindowAttribute) {
        context.windowTitle = string(window, kAXTitleAttribute)
      }
      if let focused = element(appElement, kAXFocusedUIElementAttribute) {
        AXUIElementSetMessagingTimeout(focused, timeout)
        if let selected = string(focused, kAXSelectedTextAttribute), !selected.isEmpty {
          context.selectedText = String(selected.prefix(20_000))
        }
        textBefore = readTextBefore(focused, length: 3)
        // Never in a password field: there the screen isn't read at all.
        if readScreen, !secure {
          field = focused
          longBefore = readTextBefore(focused, length: DictationContext.maxTextBefore)
          screenText = nearbyText(focused, deadline: Date().addingTimeInterval(screenBudget))
        }
      }
    }

    context.insertion = Insertion(rawValue: SmartSpacing.insertion(textBefore: textBefore).rawValue) ?? .start
    context.textBefore = DictationContext.clip(longBefore, DictationContext.maxTextBefore)
    context.screenText = DictationContext.clip(screenText, DictationContext.maxScreenText)
    let names = TextTools.names(in: [context.windowTitle, context.screenText].compactMap { $0 }.joined(separator: "\n"))
    return CapturedContext(
      context: context, textBefore: textBefore, secureInput: secure, field: field, pid: app?.processIdentifier, screenNames: names,
      screenChars: (context.screenText?.count ?? 0) + (context.textBefore?.count ?? 0), screenMs: Date().timeIntervalSince(started) * 1000)
  }

  /// The text right before the cursor, at most `length` characters; "" at the start of the field.
  private static func readTextBefore(_ element: AXUIElement, length: Int) -> String? {
    guard let rangeValue = value(element, kAXSelectedTextRangeAttribute),
          CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
    if range.location <= 0 { return "" }

    let start = max(0, range.location - length)
    var wanted = CFRange(location: start, length: range.location - start)
    if let parameter = AXValueCreate(.cfRange, &wanted) {
      var result: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(
        element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result
      ) == .success, let text = result as? String {
        return text
      }
    }
    // Fallback: the whole value of the field.
    guard let full = string(element, kAXValueAttribute) else { return nil }
    let ns = full as NSString
    guard range.location <= ns.length else { return nil }
    return ns.substring(with: NSRange(location: start, length: range.location - start))
  }

  /// The text near the field: going up from it, what comes before it at each level (the messages
  /// above a reply box, a recipient, a subject), closest first, until there's enough or time is up.
  private static func nearbyText(_ field: AXUIElement, deadline: Date) -> String? {
    var pieces: [String] = []
    var total = 0
    var nodes = 0
    var current = field
    for _ in 0..<14 {
      guard Date() < deadline, total < DictationContext.maxScreenText, let parent = element(current, kAXParentAttribute) else { break }
      AXUIElementSetMessagingTimeout(parent, timeout)
      let siblings = children(parent)
      let index = siblings.firstIndex { CFEqual($0, current) } ?? siblings.count
      for sibling in siblings[..<index].reversed() {
        guard Date() < deadline, total < DictationContext.maxScreenText else { break }
        let texts = texts(in: sibling, deadline: deadline, nodes: &nodes)
        for text in texts.reversed() where pieces.last != text {
          pieces.append(text)
          total += text.count + 1
        }
      }
      current = parent
    }
    let text = pieces.reversed().joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  /// The visible texts of a subtree, in reading order.
  private static func texts(in root: AXUIElement, deadline: Date, nodes: inout Int) -> [String] {
    var out: [String] = []
    var stack = [root]
    while let node = stack.popLast(), nodes < maxNodes, Date() < deadline {
      nodes += 1
      let role = string(node, kAXRoleAttribute) ?? ""
      if role == kAXStaticTextRole || role == "AXHeading" || role == kAXTextAreaRole || role == kAXTextFieldRole {
        if let text = string(node, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
          out.append(text)
          if role != "AXHeading" { continue }
        }
      }
      // Hidden parts of the interface and controls hold no conversation.
      if role == kAXMenuRole || role == kAXMenuBarRole || role == kAXToolbarRole || role == kAXPopUpButtonRole { continue }
      stack.append(contentsOf: children(node).reversed())
    }
    return out
  }

  private static func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }

  private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
  }

  private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
  }
}

/// Chrome and Electron apps (Slack, Notion...) expose their pages to Accessibility only when an
/// assistive app asks. Asked once per process: the first dictation in a new app may see less.
enum WebAccessibility {
  private static let lock = NSLock()
  private static var asked = Set<pid_t>()
  private static let chromium: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
    "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
  ]

  static func enable(_ appElement: AXUIElement, app: NSRunningApplication) {
    let first = lock.withLock { asked.insert(app.processIdentifier).inserted }
    guard first else { return }
    // Electron's switch; Chromium browsers answer to the one VoiceOver uses.
    let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    if manual != .success, let id = app.bundleIdentifier, chromium.contains(id) {
      AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
  }
}
