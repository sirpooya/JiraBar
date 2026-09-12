import XCTest
@testable import Jirabar

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

    /// Jira renders an attached screenshot as a path on its own host, which a web view cannot
    /// load: no token, and no base URL to resolve it against.
    func testAttachmentImageSourcesAreFoundAndRewritten() {
        let html = """
        <p>see this</p><img src="/secure/attachment/12345/pastedImage.png" height="200">
        <img src=\'/secure/attachment/9/b.jpg\'><img src="data:image/png;base64,AAA">
        """
        XCTAssertEqual(HTMLImages.sources(in: html),
                       ["/secure/attachment/12345/pastedImage.png", "/secure/attachment/9/b.jpg"],
                       "an image already inlined is not fetched again")

        let rewritten = HTMLImages.rewriting(html) { source in
            source.hasSuffix(".png") ? "data:image/png;base64,ZZZ" : nil
        }
        XCTAssertTrue(rewritten.contains("src=\"data:image/png;base64,ZZZ\""))
        XCTAssertTrue(rewritten.contains("/secure/attachment/9/b.jpg"),
                      "a source with nothing to put in its place is left alone")
        XCTAssertTrue(rewritten.contains("height=\"200\""), "the tag's other attributes survive")
    }

    func testImageMimeTypeComesFromTheExtension() {
        XCTAssertEqual(HTMLImages.mimeType(forPath: "/a/b/shot.png"), "image/png")
        XCTAssertEqual(HTMLImages.mimeType(forPath: "/a/b/photo.JPEG"), "image/jpeg")
        XCTAssertEqual(HTMLImages.mimeType(forPath: "/a/b/thing"), "image/png")
    }

    /// The whole paste chain except AppKit's own dispatch: a Cmd+V key equivalent reaching the
    /// text view, the pasteboard being read, and the image coming back out as PNG bytes.
    ///
    /// This is the bug that survived two attempted fixes. `paste(_:)` was never being called,
    /// because an accessory app whose only scene is a MenuBarExtra does not keep an Edit menu for
    /// AppKit to dispatch the shortcut through.
    @MainActor
    func testCommandVReachesTheTextViewAndYieldsTheImage() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("ticketbar.tests.paste"))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        board.setData(try XCTUnwrap(image.pngData()), forType: .png)

        var pasted: Data?
        let view = PastingTextView()
        view.pasteboardProvider = { board }
        view.onPasteImage = { pasted = $0 }

        // A window, because the view only claims the shortcut when it is the first responder.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        XCTAssertTrue(window.makeFirstResponder(view))

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                   location: .zero,
                                                   modifierFlags: .command,
                                                   timestamp: 0,
                                                   windowNumber: window.windowNumber,
                                                   context: nil,
                                                   characters: "v",
                                                   charactersIgnoringModifiers: "v",
                                                   isARepeat: false,
                                                   keyCode: 9))
        XCTAssertTrue(view.performKeyEquivalent(with: event), "Cmd+V must be claimed by the view")
        XCTAssertNotNil(pasted, "the image on the pasteboard must come back as PNG bytes")
    }

    /// The chip carries its comment id as an attribute as well as in the link, because the page
    /// posts the id with the chip's position so the picker can open beside it.
    func testTheReactionChipCarriesItsCommentIdForThePageScript() {
        let json = """
        {"comments":[{"id":"11","author":{"name":"pooya","displayName":"Pouya Kamel"},
         "renderedBody":"<p>hi</p>","created":"2026-09-08T11:04:33.000+0330"}]}
        """.data(using: .utf8)!
        let thread = try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments
        let html = JiraComment.composedHTML(thread)

        XCTAssertTrue(html.contains("data-comment=\"11\""))
        XCTAssertTrue(html.contains("\(JiraComment.actionScheme)://picker/11"),
                      "the link stays as the fallback for when the script does not run")
    }




    /// The menu names the board column, which is what the dropdown at the top of the panel says.
    func testADestinationIsNamedAfterTheColumnThatGathersIt() {
        let columns = [BoardColumn(name: "Testing", statusIDs: ["10005", "10006"]),
                       BoardColumn(name: "Done", statusIDs: ["10007"])]
        XCTAssertEqual(BoardColumn.name(forStatusID: "10006", in: columns), "Testing")
        XCTAssertNil(BoardColumn.name(forStatusID: "99999", in: columns))
        XCTAssertNil(BoardColumn.name(forStatusID: nil, in: columns))
    }

    /// Swiping across the header steps through the board's columns.
    func testSwipingStepsThroughTheColumnsAndTheEndsHold() {
        let columns = [BoardColumn(name: "Sprint Backlog", statusIDs: ["1"]),
                       BoardColumn(name: "Testing", statusIDs: ["2"]),
                       BoardColumn(name: "Done", statusIDs: ["3"])]

        XCTAssertEqual(ColumnPaging.column(after: columns[0], in: columns, forward: true)?.name,
                       "Testing")
        XCTAssertEqual(ColumnPaging.column(after: columns[1], in: columns, forward: false)?.name,
                       "Sprint Backlog")
        XCTAssertNil(ColumnPaging.column(after: columns[2], in: columns, forward: true),
                     "the last column holds rather than wrapping round to the first")
        XCTAssertNil(ColumnPaging.column(after: columns[0], in: columns, forward: false))
    }

    func testPagingSurvivesNoColumnBeingChosenYet() {
        let columns = [BoardColumn(name: "Testing", statusIDs: ["2"])]
        XCTAssertEqual(ColumnPaging.column(after: nil, in: columns, forward: true)?.name, "Testing")
        XCTAssertNil(ColumnPaging.column(after: nil, in: [], forward: true))
    }


    /// A trackpad swipe's first and last events carry no deltas at all, which is why judging each
    /// event on its own never completed the gesture.
    func testASwipeIsJudgedOnItsWholeTravelNotOnEachEvent() {
        var tracker = SwipeTracker()
        tracker.began()
        tracker.moved(deltaX: 30, deltaY: 2)
        tracker.moved(deltaX: 30, deltaY: -1)
        XCTAssertEqual(tracker.ended(threshold: 40), .right)

        tracker.began()
        tracker.moved(deltaX: -60, deltaY: 3)
        XCTAssertEqual(tracker.ended(threshold: 40), .left)
    }

    func testAMostlyVerticalOrTooSmallSwipeIsNotOne() {
        var tracker = SwipeTracker()
        tracker.began()
        tracker.moved(deltaX: 50, deltaY: 200)
        XCTAssertNil(tracker.ended(threshold: 40), "scrolling with a sideways drift is not a swipe")

        tracker.began()
        tracker.moved(deltaX: 12, deltaY: 0)
        XCTAssertNil(tracker.ended(threshold: 40))
    }

    /// A gesture that did nothing must not leak its travel into the next one.
    func testTheTrackerResetsEvenWhenTheSwipeDidNotCount() {
        var tracker = SwipeTracker()
        tracker.began()
        tracker.moved(deltaX: 30, deltaY: 0)
        XCTAssertNil(tracker.ended(threshold: 40))

        tracker.began()
        tracker.moved(deltaX: 30, deltaY: 0)
        XCTAssertNil(tracker.ended(threshold: 40), "the first swipe's travel must not carry over")
    }

    /// Jira sends every one of these shapes for the fields down the side of an issue.
    func testEveryFieldShapeJiraSendsBecomesOneReadableLine() throws {
        func value(_ raw: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: raw.data(using: .utf8)!)
        }
        XCTAssertEqual(try value("4").displayText, "4", "story points are 4, not 4.0")
        XCTAssertEqual(try value("2.5").displayText, "2.5")
        XCTAssertEqual(try value("\"Core\"").displayText, "Core")
        XCTAssertEqual(try value("[\"Core\",\"PDP\"]").displayText, "Core, PDP")
        XCTAssertEqual(try value("{\"name\":\"PDP\"}").displayText, "PDP")
        XCTAssertEqual(try value("{\"value\":\"Mobile\"}").displayText, "Mobile")
        XCTAssertEqual(try value("[{\"name\":\"PDP\"},{\"name\":\"Cart\"}]").displayText, "PDP, Cart")
        XCTAssertNil(try value("null").displayText)
        XCTAssertNil(try value("[]").displayText, "an empty list is a row that says nothing")
        XCTAssertNil(try value("\"   \"").displayText)
    }

    /// The custom field ids differ per instance, so the rows are matched on the display names the
    /// server itself reports.
    func testFieldRowsAreMatchedByNameNotByCustomFieldID() throws {
        let json = """
        {"names":{"customfield_10004":"Story Points","components":"Component/s",
                  "labels":"Labels","versions":"Affects Version/s","summary":"Summary"},
         "fields":{"customfield_10004":4,"components":[{"name":"PDP"}],"labels":["Core"],
                   "versions":[],"summary":"Table"}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(IssueFieldsResponse.self, from: json)
        let rows = IssueFieldRows.rows(fields: response.fields ?? [:], names: response.names ?? [:])

        XCTAssertEqual(rows, [IssueFieldRow(label: "Component/s", value: "PDP"),
                              IssueFieldRow(label: "Labels", value: "Core"),
                              IssueFieldRow(label: "Story Points", value: "4")],
                       "empty Affects Version/s is dropped, and Summary is not a side panel field")
    }

    /// The icon is chosen from the URL the server gives, not from the display name, which is
    /// renamed and translated per instance.
    func testTheIconIsPickedFromTheURLJiraReports() {
        XCTAssertEqual(JiraIconAsset.name(forIconURL: "https://works.digikala.com/images/icons/priorities/medium.svg",
                                          kind: .priority),
                       "priority-medium")
        XCTAssertEqual(JiraIconAsset.name(forIconURL: "/images/icons/issuetypes/story.svg",
                                          kind: .issueType),
                       "issuetype-story")
        XCTAssertEqual(JiraIconAsset.name(forIconURL: "/images/icons/priorities/High.SVG?v=2",
                                          kind: .priority),
                       "priority-high",
                       "the case and a cache busting query must not change which file it is")
    }

    /// An instance serving PNG avatars for its issue types has no bundled match, and the chip
    /// falls back to plain text rather than showing nothing.
    func testAnIconWeDoNotHaveYieldsNothingToDraw() {
        XCTAssertNil(JiraIconAsset.name(forIconURL: nil, kind: .priority))
        XCTAssertNil(JiraIconAsset.name(forIconURL: "", kind: .issueType))
        XCTAssertEqual(JiraIconAsset.name(forIconURL: "/secure/viewavatar?avatarId=10318",
                                          kind: .issueType),
                       "issuetype-viewavatar",
                       "a name we have no asset for is still returned; the view checks the bundle")
    }

    /// The panel follows the swipe, but only so far, and never past the limit.
    func testTheDragFollowsTheFingersAndNeverRunsAway() {
        XCTAssertEqual(SwipeTracker.rubberBand(0, limit: 46), 0)
        XCTAssertEqual(SwipeTracker.rubberBand(1000, limit: 46), 46, accuracy: 0.5,
                       "a long swipe eases into the limit rather than opening a gap")
        XCTAssertEqual(SwipeTracker.rubberBand(-1000, limit: 46), -46, accuracy: 0.5)

        let small = SwipeTracker.rubberBand(10, limit: 46)
        XCTAssertGreaterThan(small, 8, "a small movement is followed nearly one for one")
        XCTAssertLessThan(small, 10)

        XCTAssertLessThan(SwipeTracker.rubberBand(100, limit: 16),
                          SwipeTracker.rubberBand(100, limit: 46),
                          "an end of the board gives way less, which is how it says no")
    }

    /// The panel must not slide sideways while the list is being scrolled up and down.
    func testASidewaysGestureIsToldApartFromAScroll() {
        var tracker = SwipeTracker()
        tracker.began()
        tracker.moved(deltaX: 4, deltaY: 60)
        XCTAssertFalse(tracker.isSideways)

        tracker.began()
        tracker.moved(deltaX: 40, deltaY: 6)
        XCTAssertTrue(tracker.isSideways)
        XCTAssertEqual(tracker.sidewaysTravel, 40)
    }

    /// Every move menu offers board columns and nothing else, named as the board names them.
    func testOnlyMovesThatLandInAColumnAreOffered() {
        let columns = [BoardColumn(name: "🟢 Done", statusIDs: ["10007"])]
        let json = """
        {"transitions":[{"id":"31","name":"Finish","to":{"id":"10007","name":"Closed"}},
                        {"id":"32","name":"Blocked","to":{"id":"10099","name":"Blocked"}}]}
        """.data(using: .utf8)!
        let transitions = try! JSONDecoder().decode(JiraTransitionsResponse.self, from: json).transitions
        let offered = MoveOption.options(from: transitions, columns: columns)

        XCTAssertEqual(offered.map(\.columnName), ["🟢 Done"],
                       "Blocked is a status this board has no column for, so it is not offered")
        XCTAssertEqual(offered.first?.transition.id, "31",
                       "the workflow's own id still drives the move")
    }

    /// Jira lists a transition back to the current status, and offering it put "Testing" in a
    /// Testing issue's own move menu, which is not a move at all.
    func testTheColumnTheIssueIsAlreadyInIsNotOffered() {
        let columns = [BoardColumn(name: "🔵 Testing", statusIDs: ["10005", "10006"]),
                       BoardColumn(name: "🟢 Done", statusIDs: ["10007"])]
        let json = """
        {"transitions":[{"id":"51","name":"Test","to":{"id":"10005","name":"Testing"}},
                        {"id":"52","name":"Retest","to":{"id":"10006","name":"In Test"}},
                        {"id":"53","name":"Finish","to":{"id":"10007","name":"Done"}}]}
        """.data(using: .utf8)!
        let transitions = try! JSONDecoder().decode(JiraTransitionsResponse.self, from: json).transitions
        let here = JiraIssue.NamedRef(id: "10005", name: "Testing", statusCategory: nil, iconUrl: nil)
        let offered = MoveOption.options(from: transitions, columns: columns, currentStatus: here)

        XCTAssertEqual(offered.map(\.columnName), ["🟢 Done"],
                       "both statuses the Testing column gathers are where the issue already is")
    }

    /// `to.id` is optional in Jira's answer, and matching on it alone dropped those transitions
    /// entirely, which looked like the workflow refusing the move.
    func testAMoveIsMatchedByStatusNameWhenNoIdCameWithIt() {
        let columns = [BoardColumn(name: "🟢 Done", statusIDs: ["10007"]),
                       BoardColumn(name: "🔴 Rejected", statusIDs: ["10009"])]
        let json = """
        {"transitions":[{"id":"41","name":"Finish","to":{"name":"Done"}},
                        {"id":"42","name":"Reject","to":{"name":"rejected"}},
                        {"id":"43","name":"Park","to":{"name":"Blocked"}}]}
        """.data(using: .utf8)!
        let transitions = try! JSONDecoder().decode(JiraTransitionsResponse.self, from: json).transitions
        let offered = MoveOption.options(from: transitions, columns: columns)

        XCTAssertEqual(offered.map(\.columnName), ["🟢 Done", "🔴 Rejected"],
                       "matched on name, and the board's own name with its circle is what shows")
        XCTAssertEqual(offered.count, 2, "Blocked still has no column, so it is still not offered")
    }

    /// The badges show values with no label beside them, so a bare number needs its unit.
    func testStoryPointsCarryTheirUnitAndNothingElseDoes() {
        let points = IssueFieldRow(label: "Story Points", value: "0.5")
        XCTAssertEqual(points.badgeText(for: "0.5"), "0.5 SP")

        let labels = IssueFieldRow(label: "Labels", value: "Core")
        XCTAssertEqual(labels.badgeText(for: "Core"), "Core")
    }

    /// works.digikala.com does not serve the reactions API: the read 404s, so the picker would
    /// error every single time it was used.
    func testThePickerIsAbsentOnAnInstanceWithNoReactionsAPI() {
        let json = """
        {"comments":[{"id":"11","author":{"name":"pooya","displayName":"Pouya Kamel"},
         "renderedBody":"<p>hi</p>","created":"2026-09-08T11:04:33.000+0330"}]}
        """.data(using: .utf8)!
        let thread = try! JSONDecoder().decode(JiraCommentsResponse.self, from: json).comments

        let without = JiraComment.composedHTML(thread, offersReactions: false)
        XCTAssertFalse(without.contains("\(JiraComment.actionScheme)://picker/"))
        XCTAssertTrue(without.contains("<p>hi</p>"), "the thread still reads")

        let with = JiraComment.composedHTML(thread, offersReactions: true)
        XCTAssertTrue(with.contains("\(JiraComment.actionScheme)://picker/11"))
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

    /// The rule the user called very important: Jirabar can add and edit comments, never delete
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

// MARK: - Editing shortcuts survive a keyboard layout change

/// The bug these protect: both paste paths matched `charactersIgnoringModifiers` against "v", and
/// that string is whatever the ACTIVE INPUT SOURCE prints on the key. With Persian selected, Cmd+V
/// reported a Persian letter and paste silently did nothing. It was reported as "pasting an image
/// only works when the comment box is empty", because the box had text precisely when the layout
/// had been switched to write it.
final class EditingShortcutTests: XCTestCase {

    // kVK_ANSI_*, positional and identical on every layout.
    private let a: UInt16 = 0x00
    private let z: UInt16 = 0x06
    private let x: UInt16 = 0x07
    private let c: UInt16 = 0x08
    private let v: UInt16 = 0x09

    func testMatchesByPositionSoTheLayoutCannotChangeTheAnswer() {
        XCTAssertEqual(EditingShortcut.match(keyCode: v, command: true, shift: false), .paste)
        XCTAssertEqual(EditingShortcut.match(keyCode: c, command: true, shift: false), .copy)
        XCTAssertEqual(EditingShortcut.match(keyCode: x, command: true, shift: false), .cut)
        XCTAssertEqual(EditingShortcut.match(keyCode: a, command: true, shift: false), .selectAll)
    }

    func testShiftOnlyDistinguishesRedoFromUndo() {
        XCTAssertEqual(EditingShortcut.match(keyCode: z, command: true, shift: false), .undo)
        XCTAssertEqual(EditingShortcut.match(keyCode: z, command: true, shift: true), .redo)
        // Shift must not turn any of the others into something else.
        XCTAssertNil(EditingShortcut.match(keyCode: v, command: true, shift: true))
    }

    func testCommandIsRequired() {
        for shortcut in EditingShortcut.allCases {
            _ = shortcut
        }
        XCTAssertNil(EditingShortcut.match(keyCode: v, command: false, shift: false),
                     "A bare V must stay a typed letter, not a paste.")
        XCTAssertNil(EditingShortcut.match(keyCode: a, command: false, shift: false))
    }

    func testUnrelatedKeysAreLeftAlone() {
        // 0x0B is B: no editing shortcut, so the event must pass through untouched.
        XCTAssertNil(EditingShortcut.match(keyCode: 0x0B, command: true, shift: false))
    }

    func testEverySelectorIsAnAppKitEditingAction() {
        XCTAssertEqual(EditingShortcut.paste.selectorName, "paste:")
        XCTAssertEqual(EditingShortcut.copy.selectorName, "copy:")
        XCTAssertEqual(EditingShortcut.cut.selectorName, "cut:")
        XCTAssertEqual(EditingShortcut.selectAll.selectorName, "selectAll:")
        XCTAssertEqual(EditingShortcut.undo.selectorName, "undo:")
        XCTAssertEqual(EditingShortcut.redo.selectorName, "redo:")
    }
}

// MARK: - Cmd+Return sends the comment

final class ComposerShortcutTests: XCTestCase {

    private let returnKey: UInt16 = 0x24
    private let keypadEnter: UInt16 = 0x4C

    func testCommandReturnSends() {
        XCTAssertTrue(ComposerShortcut.isSend(keyCode: returnKey, command: true))
        XCTAssertTrue(ComposerShortcut.isSend(keyCode: keypadEnter, command: true),
                      "The keypad's Enter is the same intent as Return.")
    }

    /// The one that matters. A comment here is regularly several lines, and the composer grows to
    /// five of them on purpose, so a bare Return has to stay a newline.
    func testBareReturnDoesNotSend() {
        XCTAssertFalse(ComposerShortcut.isSend(keyCode: returnKey, command: false))
        XCTAssertFalse(ComposerShortcut.isSend(keyCode: keypadEnter, command: false))
    }

    func testOtherKeysDoNotSend() {
        // 0x09 is V: Cmd+V is a paste, and must never be mistaken for a send.
        XCTAssertFalse(ComposerShortcut.isSend(keyCode: 0x09, command: true))
        XCTAssertFalse(ComposerShortcut.isSend(keyCode: 0x00, command: true))
    }

    /// Return carries no editing selector, or the key monitor would swallow it before the composer
    /// ever saw it.
    func testReturnIsNotAnEditingShortcut() {
        XCTAssertNil(EditingShortcut.match(keyCode: returnKey, command: true, shift: false))
        XCTAssertNil(EditingShortcut.match(keyCode: keypadEnter, command: true, shift: false))
    }
}
