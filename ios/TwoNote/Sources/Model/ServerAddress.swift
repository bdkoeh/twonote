import Foundation

/// The one server address the user types on the set-up screen.
enum ServerAddress {
    /// Turns what was typed into the server's base URL, or nil when it cannot be one.
    /// `192.168.1.20:8080` and `nas.local:8080` are read as `http://…` (a self-hosted server on
    /// a LAN or Tailscale address has no certificate); a path, query or trailing slash is dropped.
    static func parse(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return nil
        }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
