import Foundation

/// An invite to an organization's diVoice server, from any of the forms it reaches the app in:
/// - the page link, https://<server>/i/<code> (pasted, or from the download's metadata);
/// - the download link, https://<server>/i/<code>/download;
/// - the page's "Open diVoice" button, divoice://join?server=<url>&code=<code>;
/// - the name of the downloaded disk image, "diVoice (Org) [<host> <code>].dmg".
public struct InviteLink: Equatable, Sendable, Codable {
  public var server: URL
  public var code: String

  public init(server: URL, code: String) {
    self.server = server
    self.code = code
  }

  public static func parse(_ text: String) -> InviteLink? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return parse(url)
  }

  public static func parse(_ url: URL) -> InviteLink? {
    if url.scheme?.lowercased() == "divoice" {
      guard url.host?.lowercased() == "join",
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
        let serverText = items.first(where: { $0.name == "server" })?.value,
        let code = items.first(where: { $0.name == "code" })?.value,
        let server = URL(string: serverText).flatMap(serverRoot)
      else { return nil }
      return valid(code) ? InviteLink(server: server, code: code) : nil
    }
    guard let server = serverRoot(url) else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 2, parts[0] == "i", valid(parts[1]), parts.count == 2 || (parts.count == 3 && parts[2] == "download") else {
      return nil
    }
    return InviteLink(server: server, code: parts[1])
  }

  /// The invite in a disk image's name, as the server names invite downloads: "[host code]"
  /// anywhere in the name (browsers may add " (1)" or "-2").
  public static func parse(diskImageName name: String) -> InviteLink? {
    var rest = Substring(name)
    while let open = rest.firstIndex(of: "[") {
      let after = rest[rest.index(after: open)...]
      guard let close = after.firstIndex(of: "]") else { return nil }
      let parts = after[..<close].split(separator: " ")
      if parts.count == 2, valid(String(parts[1])) {
        let host = String(parts[0]).lowercased()
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
        if host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }), host.contains(".") || local,
          let server = URL(string: "\(local ? "http" : "https")://\(host)").flatMap(serverRoot)
        {
          return InviteLink(server: server, code: String(parts[1]))
        }
      }
      rest = after[after.index(after: close)...]
    }
    return nil
  }

  /// 16 characters of base64url, as the server makes them.
  private static func valid(_ code: String) -> Bool {
    code.count == 16 && code.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
  }

  /// The server's origin: https only, except plain http on this Mac for development.
  public static func serverRoot(_ url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    let local = host == "localhost" || host == "127.0.0.1"
    guard scheme == "https" || (scheme == "http" && local) else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.url
  }

  /// The page to share: https://<server>/i/<code>.
  public var pageURL: URL {
    server.appendingPathComponent("i").appendingPathComponent(code)
  }

  /// A server address as people type or paste it ("diserver.acme.workers.dev",
  /// "https://diserver.acme.workers.dev/", a page on it): its origin, or nil.
  public static func serverAddress(_ text: String) -> URL? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(" ") else { return nil }
    if !text.contains("://") {
      let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
      text = (local ? "http://" : "https://") + text
    }
    guard let url = URL(string: text), let root = serverRoot(url), let host = root.host else { return nil }
    let local = host == "localhost" || host == "127.0.0.1"
    return host.contains(".") && !host.hasSuffix(".") || local ? root : nil
  }
}
