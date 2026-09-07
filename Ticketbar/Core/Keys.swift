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
    static let showDescription = "in.pooya.ticketbar.showDescription"
    static let showComments = "in.pooya.ticketbar.showComments"
    /// The status, type and priority chips plus the "updated" line in the detail view.
    static let showMetadata = "in.pooya.ticketbar.showMetadata"
    static let accountDisplayName = "in.pooya.ticketbar.accountDisplayName"
    /// The username from /myself. Used to decide which comments this user may edit.
    static let accountUsername = "in.pooya.ticketbar.accountUsername"
    static let seenIssueKeys = "in.pooya.ticketbar.seenIssueKeys"
    static let seenSetSeeded = "in.pooya.ticketbar.seenSetSeeded"
    static let boardProjectKey = "in.pooya.ticketbar.boardProjectKey"
    static let boardID = "in.pooya.ticketbar.boardID"
    static let cachedColumns = "in.pooya.ticketbar.cachedColumns"
    static let selectedScope = "in.pooya.ticketbar.selectedScope"

    static let defaultBaseURL = "https://works.digikala.com"
    /// The DDS board's project. dds-dashboard's lib/jira.ts uses the same key.
    static let defaultProjectKey = "DDS"
    /// The DDS board, from its own URL:
    /// works.digikala.com/secure/RapidBoard.jspa?rapidView=95&projectKey=DDS
    /// `rapidView` is the board id the Agile API wants. Pinned rather than discovered, because
    /// a project can own several boards and picking the first one returned is a coin toss.
    static let defaultBoardID = 95

    /// The Jira admin sets the real ceiling; these are the bounds the UI offers.
    static let pollMinutesRange: ClosedRange<Int> = 2...5

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            baseURL: defaultBaseURL,
            pollMinutes: 3,
            monochromeIcon: false,
            showBadgeCount: true,
            notifyOnNewIssue: true,
            showDescription: true,
            showComments: true,
            showMetadata: true,
            seenSetSeeded: false,
            boardProjectKey: defaultProjectKey,
            boardID: defaultBoardID,
        ])
    }

    /// Clamped so a hand-edited plist cannot make the app poll every second.
    static func pollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = min(max(defaults.integer(forKey: pollMinutes), pollMinutesRange.lowerBound),
                          pollMinutesRange.upperBound)
        return TimeInterval(minutes * 60)
    }
}
