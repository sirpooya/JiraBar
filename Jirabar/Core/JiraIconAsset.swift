import Foundation

/// Picks the bundled copy of one of Jira's own icons.
///
/// Jira tells us which icon an issue uses: `issuetype.iconUrl` and `priority.iconUrl` point at
/// files like `/images/icons/priorities/medium.svg` on the Jira host. The last path component is
/// the name, so the icon is chosen by what the server actually says rather than by matching the
/// display name, which is translated and renamed and would need a table per instance.
///
/// The files are bundled rather than fetched: they are SVG, and `NSImage` cannot decode SVG at
/// runtime. An asset catalog compiles it at build time, which is the only way these render at all.
enum JiraIconAsset {
    enum Kind: String {
        case issueType = "issuetype"
        case priority
    }

    /// The asset name to try, or nil when the URL is not one of these icons.
    ///
    /// An instance serving PNG avatars for its issue types (`/secure/viewavatar?avatarId=...`)
    /// yields nil here, and the caller falls back to the plain text chip.
    static func name(forIconURL url: String?, kind: Kind) -> String? {
        guard let url, let file = url.split(separator: "?").first?.split(separator: "/").last else {
            return nil
        }
        let name = file
            .split(separator: ".")
            .first?
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard let name, !name.isEmpty else { return nil }
        return "\(kind.rawValue)-\(name)"
    }
}
