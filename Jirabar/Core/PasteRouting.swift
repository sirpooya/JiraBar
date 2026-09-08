import Foundation

/// Decides whether a paste carrying both image bytes and text is an image paste or a text paste.
///
/// It has to be decided, because a copy usually puts several representations on the pasteboard at
/// once: a screenshot copied from an app carries image bytes and nothing else, an image copied
/// from a browser carries the bytes plus its source URL as text, and a copied paragraph carries
/// only text.
enum PasteRouting {
    /// True when the image is what the person meant.
    ///
    /// The image wins whenever there are image bytes, unless the text alongside them is real
    /// prose. This used to be the other way round, and any text at all beat the image: copying a
    /// screenshot out of a browser or a design tool pasted the file name or the source URL as a
    /// line of text and quietly dropped the picture.
    static func prefersImage(hasImageData: Bool, text: String?) -> Bool {
        guard hasImageData else { return false }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return true
        }
        return !isProse(text)
    }

    /// Prose is more than one word and is not an address or a file name. A URL or a name like
    /// `pastedImage_9_6_2026.png` is a label for the image, not something anybody wants typed
    /// into their comment.
    private static func isProse(_ text: String) -> Bool {
        if text.contains(where: \.isWhitespace) {
            return !looksLikeAddress(text)
        }
        return false
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
    }
}
