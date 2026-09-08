import Foundation

/// The base direction a block of text should be laid out in, decided by the text itself.
///
/// The comment composer needs this because a Persian sentence typed into a left-to-right box is
/// laid out from the left: the words are individually right-to-left, but the sentence starts on
/// the wrong side and any English word in it lands in the wrong place.
enum TextDirection: Equatable {
    case leftToRight
    case rightToLeft

    /// The direction implied by the first strong character, or nil when there is not one yet.
    ///
    /// Digits, spaces and punctuation are skipped rather than counted as left-to-right, which is
    /// what the Unicode bidi algorithm does with them too. It matters here: a numbered list in
    /// Persian starts "1- ", and treating that digit as strong would lay the whole line out
    /// backwards.
    static func firstStrong(in text: String) -> TextDirection? {
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar) { return .rightToLeft }
            if scalar.properties.isAlphabetic { return .leftToRight }
        }
        return nil
    }

    /// Hebrew, Arabic and Persian, Syriac, Thaana, NKo and Samaritan, plus the Arabic and Hebrew
    /// presentation forms that older documents still carry.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }
}
