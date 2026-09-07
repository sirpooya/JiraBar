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

    func testTheFallbackColumnsQueryByQuotedName() {
        let column = BoardColumn(name: "Blocked / Rejected", statusNames: ["Blocked / Rejected"])
        XCTAssertEqual(column.statusClause, "status in (\"Blocked / Rejected\")")
    }

    /// The fallback list is what the dropdown offers when the Agile API is unavailable, so it has
    /// to match the workflow statuses recorded in CLAUDE.md.
    func testTheFallbackCoversEveryKnownWorkflowStatus() {
        let names = Set(BoardColumn.fallback.map(\.name))
        for expected in ["Sprint Backlog", "Planning Web", "Planning App", "In-Progress",
                         "Storybook", "Testing", "Blocked / Rejected", "UAT", "Done"] {
            XCTAssertTrue(names.contains(expected), "the dropdown would be missing \(expected)")
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

    /// Two columns must never share a seen-issue set.
    func testSeenNamespacesAreDistinctPerColumn() {
        XCTAssertEqual(BoardColumn(name: "In-Progress").seenNamespace, "in-progress")
        XCTAssertEqual(BoardColumn(name: "Sprint Backlog").seenNamespace, "sprint-backlog")
        XCTAssertNotEqual(BoardColumn(name: "UAT").seenNamespace,
                          BoardColumn(name: "Testing").seenNamespace)
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
