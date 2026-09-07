import Foundation

/// Every UserDefaults key the app owns, in one place, with the defaults registered at launch.
///
/// `UserDefaults.bool` answers `false` for an absent key and `integer` answers `0`, so a default
/// that is not `false` or `0` has to be registered or the first launch reads the wrong thing.
///
/// The `in.pooya.ticketbar.` prefix is a storage address, not a label. Renaming it strands every
/// setting the user has already made.
enum Keys {
    static let baseURL = "in.pooya.ticketbar.baseURL"
    static let pollMinutes = "in.pooya.ticketbar.pollMinutes"
    static let monochromeIcon = "in.pooya.ticketbar.monochromeIcon"
    static let showBadgeCount = "in.pooya.ticketbar.showBadgeCount"
    static let notifyOnNewIssue = "in.pooya.ticketbar.notifyOnNewIssue"
    static let accountDisplayName = "in.pooya.ticketbar.accountDisplayName"
    static let seenIssueKeys = "in.pooya.ticketbar.seenIssueKeys"
    static let seenSetSeeded = "in.pooya.ticketbar.seenSetSeeded"

    static let defaultBaseURL = "https://works.digikala.com"

    /// The Jira admin sets the real ceiling; these are the bounds the UI offers.
    static let pollMinutesRange: ClosedRange<Int> = 2...5

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            baseURL: defaultBaseURL,
            pollMinutes: 3,
            monochromeIcon: false,
            showBadgeCount: true,
            notifyOnNewIssue: true,
            seenSetSeeded: false,
        ])
    }

    /// Clamped so a hand-edited plist cannot make the app poll every second.
    static func pollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = min(max(defaults.integer(forKey: pollMinutes), pollMinutesRange.lowerBound),
                          pollMinutesRange.upperBound)
        return TimeInterval(minutes * 60)
    }
}
