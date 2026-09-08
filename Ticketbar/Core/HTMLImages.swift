import Foundation

/// Finds and rewrites the `src` of every `<img>` in a block of server-rendered HTML.
///
/// Jira renders an attached screenshot as `<img src="/secure/attachment/12345/pastedImage.png">`,
/// which is a path on the Jira host behind the same bearer token as everything else. A web view
/// loading it gets no token and, with no base URL, cannot even resolve the path, so the image
/// arrives as a broken placeholder with the file name beside it. The bytes are fetched through the
/// client instead and pasted back in as `data:` URIs, which also means the web view still makes no
/// network requests of its own.
enum HTMLImages {
    private static let pattern = try? NSRegularExpression(
        pattern: "<img\\b[^>]*?\\bsrc\\s*=\\s*([\"'])(.*?)\\1",
        options: [.caseInsensitive])

    /// Every `src` in the document, in order, without duplicates.
    static func sources(in html: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for source in allSources(in: html) where !seen.contains(source) {
            seen.insert(source)
            found.append(source)
        }
        return found
    }

    /// Replaces each `src` with what `replacement` returns for it. A source the replacement has
    /// nothing for is left exactly as it was, so a half-loaded thread still renders.
    static func rewriting(_ html: String, using replacement: (String) -> String?) -> String {
        guard let pattern else { return html }
        let text = html as NSString
        var result = html
        // Backwards, so replacing one match cannot move the ranges of the ones not yet done.
        let matches = pattern.matches(in: html, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() where match.numberOfRanges > 2 {
            let range = match.range(at: 2)
            guard range.location != NSNotFound else { continue }
            let source = text.substring(with: range)
            guard let replaced = replacement(source) else { continue }
            result = (result as NSString).replacingCharacters(in: range, with: replaced)
        }
        return result
    }

    private static func allSources(in html: String) -> [String] {
        guard let pattern else { return [] }
        let text = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                guard match.numberOfRanges > 2 else { return nil }
                let range = match.range(at: 2)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("data:") }
    }

    /// From the file extension, because the attachment endpoint's own content type is not always
    /// specific. An unknown extension is called a PNG: every browser sniffs the bytes anyway.
    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "image/png"
        }
    }

    static func dataURI(mime: String, data: Data) -> String {
        "data:\(mime);base64," + data.base64EncodedString()
    }
}
