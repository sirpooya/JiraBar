import XCTest
@testable import Ticketbar

// MARK: - Seen issues

/// The first-run rule: the backlog that already exists must never arrive as notifications.
final class SeenIssuesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ticketbar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFreshInstallIsNotSeeded() {
        XCTAssertFalse(SeenIssues(namespace: "in-progress", defaults: defaults).isSeeded)
    }

    func testSeedingRecordsTheBacklogWithoutReportingAnyOfItAsNew() {
        let seen = SeenIssues(namespace: "in-progress", defaults: defaults)
        seen.seed(with: ["A-1", "A-2", "A-3"])

        XCTAssertTrue(seen.isSeeded)
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(seen.unseen(among: ["A-1", "A-2", "A-3"]).isEmpty,
                      "the existing backlog must never be reported as new")
    }

    func testOnlyGenuinelyNewKeysComeBack() {
        let seen = SeenIssues(namespace: "in-progress", defaults: defaults)
        seen.seed(with: ["A-1", "A-2"])
        XCTAssertEqual(seen.unseen(among: ["A-2", "A-3", "A-4"]), ["A-3", "A-4"])
    }

    func testUnseenIsReadOnlySoACrashBeforeNotifyingDoesNotSwallowIssues() {
        let seen = SeenIssues(namespace: "in-progress", defaults: defaults)
        seen.seed(with: ["A-1"])
        XCTAssertEqual(seen.unseen(among: ["A-9"]), ["A-9"])
        XCTAssertEqual(seen.unseen(among: ["A-9"]), ["A-9"], "reading must not mark anything seen")
        seen.markSeen(["A-9"])
        XCTAssertTrue(seen.unseen(among: ["A-9"]).isEmpty)
    }

    func testTheSetSurvivesRelaunch() {
        SeenIssues(namespace: "in-progress", defaults: defaults).seed(with: ["A-1", "A-2"])
        let reopened = SeenIssues(namespace: "in-progress", defaults: defaults)
        XCTAssertTrue(reopened.isSeeded)
        XCTAssertTrue(reopened.unseen(among: ["A-1"]).isEmpty)
    }

    func testTheSetIsCappedSoItCannotGrowForever() {
        let seen = SeenIssues(namespace: "in-progress", defaults: defaults)
        seen.seed(with: (0..<1400).map { "A-\($0)" })
        XCTAssertEqual(seen.count, 1000)
        XCTAssertTrue(seen.unseen(among: ["A-1399"]).isEmpty, "the newest keys are the ones kept")
        XCTAssertEqual(seen.unseen(among: ["A-0"]), ["A-0"], "the oldest fall off the front")
    }

    /// Each column keeps its own set. Sharing one would make every column switch a notification
    /// storm, because the new column's issues have never been seen by the old column's set.
    func testEachColumnKeepsItsOwnSet() {
        let inProgress = SeenIssues(namespace: "in-progress", defaults: defaults)
        let testing = SeenIssues(namespace: "testing", defaults: defaults)

        inProgress.seed(with: ["A-1", "A-2"])

        XCTAssertFalse(testing.isSeeded, "seeding one column must not mark another as seeded")
        XCTAssertEqual(testing.unseen(among: ["A-1"]), ["A-1"])
        XCTAssertTrue(inProgress.unseen(among: ["A-1"]).isEmpty)
    }

    func testForgettingEverythingReturnsToTheUnseededState() {
        let seen = SeenIssues(namespace: "in-progress", defaults: defaults)
        seen.seed(with: ["A-1"])
        seen.forgetAll()
        XCTAssertFalse(seen.isSeeded)
        XCTAssertEqual(seen.count, 0)
    }
}

// MARK: - Keychain

/// Against a throwaway service, never the shipping one, with `deleteAll()` in teardown.
final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        store = KeychainStore(service: "in.pooya.ticketbar.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.deleteAll()
        super.tearDown()
    }

    func testRoundTrip() throws {
        try store.set(Data("secret-value".utf8), for: "works.example.com")
        let read = try store.secret(for: "works.example.com")
        XCTAssertEqual(String(data: read, encoding: .utf8), "secret-value")
    }

    func testWritingTwiceReplacesRatherThanDuplicating() throws {
        try store.set(Data("first".utf8), for: "host")
        try store.set(Data("second".utf8), for: "host")
        XCTAssertEqual(try store.accounts(), ["host"])
        XCTAssertEqual(String(data: try store.secret(for: "host"), encoding: .utf8), "second")
    }

    func testReadingSomethingAbsentIsNotFound() {
        XCTAssertThrowsError(try store.secret(for: "nothing-here"))
    }

    func testDeletingSomethingAlreadyGoneIsNotAnError() {
        XCTAssertNoThrow(try store.delete(account: "never-existed"))
    }

    func testAccountsListsWithoutReadingAnySecret() throws {
        try store.set(Data("a".utf8), for: "one")
        try store.set(Data("b".utf8), for: "two")
        XCTAssertEqual(try store.accounts().sorted(), ["one", "two"])
    }
}

/// The token layer on top: one item per host, and nothing ever reaching UserDefaults.
final class TokenStoreTests: XCTestCase {
    private var service = ""
    private var store: TokenStore!

    override func setUp() {
        super.setUp()
        service = "in.pooya.ticketbar.tests.\(UUID().uuidString)"
        store = TokenStore(service: service)
    }

    override func tearDown() {
        try? KeychainStore(service: service).deleteAll()
        super.tearDown()
    }

    func testTokensAreStoredPerHost() throws {
        let live = URL(string: "https://works.digikala.com")!
        let staging = URL(string: "https://staging.example.com")!

        try store.save("live-token", for: live)
        try store.save("staging-token", for: staging)

        XCTAssertEqual(store.token(for: live), "live-token")
        XCTAssertEqual(store.token(for: staging), "staging-token")
    }

    func testHasTokenDoesNotNeedToReadTheSecret() throws {
        let url = URL(string: "https://works.digikala.com")!
        XCTAssertFalse(store.hasToken(for: url))
        try store.save("t", for: url)
        XCTAssertTrue(store.hasToken(for: url))
    }

    func testWhitespaceAroundAPastedTokenIsTrimmed() throws {
        let url = URL(string: "https://works.digikala.com")!
        try store.save("  padded-token\n", for: url)
        XCTAssertEqual(store.token(for: url), "padded-token")
    }

    func testAnEmptyTokenIsRefused() {
        XCTAssertThrowsError(try store.save("   ", for: URL(string: "https://x.example.com")!))
    }

    func testSigningOutRemovesTheItem() throws {
        let url = URL(string: "https://works.digikala.com")!
        try store.save("t", for: url)
        try store.delete(for: url)
        XCTAssertFalse(store.hasToken(for: url))
    }

    /// The rule from CLAUDE.md, asserted rather than trusted.
    func testTheTokenNeverReachesUserDefaults() throws {
        let url = URL(string: "https://works.digikala.com")!
        try store.save("super-secret-pat", for: url)

        let domain = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in domain {
            XCTAssertFalse("\(value)".contains("super-secret-pat"),
                           "the token leaked into UserDefaults under \(key)")
        }
    }
}

// MARK: - Request building

final class JiraClientRequestTests: XCTestCase {

    /// A request dump must be safe to paste into an issue report.
    func testTheAuthorizationHeaderIsRedactedAndNotMerelyShortened() {
        var request = URLRequest(url: URL(string: "https://works.digikala.com/rest/api/2/myself")!)
        request.setValue("Bearer super-secret-pat", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let dump = request.redactedDescription
        XCTAssertFalse(dump.contains("super-secret-pat"))
        XCTAssertFalse(dump.contains("super"), "a prefix of a token is still a leak")
        XCTAssertTrue(dump.contains("<redacted>"))
        XCTAssertTrue(dump.contains("application/json"))
    }

    func testTheBrowseURLPointsAtTheIssuePage() {
        let client = JiraClient(baseURL: URL(string: "https://works.digikala.com")!,
                                tokenProvider: { "t" })
        XCTAssertEqual(client.browseURL(for: "DDS-412").absoluteString,
                       "https://works.digikala.com/browse/DDS-412")
        XCTAssertEqual(client.tokenPageURL.absoluteString,
                       "https://works.digikala.com/secure/ViewProfile.jspa")
    }
}
