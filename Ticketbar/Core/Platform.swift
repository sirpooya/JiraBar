import Foundation

/// Tech Area, as the team actually records it: sometimes in `customfield_10411`, sometimes only
/// as an emoji suffix on the summary. The field wins; the emoji is the fallback.
enum Platform: String, CaseIterable, Hashable {
    case web
    case mobile

    var label: String {
        switch self {
        case .web: return "Web"
        case .mobile: return "Mobile"
        }
    }

    var symbolName: String {
        switch self {
        case .web: return "globe"
        case .mobile: return "iphone"
        }
    }

    private static let webMarkers: [Character] = ["\u{1F310}"]      // globe
    private static let mobileMarkers: [Character] = ["\u{1F4F1}"]   // phone

    static func detect(techArea: String?, summary: String) -> Platform? {
        if let area = techArea?.trimmingCharacters(in: .whitespacesAndNewlines), !area.isEmpty {
            if area.caseInsensitiveCompare("Web") == .orderedSame { return .web }
            if area.caseInsensitiveCompare("Mobile") == .orderedSame { return .mobile }
        }
        if summary.contains(where: { webMarkers.contains($0) }) { return .web }
        if summary.contains(where: { mobileMarkers.contains($0) }) { return .mobile }
        return nil
    }

    /// Drops the trailing platform emoji so the row does not show the platform twice.
    static func strippingMarker(from summary: String) -> String {
        var text = summary
        while let last = text.trimmingCharacters(in: .whitespaces).last,
              webMarkers.contains(last) || mobileMarkers.contains(last) {
            text = String(text.trimmingCharacters(in: .whitespaces).dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
