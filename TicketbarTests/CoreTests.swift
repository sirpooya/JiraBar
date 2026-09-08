import XCTest
@testable import Ticketbar

// MARK: - The rule this app exists to get right

/// A failure must never be renderable as an empty list. This is the test that protects the
/// decision in CLAUDE.md, so if someone adds a `JiraError` case and wires it to `.empty`, it
/// fails here rather than in production three months later when a token quietly expires.
final class ContentStateTests: XCTestCase {

    private let everyError: [JiraError] = [
        .notConfigured,
        .tokenRejected,
        .hostUnreachable("The host name does not resolve."),
        .tlsFailure("The secure connection was refused."),
        .badRequest("bad jql"),
        .notFound("nope"),
        .serverError(503),
        .decodingFailed("shape"),
        .unexpected("who knows"),
    ]

    func testNoErrorEverBecomesTheEmptyState() {
        for error in everyError {
            XCTAssertNotEqual(ContentState.from(error), .empty,
                              "\(error) was rendered as the empty state")
        }
    }

    func testNoErrorEverBecomesAPopulatedList() {
        for error in everyError {
            XCTAssertTrue(ContentState.from(error).issues.isEmpty)
        }
    }

    func testRejectedTokenGetsItsOwnState() {
        XCTAssertEqual(ContentState.from(JiraError.tokenRejected), .tokenRejected)
    }

    func testUnreachableGetsItsOwnStateAndKeepsTheReason() {
        XCTAssertEqual(ContentState.from(JiraError.hostUnreachable("no dns")), .unreachable("no dns"))
    }

    func testOnlyAnActuallyEmptyResultIsTheEmptyState() {
        XCTAssertEqual(ContentState.from([]), .empty)
        XCTAssertEqual(ContentState.from(QCHooks.sampleIssues).issues.count, 4)
    }

    func testBadgeCountIsZeroForEveryFailure() {
        for error in everyError {
            XCTAssertEqual(ContentState.from(error).openCount, 0)
        }
    }

    func testOnlyHealthyStatesAvoidBackoff() {
        XCTAssertTrue(ContentState.empty.isHealthy)
        XCTAssertTrue(ContentState.from(QCHooks.sampleIssues).isHealthy)
        XCTAssertFalse(ContentState.tokenRejected.isHealthy)
        XCTAssertFalse(ContentState.unreachable("x").isHealthy)
    }
}

// MARK: - Error mapping

final class JiraErrorTests: XCTestCase {

    func testUnauthorizedAndForbiddenBothMeanTheTokenIsBad() {
        XCTAssertEqual(JiraError.from(statusCode: 401, message: nil), .tokenRejected)
        XCTAssertEqual(JiraError.from(statusCode: 403, message: nil), .tokenRejected)
    }

    func testSuccessIsNotAnError() {
        XCTAssertNil(JiraError.from(statusCode: 200, message: nil))
        XCTAssertNil(JiraError.from(statusCode: 204, message: nil))
    }

    func testServerErrorsKeepTheirCode() {
        XCTAssertEqual(JiraError.from(statusCode: 503, message: nil), .serverError(503))
    }

    func testReachabilityFailuresMapToUnreachable() {
        let codes: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost,
                                      .cannotConnectToHost, .timedOut, .dnsLookupFailed,
                                      .networkConnectionLost]
        for code in codes {
            guard case .hostUnreachable = JiraError.from(urlError: URLError(code)) else {
                return XCTFail("\(code) should read as unreachable")
            }
        }
    }

    /// A certificate problem is not "you are off the VPN". Saying so would send the user chasing
    /// the wrong fix, which is the same class of mistake as showing an empty list.
    func testCertificateFailuresAreNotReportedAsBeingOffTheVPN() {
        guard case .tlsFailure = JiraError.from(urlError: URLError(.serverCertificateUntrusted)) else {
            return XCTFail("a certificate failure must not be reported as unreachable")
        }
    }

    func testAnUnknownTransportFailureStaysUnknown() {
        guard case .unexpected = JiraError.from(urlError: URLError(.unsupportedURL)) else {
            return XCTFail("an unclassified failure must not be guessed at")
        }
    }
}

// MARK: - Decoding

final class DecodingTests: XCTestCase {

    func testSampleSearchResponseDecodes() {
        XCTAssertEqual(QCHooks.sampleIssues.count, 4, "the QC fixture must parse or the QC pass is blind")
    }

    func testRenderedDescriptionIsPreferredOverRawMarkup() {
        let issue = QCHooks.sampleIssues[0]
        XCTAssertTrue(issue.descriptionHTML?.contains("<p>") == true)
    }

    func testStatusCategoryDrivesDoneRatherThanTheName() {
        let json = """
        {"transitions":[{"id":"31","name":"Ship it","to":{"name":"Shipped",
         "statusCategory":{"key":"done"}}}]}
        """.data(using: .utf8)!
        let list = try! JSONDecoder().decode(JiraTransitionsResponse.self, from: json).transitions
        XCTAssertTrue(list[0].landsInDone, "a transition into the done category counts, whatever it is called")
    }

    func testTransitionsNeedingFieldsAreFlaggedBeforeTheyAreAttempted() {
        let json = """
        {"transitions":[{"id":"41","name":"Resolve","to":{"name":"Done",
         "statusCategory":{"key":"done"}},
         "fields":{"resolution":{"required":true,"name":"Resolution","hasDefaultValue":false},
                   "comment":{"required":false,"name":"Comment"}}}]}
        """.data(using: .utf8)!
        let list = try! JSONDecoder().decode(JiraTransitionsResponse.self, from: json).transitions
        XCTAssertEqual(list[0].blockingFieldNames, ["Resolution"])
    }

    func testAssigneeDecodesAndPrefersTheLargestAvatar() {
        let json = """
        {"total":1,"issues":[{"id":"1","key":"DDS-479","fields":{"summary":"Rating Scale Control",
         "assignee":{"name":"pooya","displayName":"Pouya Kamel","avatarUrls":{
           "16x16":"https://works.digikala.com/secure/useravatar?size=xsmall&ownerId=pooya",
           "48x48":"https://works.digikala.com/secure/useravatar?ownerId=pooya"}}}}]}
        """.data(using: .utf8)!
        let issues = try! JSONDecoder().decode(JiraSearchResponse.self, from: json).issues
        let assignee = issues[0].fields.assignee

        XCTAssertEqual(assignee?.name, "pooya")
        XCTAssertEqual(assignee?.avatarURL?.absoluteString,
                       "https://works.digikala.com/secure/useravatar?ownerId=pooya",
                       "a 20 point circle is 40 pixels on retina, so the largest source wins")
    }

    /// Unassigned is a normal state on this board, not a malformed response.
    func testAnUnassignedIssueStillDecodes() {
        let json = """
        {"total":1,"issues":[{"id":"2","key":"DDS-403","fields":{"summary":"Floating Bottom Sheet"}}]}
        """.data(using: .utf8)!
        let issues = try! JSONDecoder().decode(JiraSearchResponse.self, from: json).issues
        XCTAssertNil(issues[0].fields.assignee)
    }

    /// The fallback drawn until the image arrives, and instead of it when there is none.
    func testInitialsComeFromTheDisplayName() {
        func user(_ name: String) -> JiraUser {
            let json = "{\"displayName\":\"\(name)\"}".data(using: .utf8)!
            return try! JSONDecoder().decode(JiraUser.self, from: json)
        }
        XCTAssertEqual(user("Pouya Kamel").initials, "PK")
        XCTAssertEqual(user("Pooya").initials, "P")
        XCTAssertEqual(user("").initials, "?")
    }

    func testTextDirectionComesFromTheFirstStrongCharacter() {
        XCTAssertEqual(TextDirection.firstStrong(in: "\u{0633}\u{0644}\u{0627}\u{0645}"), .rightToLeft)
        XCTAssertEqual(TextDirection.firstStrong(in: "Hello"), .leftToRight)
        XCTAssertEqual(TextDirection.firstStrong(in: "Hello \u{0633}\u{0644}\u{0627}\u{0645}"),
                       .leftToRight)
    }

    /// A numbered Persian list starts with a digit. Counting that as strong would lay the whole
    /// line out backwards, so weak characters are skipped.
    func testDigitsAndPunctuationDoNotDecideDirection() {
        XCTAssertEqual(TextDirection.firstStrong(in: "1- \u{0633}\u{0644}\u{0627}\u{0645}"),
                       .rightToLeft)
        XCTAssertNil(TextDirection.firstStrong(in: "123 -- ..."))
        XCTAssertNil(TextDirection.firstStrong(in: ""))
    }

    /// The bug this replaced: any text on the pasteboard beat the image, so a screenshot copied
    /// out of a browser pasted its file name and dropped the picture.
    func testAPastedImageBeatsTheLabelThatCameWithIt() {
        XCTAssertTrue(PasteRouting.prefersImage(hasImageData: true, text: nil))
        XCTAssertTrue(PasteRouting.prefersImage(hasImageData: true, text: ""))
        XCTAssertTrue(PasteRouting.prefersImage(hasImageData: true,
                                                text: "pastedImage_9_6_2026__20_18_06_811.png"))
        XCTAssertTrue(PasteRouting.prefersImage(hasImageData: true,
                                                text: "https://works.digikala.com/x.png"))
    }

    func testPastedProseStaysTextAndAPlainTextPasteIsNeverAnImage() {
        XCTAssertFalse(PasteRouting.prefersImage(hasImageData: true,
                                                 text: "please check the spacing here"))
        XCTAssertFalse(PasteRouting.prefersImage(hasImageData: false, text: "anything"))
        XCTAssertFalse(PasteRouting.prefersImage(hasImageData: false, text: nil))
    }

    /// A Jira select field arrives in several shapes depending on configuration. Throwing on the
    /// wrong one would take the whole search response down with it.
    func testCustomFieldAbsorbsEveryShapeItArrivesIn() {
        func decode(_ raw: String) -> String? {
            try? JSONDecoder().decode(CustomFieldValue.self, from: raw.data(using: .utf8)!).stringValue
        }
        XCTAssertEqual(decode("\"Web\""), "Web")
        XCTAssertEqual(decode("{\"value\":\"Mobile\"}"), "Mobile")
        XCTAssertEqual(decode("[{\"value\":\"Web\"}]"), "Web")
        XCTAssertEqual(decode("[\"Mobile\"]"), "Mobile")
        XCTAssertNil(decode("null"))
        XCTAssertNil(decode("17"))
    }

    func testJiraServerTimestampsParse() {
        XCTAssertNotNil(JiraDateFormat.parseTimestamp("2026-09-02T09:12:44.000+0330"))
        XCTAssertNotNil(JiraDateFormat.parseDay("2026-09-04"))
        XCTAssertNil(JiraDateFormat.parseTimestamp("nonsense"))
    }
}

// MARK: - Platform

final class PlatformTests: XCTestCase {

    func testTheFieldWinsOverTheEmoji() {
        XCTAssertEqual(Platform.detect(techArea: "Mobile", summary: "Something 🌐"), .mobile)
    }

    func testTheEmojiIsTheFallbackWhenTheFieldIsEmpty() {
        XCTAssertEqual(Platform.detect(techArea: nil, summary: "Range slider 🌐"), .web)
        XCTAssertEqual(Platform.detect(techArea: "  ", summary: "Bottom sheet 📱"), .mobile)
    }

    func testNeitherSourceMeansNoPlatform() {
        XCTAssertNil(Platform.detect(techArea: nil, summary: "Token audit"))
    }

    func testTheMarkerIsStrippedSoTheRowDoesNotSayItTwice() {
        XCTAssertEqual(Platform.strippingMarker(from: "Range slider magnet snap 🌐"),
                       "Range slider magnet snap")
        XCTAssertEqual(Platform.strippingMarker(from: "Plain summary"), "Plain summary")
    }
}

// MARK: - Backoff

final class PollerTests: XCTestCase {

    func testHealthyPollingUsesTheBaseInterval() {
        XCTAssertEqual(Poller.delay(base: 180, consecutiveFailures: 0), 180)
    }

    func testBackoffGrowsWhileTheHostIsDown() {
        XCTAssertEqual(Poller.delay(base: 180, consecutiveFailures: 1), 360)
        XCTAssertEqual(Poller.delay(base: 180, consecutiveFailures: 2), 720)
    }

    func testBackoffIsCappedSoItAlwaysHealsWithinAReasonableTime() {
        XCTAssertEqual(Poller.delay(base: 180, consecutiveFailures: 9), 720)
        XCTAssertEqual(Poller.delay(base: 300, consecutiveFailures: 40), 1200)
    }

    func testPollIntervalIsClampedAgainstAHandEditedPlist() {
        let defaults = UserDefaults(suiteName: "ticketbar.tests.\(UUID().uuidString)")!
        defaults.set(9999, forKey: Keys.pollMinutes)
        XCTAssertEqual(Keys.pollInterval(defaults), 300)
        defaults.set(0, forKey: Keys.pollMinutes)
        XCTAssertEqual(Keys.pollInterval(defaults), 120)
    }
}

// MARK: - Board scope

final class BoardScopeTests: XCTestCase {

    /// A column can gather several statuses, so it must query all of them, not just the first.
    func testAColumnQueriesEveryStatusItGathers() {
        let column = BoardColumn(name: "Planning", statusIDs: ["10101", "10102"])
        XCTAssertEqual(column.jql(projectKey: "DDS"),
                       "project = DDS AND status in (10101, 10102) ORDER BY updated DESC")
    }

    /// There must be no hardcoded column list. One used to exist, built from an older board's
    /// workflow, and when the Agile API failed it showed nine plausible columns that had nothing
    /// to do with board 95. A guessed list is indistinguishable from real data on screen, which is
    /// the same failure mode as showing an empty list for an expired token.
    func testColumnsCanOnlyBeBuiltFromStatusIDs() {
        let column = BoardColumn(name: "\u{1F7E0} Working on it", statusIDs: ["3"])
        XCTAssertEqual(column.statusClause, "status in (3)")
        XCTAssertEqual(column.jql(projectKey: "DDS"),
                       "project = DDS AND status in (3) ORDER BY updated DESC")
    }

    /// The QC fixture must be board 95 as the server reports it, not an older board's workflow.
    func testTheQCFixtureMatchesTheRealBoard() {
        XCTAssertEqual(QCHooks.qcColumns.map(\.name),
                       ["Backlog", "To Do", "\u{1F7E0} Working on it", "\u{1F7E3} QC Ready",
                        "\u{1F535} Testing", "\u{1F534} Rejected", "\u{1F7E2} Done"])
        for column in QCHooks.qcColumns {
            XCTAssertFalse(column.statusIDs.isEmpty, "\(column.name) has no status to query")
        }
    }

    /// A column with nothing mapped to it can only ever return nothing, which would look exactly
    /// like the empty-list bug this app exists to avoid. It is dropped instead.
    func testColumnsWithNoStatusesAreDropped() throws {
        let json = """
        {"id": 95, "name": "DDS board", "columnConfig": {"columns": [
          {"name": "Backlog", "statuses": [{"id": "1"}]},
          {"name": "Holding pen", "statuses": []},
          {"name": "Done", "statuses": [{"id": "6"}]}]}}
        """.data(using: .utf8)!
        let configuration = try JSONDecoder().decode(BoardConfiguration.self, from: json)
        XCTAssertEqual(configuration.columns.map(\.name), ["Backlog", "Done"])
    }

    /// Two columns must never share a seen-issue set, and the real board names its columns with
    /// emoji, which end up in UserDefaults keys.
    func testSeenNamespacesAreDistinctAndASCII() {
        XCTAssertEqual(BoardColumn(name: "To Do").seenNamespace, "to-do")
        XCTAssertEqual(BoardColumn(name: "\u{1F7E0} Working on it").seenNamespace, "working-on-it")
        XCTAssertEqual(BoardColumn(name: "\u{1F534} Rejected").seenNamespace, "rejected")
        XCTAssertNotEqual(BoardColumn(name: "\u{1F535} Testing").seenNamespace,
                          BoardColumn(name: "\u{1F7E3} QC Ready").seenNamespace)

        for column in QCHooks.qcColumns {
            XCTAssertTrue(column.seenNamespace.allSatisfy { $0.isASCII },
                          "\(column.name) produced a non-ASCII defaults key")
        }
    }

    /// Pinned from the board's own URL, rather than taking whichever board discovery returns first.
    func testTheBoardIsPinnedToTheDDSRapidView() {
        XCTAssertEqual(Keys.defaultBoardID, 95)
        XCTAssertEqual(Keys.defaultProjectKey, "DDS")
    }
}

// MARK: - Comments

final class CommentTests: XCTestCase {

    private func decode(_ raw: String) throws -> [JiraComment] {
        try JSONDecoder().decode(JiraCommentsResponse.self, from: raw.data(using: .utf8)!).comments
    }

    func testTheServerRenderedBodyIsPreferredOverRawMarkup() throws {
        let comments = try decode("""
        {"comments":[{"id":"1","author":{"displayName":"Sara"},
          "body":"h1. raw markup","renderedBody":"<h1>rendered</h1>",
          "created":"2026-09-07T10:00:00.000+0330"}]}
        """)
        XCTAssertEqual(comments[0].html, "<h1>rendered</h1>")
    }

    /// Some Server/DC configurations do not return renderedBody. The raw markup must still show,
    /// with its line breaks, rather than the comment silently rendering as nothing.
    func testRawMarkupIsUsedWhenTheServerRendersNothing() throws {
        let comments = try decode("""
        {"comments":[{"id":"1","author":{"displayName":"Sara"},"body":"line one\\nline two"}]}
        """)
        XCTAssertTrue(comments[0].html.contains("line one<br>line two"))
    }

    /// A comment is other people's text going into an HTML document.
    func testCommentTextAndAuthorNamesAreEscaped() throws {
        let comments = try decode("""
        {"comments":[{"id":"1","author":{"displayName":"<script>x</script>"},
          "body":"5 < 6 & 7 > 2"}]}
        """)
        let html = JiraComment.composedHTML(comments)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 2"))
    }

    func testAMissingAuthorDoesNotBreakTheThread() throws {
        let comments = try decode("""
        {"comments":[{"id":"1","body":"orphan"}]}
        """)
        XCTAssertEqual(comments[0].authorName, "Unknown")
        XCTAssertTrue(JiraComment.composedHTML(comments).contains("Unknown"))
    }

    /// One document for the whole thread, because a busy issue can carry twenty comments and
    /// twenty web views is not a thing to put in a popover.
    func testTheWholeThreadComposesIntoOneDocument() throws {
        let comments = try decode("""
        {"comments":[
          {"id":"1","author":{"displayName":"Sara"},"renderedBody":"<p>first</p>"},
          {"id":"2","author":{"displayName":"Pooya"},"renderedBody":"<p>second</p>"}]}
        """)
        let html = JiraComment.composedHTML(comments)
        XCTAssertEqual(html.components(separatedBy: "class=\"jc\"").count - 1, 2)
        XCTAssertTrue(html.contains("first"))
        XCTAssertTrue(html.contains("second"))
    }

    func testAnEmptyThreadComposesToNothing() {
        XCTAssertTrue(JiraComment.composedHTML([]).isEmpty)
    }

    func testTheQCFixtureCommentsParse() {
        XCTAssertEqual(QCHooks.sampleComments["DDS-412"]?.count, 2)
    }

    /// Both sections default to on; the setting exists to turn them off, not to opt in.
    func testDetailSectionsAreOnByDefault() {
        let defaults = UserDefaults(suiteName: "ticketbar.tests.\(UUID().uuidString)")!
        Keys.registerDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: Keys.showDescription))
        XCTAssertTrue(defaults.bool(forKey: Keys.showComments))
    }
}

// MARK: - Comment authoring

final class CommentAuthoringTests: XCTestCase {

    private func comments() -> [JiraComment] {
        let json = """
        {"comments":[
          {"id":"11","author":{"displayName":"Pooya Kamel"},"renderedBody":"<p>mine</p>",
           "created":"2026-09-07T18:09:00.000+0330","updated":"2026-09-07T18:09:00.000+0330"},
          {"id":"22","author":{"displayName":"Sara Ahmadi"},"renderedBody":"<p>theirs</p>",
           "created":"2026-09-07T19:00:00.000+0330","updated":"2026-09-07T19:00:00.000+0330"}]}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments
    }

    /// The rule the user called very important: Ticketbar can add and edit comments, never delete
    /// one. A delete control in a popover that opens under the cursor is one stray click from
    /// destroying somebody's comment, and Jira does not undo it.
    func testTheRenderedThreadNeverOffersDelete() {
        let html = JiraComment.composedHTML(comments(), editableIDs: ["11", "22"])
        XCTAssertFalse(html.lowercased().contains("delete"))
        XCTAssertFalse(html.contains("\(JiraComment.actionScheme)://delete"))
    }

    func testEditIsOfferedOnlyForTheGivenComments() {
        let html = JiraComment.composedHTML(comments(), editableIDs: ["11"])
        XCTAssertTrue(html.contains("\(JiraComment.actionScheme)://edit/11"))
        XCTAssertFalse(html.contains("\(JiraComment.actionScheme)://edit/22"),
                       "Edit must not appear on a comment the user cannot edit")
    }

    func testNoEditLinksWhenNothingIsEditable() {
        XCTAssertFalse(JiraComment.composedHTML(comments()).contains("://edit/"))
    }

    /// Relative, never an absolute timestamp: "2 hours ago", not "07/Sep/26 9:09 PM".
    func testTimesAreRelativeNotAbsolute() {
        let now = JiraDateFormat.parseTimestamp("2026-09-07T21:09:00.000+0330")!
        let html = JiraComment.composedHTML(comments(), now: now)
        XCTAssertTrue(html.contains("ago"), "expected a relative time")
        XCTAssertFalse(html.contains("07/Sep/26"))
        XCTAssertFalse(html.contains("2026-09-07"))
    }

    /// A comment that was never edited often carries no `updated` field at all. Comparing a nil
    /// `updated` against a real `created` marked every single comment as edited.
    func testACommentWithNoUpdatedFieldIsNotMarkedEdited() {
        let json = """
        {"comments":[{"id":"1","author":{"displayName":"Sara"},"renderedBody":"<p>x</p>",
          "created":"2026-09-07T18:09:00.000+0330"}]}
        """.data(using: .utf8)!
        let plain = try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments
        XCTAssertFalse(JiraComment.composedHTML(plain).contains("edited"))
    }

    /// Jira marks an edited comment by moving `updated` past `created`.
    func testAnEditedCommentSaysSo() {
        let json = """
        {"comments":[{"id":"1","author":{"displayName":"Pooya Kamel"},"renderedBody":"<p>x</p>",
          "created":"2026-09-07T18:09:00.000+0330","updated":"2026-09-07T20:00:00.000+0330"}]}
        """.data(using: .utf8)!
        let edited = try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments
        XCTAssertTrue(JiraComment.composedHTML(edited).contains("edited"))
        XCTAssertFalse(JiraComment.composedHTML(comments()).contains("edited"))
    }

    /// The action scheme is intercepted by the web view, so it must never look like a real link.
    func testTheActionSchemeIsNotAWebScheme() {
        XCTAssertEqual(JiraComment.actionScheme, "ticketbar")
        XCTAssertNotEqual(JiraComment.actionScheme, "https")
    }

    /// Every detail section is on by default; the switches exist to turn things off.
    func testEveryDetailSectionDefaultsOn() {
        let defaults = UserDefaults(suiteName: "ticketbar.tests.\(UUID().uuidString)")!
        Keys.registerDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: Keys.showMetadata))
        XCTAssertTrue(defaults.bool(forKey: Keys.showDescription))
        XCTAssertTrue(defaults.bool(forKey: Keys.showComments))
    }
}

// MARK: - Reactions

final class ReactionTests: XCTestCase {

    private func comments() -> [JiraComment] {
        let json = """
        {"comments":[{"id":"11","author":{"name":"p.kamel","displayName":"Pouya Kamel"},
          "renderedBody":"<p>mine</p>","created":"2026-09-07T18:09:00.000+0330"}]}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments
    }

    private func reactions() -> [JiraReaction] {
        let json = """
        {"reactions":[{"emojiId":"1f44d","count":2,"currentUserReacted":true},
                      {"emojiId":"1f389","count":1,"currentUserReacted":false}]}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(JiraReactionsResponse.self, from: json).reactions!
    }

    func testACodepointRendersAsItsEmoji() {
        XCTAssertEqual(JiraReaction.emoji(for: "1f44d"), "\u{1F44D}")
        XCTAssertEqual(JiraReaction.emojiId(for: "\u{1F44D}"), "1f44d")
    }

    /// An unknown or malformed codepoint must not crash or render as empty.
    func testAnUnusableCodepointFallsBackToAVisibleGlyph() {
        XCTAssertEqual(JiraReaction.emoji(for: nil), "\u{2753}")
        XCTAssertEqual(JiraReaction.emoji(for: "not-hex"), "\u{2753}")
    }

    func testChipsRenderWithTheirCountAndAToggleLink() {
        let html = JiraComment.composedHTML(comments(), reactions: ["11": reactions()])
        XCTAssertTrue(html.contains("\u{1F44D} 2"))
        XCTAssertTrue(html.contains("\u{1F389} 1"))
        XCTAssertTrue(html.contains("\(JiraComment.actionScheme)://react/11/1f44d"))
    }

    /// Your own reaction is marked so it can be styled differently and read as "click to undo".
    func testYourOwnReactionIsMarked() {
        let html = JiraComment.composedHTML(comments(), reactions: ["11": reactions()])
        XCTAssertTrue(html.contains("jr jrm"), "the reaction you added should carry the mine class")
    }

    func testThePickerIsAlwaysOffered() {
        XCTAssertTrue(JiraComment.composedHTML(comments()).contains("\(JiraComment.actionScheme)://picker/11"))
    }

    /// Reactions with nobody behind them are not drawn.
    func testEmptyReactionsAreNotDrawn() {
        let json = """
        {"reactions":[{"emojiId":"1f44d","count":0}]}
        """.data(using: .utf8)!
        let empty = try! JSONDecoder().decode(JiraReactionsResponse.self, from: json).reactions!
        XCTAssertFalse(JiraComment.composedHTML(comments(), reactions: ["11": empty]).contains("\u{1F44D} 0"))
    }

    /// The endpoint is undocumented, so a shape this code does not expect must degrade to no
    /// reactions rather than throwing and taking the whole comment thread with it.
    func testAnUnexpectedShapeDecodesToNothingRatherThanThrowing() {
        let json = """
        {"somethingElse": true}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(JiraReactionsResponse.self, from: json)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.reactions)
    }

    /// Still true with reactions on screen: add, edit and react, never delete a comment.
    func testTheThreadStillNeverOffersCommentDelete() {
        let html = JiraComment.composedHTML(comments(),
                                            editableIDs: ["11"],
                                            reactions: ["11": reactions()])
        XCTAssertFalse(html.lowercased().contains("delete"))
    }

    func testThePaletteIsShortAndAllValid() {
        XCTAssertEqual(JiraReaction.palette.count, 8)
        for emoji in JiraReaction.palette {
            XCTAssertNotNil(JiraReaction.emojiId(for: emoji), "\(emoji) has no codepoint")
        }
    }
}
