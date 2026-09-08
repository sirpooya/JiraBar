# CLAUDE.md: Jirabar (macOS menu-bar client for Jira Server/DC)

## Goal
Shows a column of the DDS Jira board in the menu bar, notifies me when a new issue lands in it,
renders the full description in the popover, and moves an issue to Done without opening a browser.
It replaces keeping a Jira tab open all day.

The scope is chosen from a dropdown at the top centre of the popover, one entry per board column.
There is deliberately no "assigned to me" entry: 2026-09-08, the user asked for it to be removed,
because nothing on this board is assigned to them and the entry was dead weight.

Keep it minimal and dependency-light. No cloud sync, no accounts, no analytics.

## Naming (DECIDED, do not re-litigate)
- 2026-09-09 Display name is **Jirabar**, renamed from Ticketbar at the user's direction. The
  earlier rule here was the opposite: the name was Ticketbar precisely so that "Jira" appeared
  nowhere in the shipped app name, because Atlassian's trademark policy does not permit it. Both
  halves of that rule are now reversed, the name and the icon, and this is recorded rather than
  quietly overwritten so nobody re-derives the old reasoning and "fixes" it back.
- **This is an internal tool and the naming is only safe while it stays internal.** Before any
  distribution outside the company, both the name and the icon have to change. Neither is
  defensible: the name contains the trademark and the icon is Atlassian's own mark.
- 2026-09-09 The menu bar icon is that mark, from the `logo.png` the user supplied, bundled as
  `Jirabar/Resources/MenuBarIcon.png` and cropped to its ink at load. The app icon is
  `Jirabar/Resources/AppIcon.icon`, an Icon Composer bundle, which needs Xcode 26 to compile.
- GitHub repo: `jira-ticketbar`. The local folder is `osx-jira-ticketbar`, matching the house
  `osx-*` convention and the existing Claude session path. Neither was renamed with the app,
  because the folder path is this project's Claude session key; use the `rename-project` skill if
  you ever want them to match.
- Bundle id `in.pooya.ticketbar`, Debug `in.pooya.ticketbar.debug`. `PRODUCT_NAME` is `Jirabar`,
  so the artifact is `Jirabar.app`.

## Status
2026-09-08 (latest): the detail view is one scroll area, rows carry the key and the assignee's
avatar, comment images are inlined, the composer grows to five lines and flips to right to left for
Persian, the editing shortcuts are delivered by a key monitor, the reaction picker opens against
its chip, a swipe right goes back, and two separate crash loops are fixed (see the `sizingOptions`
and defaults observer decisions). 94 tests green.
Two things are built but **unproven against the live instance**: pasting an image with `Cmd+V`, and
emoji reactions, whose endpoint shape 404s and is now attempted four ways. Both have DEBUG logging
on stderr; one click each settles them.
QC note: Accessibility is not granted to the VS Code host on this Mac, so `mac-qc` cannot drive or
photograph the UI. Any claim here about layout or pixels is reasoning, not measurement.

2026-09-08 (late): comments, comment authoring, emoji reactions and the detached window landed.
The detail view is now title, optional metadata, optional description, then the comment thread
newest first with the composer above it. Rows lost their one-click Done. 79 tests green.
Still unproven: (1) emoji reactions, which use Jira's undocumented `/rest/internal/2` endpoint and
have never been confirmed against works.digikala.com, (2) moving a real issue, which needs
permission because it writes to somebody's board, (3) sleep and wake across a real overnight sleep.

2026-09-08: v1 running. Keychain token proven live against works.digikala.com (`/myself` returned
the real display name). Board 95's columns load from the Agile API and the dropdown switches
between them live.

2026-09-02: repo initialized, no Swift code yet.

> **Another committer is active in this repo.** Two commits on 2026-09-08 were authored as
> `Pooya <sirpooya@users.noreply.github.com>` with generic messages ("Refactor code structure for
> improved readability and maintainability"), and they swept up uncommitted working-tree edits
> mid-session. Probably an IDE auto-commit. Commit early if you are mid-change, and do not assume
> the working tree is still yours.

## The Jira instance (ESTABLISHED, do not re-research)
- Host `https://works.digikala.com`. Self-hosted **Server/DC**, so the API is `/rest/api/2`. Not
  `/rest/api/3`, not Cloud. Nothing Cloud-only applies here.
- Auth is **bearer Personal Access Token only**: `Authorization: Bearer <pat>`. Basic auth returns
  401 on this instance, confirmed.
- Server/DC has no OAuth 2.0. OAuth 1.0a via Application Links would need a Jira admin and
  RSA-SHA1 signing for no user benefit. Every user pastes their own PAT. Do not propose
  alternatives.
- Users create a PAT at `https://works.digikala.com/secure/ViewProfile.jspa` under Personal Access
  Tokens. PATs **expire**, admin-configured maximum, often 90 days. So a 401 is a normal, expected
  state with its own UI, not an edge case.
- The host is internal. The app is unreachable off the corporate network or VPN.
- Server/DC cannot push to a laptop, so the app polls.
- Descriptions are **Jira wiki markup**, not ADF and not Markdown. Request `expand=renderedFields`
  and read `renderedFields.description`, which Jira returns as HTML.
- Workflow status names here: `Sprint Backlog`, `Planning Web`, `Planning App`, `In-Progress`,
  `Storybook`, `Testing`, `Blocked / Rejected`, `UAT`, `Done`.
- `customfield_10411` is Tech Area, values `Web` and `Mobile`. Team convention also puts a
  globe or phone emoji suffix in the summary for the same thing, so the emoji is the fallback
  when the field is empty.
- **The board is `rapidView=95`, project `DDS`**, from its own URL:
  `works.digikala.com/secure/RapidBoard.jspa?rapidView=95&projectKey=DDS`. `rapidView` is the id
  the Agile API wants. It is pinned, not discovered: a project can own several boards, and taking
  whichever one discovery returns first is a coin toss.
- A board **column** is not a status. One column can gather several statuses, so the column's
  status ids are read from the board and queried with `status in (...)`.
- The sibling repo `~/Documents/GitHub/dds-dashboard` has `lib/jira.ts`, whose
  `mapJiraStatusToDev` confirms the same nine status names. Note it points at
  `dkjira.digikala.com`; **this app uses `works.digikala.com`**, which is the host the real token
  authenticated against.

## Endpoints, exhaustively
| What | Call |
|---|---|
| Validate a token, get the display name | `GET /rest/api/2/myself` |
| The board's columns | `GET /rest/agile/1.0/board/95/configuration`, read `columnConfig.columns[].statuses[].id` |
| Find the board, if 95 ever changes | `GET /rest/agile/1.0/board?projectKeyOrId=DDS` |
| A column's issues | `GET /rest/api/2/search`, `jql=project = DDS AND status in (<ids>) ORDER BY updated DESC`, `fields=summary,description,status,priority,issuetype,updated,duedate,parent,customfield_10411`, `expand=renderedFields`, `maxResults=50` |
| Available transitions | `GET /rest/api/2/issue/{key}/transitions` |
| Move an issue | `POST /rest/api/2/issue/{key}/transitions` with the matching transition id |
| Read comments | `GET /rest/api/2/issue/{key}/comment`, `expand=renderedBody`, `orderBy=created` |
| Comment | `POST /rest/api/2/issue/{key}/comment` |

**Never** try to set `fields.status` directly. It is not writable. Always read the transition list
first and match by name, never hardcode a transition id: ids differ per workflow scheme.

## Tech stack (Apple frameworks only)
- Swift 5.10. SwiftUI, hosted by AppKit where AppKit is needed (status item, popover, settings
  window).
- Min target: macOS 14.0. Three places must agree: `options.deploymentTarget.macOS`,
  `MACOSX_DEPLOYMENT_TARGET`, `LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)`.
- Storage: UserDefaults for configuration, every key in one `Keys` enum, defaults registered at
  launch. Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`) for the PAT.
  Never plist or UserDefaults for the token.
- Format: XcodeGen `project.yml` is the source of truth; `Jirabar.xcodeproj` is generated and
  gitignored.

> Do NOT add a Swift package unless a task truly needs it. Ask first. There are no approved
> exceptions yet. `URLSession`, `WKWebView`, `Security`, `UserNotifications` and `ServiceManagement`
> cover the whole app.

## Project layout
```
project.yml            XcodeGen spec, the source of truth
CLAUDE.md              this file
PLAN.md                phase order, check the boxes as they land
Jirabar/
  App/                 AppKit. No Jira knowledge here.
    JirabarApp        @main, one MenuBarExtra that presents nothing so SwiftUI has a scene
    AppDelegate         defaults, sleep/wake wiring, lifecycle returns
    StatusItemController  status item, popover, detach, icon updates
    StatusItemIcon      the two rendering modes and the urgency colours
    DetachedWindow      the torn-off floating window (NSWindow, never NSPanel)
    WindowActivation    .accessory to .regular, derived from the window list
  Views/               SwiftUI
    PopoverRootView     header with the column dropdown, the state switch, footer
    IssueListView       inside PopoverRootView
    IssueRowView        two lines: column, platform, due date, then title. Plus the pills.
    IssueDetailView     title header, metadata, description, comment thread
    CommentComposer     the editor, including pasted-image upload
    DescriptionWebView  the one WKWebView wrapper and the one stylesheet
    StateViews          needs-token, token-rejected, unreachable, empty, failed, loading
    SettingsWindow / SettingsView / SettingsComponents
  Core/                no SwiftUI and no AppKit imports
    JiraClient          every network call. Nothing else touches URLSession.
    JiraModels          issues, comments, reactions, transitions, date parsing, HTML escaping
    BoardModels         Agile board, columns, the JQL a column produces
    ContentState        the state machine that makes the failure split structural
    JiraError           the error taxonomy and its two mappers
    IssueStore          the one observable. Everything the views read.
    Poller / SeenIssues / NotificationService / TokenStore / KeychainStore
    Keys                every defaults key, registered at launch
    Platform            Tech Area, field first then emoji fallback
    QCHooks             forced states and fixtures. DEBUG only.
  Resources/           Assets.xcassets
  Info.plist
  Jirabar.entitlements
JirabarTests/        CoreTests, StorageTests. The app is the TEST_HOST.
_samples/              the visual spec
```
Build: `xcodegen generate && xcodebuild -project Jirabar.xcodeproj -scheme Jirabar build`.
Run: **install to `/Applications` and launch from there, never from DerivedData.** `build/` does
not exist; `xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData/Jirabar-<hash>/Build/
Products/Debug/`, and the hash changes if the project is ever renamed, so locate it rather than
hardcoding it:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name "Jirabar.app" \
        -path "*/Build/Products/Debug/*" | head -1)
pkill -x Jirabar; sleep 1
rm -rf /Applications/Jirabar.app && cp -R "$APP" /Applications/Jirabar.app
/Applications/Jirabar.app/Contents/MacOS/Jirabar 2>/tmp/jirabar.err &
```
`/Applications/Jirabar.app` is the copy the user actually clicks, so verifying a DerivedData build
verifies a bundle they are not running. Launch the binary directly rather than with `open` so
stderr can be captured and read back. Quit the running app before replacing the bundle: overwriting
it under a live process invalidates its code signature. Copying to `/Applications` does not
re-prompt for the token, because signing uses a real certificate and the designated requirement
carries no path.

## Decisions (DECIDED, do not re-litigate unless you spot a real problem)
- 2026-09-02 Menu bar: `NSStatusItem` plus `NSPopover`, not `MenuBarExtra`. The popover must sit
  centred under the icon and holds a text field and a picker; `MenuBarExtra` gives no control over
  where its window lands.
- 2026-09-02 Settings is an `NSWindow` this app owns, not a SwiftUI `Settings` scene. Panes come
  from `SettingsComponents.swift`; the control goes in the row's trailing slot, never in a
  control's own label.
- 2026-09-02 The bundle id `in.pooya.ticketbar`, the Keychain service `in.pooya.ticketbar.pat` and
  the defaults prefix `in.pooya.ticketbar.` are storage addresses, not labels. Renaming any of them
  strands the user's token and settings.
- 2026-09-09 **The Ticketbar to Jirabar rename deliberately stopped at those addresses.** The rule
  is mechanical: capitalised `Ticketbar` was a product name and became `Jirabar`; lowercase
  `ticketbar` was an address and did not move. No line in the tree mixed the two, so the split was
  exact. What stayed: the three bundle ids, the 17 defaults keys in `Keys.swift`, the Keychain
  service (which `TokenStore` derives from the bundle id, so it follows automatically), the status
  item's `autosaveName` of `ticketbar.status.v1`, the detached window's frame autosave name, and
  the `ticketbar` URL scheme that notification clicks come back through. Renaming the autosave name
  is its own trap: `NSStatusItem` persists visibility per slot, and a fresh name means a fresh slot
  (see the autosaveName decision). Two harmless leftovers are cosmetic only, the pasted-image
  attachment filename `ticketbar-<timestamp>.png` and a multipart boundary string.
- 2026-09-02 Failure states are three separate states, never one empty list. A 401 or 403 says the
  token expired and offers the token page. An unreachable host says you are probably off the VPN
  and offers a retry. Only a genuinely empty result set shows the empty state. Collapsing any of
  these into "no issues" is the single worst bug this app can have.
- 2026-09-02 The seen-issue set is seeded silently on first run in an explicit step, not as a side
  effect of the first fetch, so the existing backlog never notifies.
- 2026-09-02 Signing is Manual, with `CODE_SIGN_IDENTITY` given as the certificate SHA-1 hash
  and `DEVELOPMENT_TEAM` still set. By name, "Apple Development" is classified as the
  "Mac Development" certificate type and xcodebuild reports it missing, though `codesign` uses it
  fine. Automatic signing wants a profile it cannot mint headlessly, and dropping the team makes
  manual signing refuse. Ad-hoc was rejected: its signature changes every build, so the Keychain
  ACL re-prompts for the token on every launch. The hash is this Mac's; another Mac needs its own.
- 2026-09-02 The status item MUST set `autosaveName` (`ticketbar.status.v1`) and `behavior = []`.
  Symptom without it: the app runs, the popover opens and is anchored correctly, but no icon is on
  the menu bar. Cause: `NSStatusItem` persists visibility per slot, the generic slot had
  `"NSStatusItem VisibleCC Item-0" = 0` in this app's defaults, and Control Center honored it. The
  Control Center log is the diagnostic: `clientRequestsVisibility: false` followed by "Removing
  ephemeral displayable instance". This is NOT the Tahoe block list, so `menubar-fix` does not
  apply: there is no "Moving host to blocked list" line. A SwiftUI `MenuBarExtra` with
  `isInserted` false also registers a slot, so two hosts are tracked and only ours should be
  visible.
- 2026-09-08 The popover lists **one board column**, chosen from a dropdown at the top centre.
  Columns come from the Agile API, never a hardcoded list, so a board the team rearranges needs no
  code change. Three fallbacks in order: pinned board 95, discovery by project key, then the nine
  workflow statuses in this file. A column with no statuses mapped to it is dropped, because it
  could only ever return nothing, which is indistinguishable from the empty-list bug.
- 2026-09-08 The detail view's description and comments are each behind a setting, both on by
  default. Turning one off also skips the request: comments are a separate call made only when a
  detail view opens, never folded into the list search, which would fetch discussion for fifty
  issues nobody has opened.
- 2026-09-08 A whole comment thread is composed into **one** HTML document and shown in one
  `WKWebView`. One web view per comment does not belong in a popover. Author names and any raw
  markup are HTML-escaped: comments are other people's text going into a document.
- 2026-09-08 Comments are fetched `orderBy=-created`, newest first, which is the order the Jira
  web UI shows them in. The composer sits **above** the thread so the box you type into and the
  comment you just posted are next to each other rather than a scroll apart.
- 2026-09-08 There is **one scroll area** in the detail view. Every `WKWebView` is sized to its
  full content (`maxHeight` effectively uncapped) and the detail view's own `ScrollView` is the
  only thing that scrolls. Capping a web view put a second scroller inside the first, and the
  trackpad picked whichever it liked.
- 2026-09-08 Comment bodies are forced to one font size with `!important`. Jira stores the sizes
  the editor left behind as **inline styles**, so nothing weaker overrides them and one comment
  renders at twice the size of the one above it. Only size and line height are normalised: weight,
  style, colour, lists, tables and links stay exactly as the server sent them.
- 2026-09-08 **No transition control on a list row.** A checkmark that moved an issue to Done on
  one click, with no confirmation, in a popover that opens under the cursor, is an accident
  waiting to happen. Moving an issue happens in the detail view, where you have opened the thing
  you are about to change. A row is two lines: column pill, platform tag and due date, then the
  title. No issue key: it is a reference number, not something to read.
- 2026-09-08 The panel can be **detached** into a floating window (`Keys.detached`, persisted). It
  is a plain `NSWindow`, never an `NSPanel`: `WindowActivation` derives the activation policy from
  the titled non-panel windows on screen, so a panel leaves the app `.accessory` and the comment
  field refuses first responder. While detached the status item raises the window instead of
  opening a second copy of the same panel underneath it.
- 2026-09-08 **Jirabar never deletes a Jira comment.** Add, edit and react only. There is no
  `deleteComment` on the client, no delete link in the rendered thread, and a test asserts the
  composed HTML contains no delete affordance. A delete control in a popover that opens under the
  cursor is one stray click from destroying somebody's comment, and Jira does not undo it. Taking
  back your own emoji reaction is not this: it cannot touch anyone else's content.
- 2026-09-08 Comment authors are matched by **username**, never display name. The same person
  reads as "Pouya Kamel" or "Pooya Kamel" depending on who transliterated it, and matching on the
  display name silently removed the Edit link.
- 2026-09-08 Reactions come from `/rest/internal/2/.../reactions`, which is Jira's own
  undocumented UI API. Every field is optional and a failure is silent: the chips do not appear
  and the thread still reads. NOT YET VERIFIED against works.digikala.com.
- 2026-09-08 The detail header is the issue title. The key used to occupy that slot, which put a
  reference number in the most prominent place on screen; it is still on the browser link.
- 2026-09-08 The seen-issue set is **per column**, keyed by the column name. One shared set would
  turn every column switch into a notification storm, because the new column's issues have never
  been seen by the old column's set.
- 2026-09-02 The PAT is never logged, never printed in an error message, and never written to
  UserDefaults, a plist or a crash report. Redact the `Authorization` header in any request dump.

- 2026-09-08 A row shows the issue key, and shows the status pill **only when the selected column
  gathers more than one status** (`BoardColumn.gathersMultipleStatuses`). Every column on board 95
  maps to exactly one status, so the pill was repeating the dropdown above the list. The key was
  briefly removed from the row and put back: it is the string you quote to another person.
- 2026-09-08 The assignee's avatar sits at the trailing edge of a row, vertically centred across
  both lines. It is fetched through `JiraClient.avatar(at:)`, never `AsyncImage`: on this instance
  the avatar is behind the same bearer token as everything else, and an unauthenticated load
  returns a login page. That call **refuses any URL whose host is not the base URL's**, so the
  token cannot follow a redirect off the Jira host. No avatar shows the person's initials, no
  assignee shows a neutral person glyph, so the trailing column stays aligned down the list.
- 2026-09-08 **`NSHostingController.sizingOptions` must stay empty for the detached window.**
  With `.preferredContentSize` the SwiftUI content resized the window, and this content changes
  height as it loads (description, comment thread, growing composer). Each change resized the
  window from inside AppKit's layout pass, the resize made `NSHostingView` invalidate and mark
  constraints dirty again, and AppKit aborts that loop with `NSGenericException`: "more Update
  Constraints in Window passes than there are views in the window". The app crashed on every
  launch it was left detached in. The window owns its size; the panel fills it.
- 2026-09-08 **Nothing may touch AppKit synchronously from `UserDefaults.didChangeNotification`.**
  It fires for every key in the domain, AppKit writes to that domain itself when a window persists
  an autosaved frame, and it is posted from inside whatever wrote. Setting the status button's
  image there marked the status bar window as needing constraints during its own layout pass, with
  the same exception as above. The observer compares the values the icon actually depends on and
  defers the redraw by a run loop turn.
- 2026-09-08 The panel is 380 points wide in the popover, which sizes to its content, and fills
  the window in both directions when detached, with 380 as the floor. Pinned to 380 it sat in a
  window dragged out to 572 with a wide empty margin beside it.
- 2026-09-08 **The standard editing shortcuts are delivered by a local key monitor, not by a
  menu.** `Cmd+V` reached nothing at all: pasting into the composer or the token field did
  nothing, for plain text as much as for an image, and `PastingTextView.paste(_:)`, where a pasted
  screenshot is intercepted, was never called. A text view builds its own contextual menu, so
  right-click Paste worked, which disguised this as an image-only bug.
  Two fixes were tried and neither was enough on its own. AppKit dispatches these shortcuts
  through `NSApp.mainMenu`, and installing an Edit menu in the delegate does not hold, because
  this app's only scene is a `MenuBarExtra` and SwiftUI owns that menu and replaces it. Overriding
  `performKeyEquivalent` on the text view was never reached either. What works is
  `AppDelegate.installEditingShortcuts`: a local `.keyDown` monitor, which sees the key before the
  window dispatches it and so depends on neither the menu nor the responder chain. It acts only
  when the focused responder can perform the action, which is what also fixes the token field.
  The main menu is still installed, and is still never seen.
- 2026-09-08 Right-to-left text is decided by the text, per element, never globally. The composer
  sets its base writing direction from the draft's **first strong character**
  (`TextDirection.firstStrong`), and each comment's byline and body carry `dir="auto"`. Digits and
  punctuation are skipped: a Persian numbered list starts "1- ", and counting that digit as strong
  laid the whole line out backwards. Without this, Persian rendered in the document's
  left-to-right base direction, which reorders the runs and reads as scrambled.
- 2026-09-08 A rendered block (description or comment thread) reports its own height from the page
  through a `ResizeObserver`, and its web view forwards the scroll wheel to its container
  (`NonScrollingWebView`). A single height measured at load came in short, and WKWebView answered
  by scrolling internally: the thread slid under the composer while the detail view's own scroller
  sat untouched. The detail view has exactly one scroll area.
- 2026-09-09 The detach control is `pin` and, while detached, `pin.fill`. It says what detaching
  is for rather than what it makes: the panel stays put instead of closing the moment focus moves.
  It went picture in picture, then `macwindow`, then this. Verify any SF Symbol name against the
  system list before shipping it: a misspelled name renders as nothing and the build still
  succeeds.
- 2026-09-08 **Comment times are not wrong when they disagree with Jira's web UI.** Jira renders
  them in the Jira profile's timezone, this app uses the Mac's clock, and both describe the same
  instant. `08/Sep/26 7:37 AM` in Jira is 11:07 in Tehran, so "2 minutes ago" at 11:09 is correct.
  The offset in `2026-09-02T11:04:33.000+0330` is parsed, not dropped.

- 2026-09-08 A paste carrying both image bytes and text is an **image** paste unless the text is
  real prose (`PasteRouting`). The rule used to be the other way round, and any text at all beat
  the image, so a screenshot copied out of a browser or a design tool pasted its file name
  (`pastedImage_9_8_2026__11_52_41_224.png`) as a line of text and dropped the picture.
- 2026-09-08 Images inside rendered HTML are **fetched with the token and inlined as `data:` URIs**
  (`HTMLImages`, `JiraClient.imageData(at:)`). Jira renders an attachment as
  `<img src="/secure/attachment/...">`, a path on the Jira host behind the same bearer token as
  everything else, and a web view given no base URL and no token showed a broken icon with the
  file name beside it. Inlining also means the web view still makes no requests of its own, so the
  privacy claim below stays exactly true. The same host guard as the avatar applies, and an image
  over 8 MB is left alone rather than putting a document of many megabytes into a web view.
- 2026-09-08 The detached window's minimum is enforced in **`windowWillResize(_:to:)`**, and a
  restored frame is clamped up to it. `contentMinSize` did not hold: with `sizingOptions` empty the
  content imposes no constraints of its own and the drag went straight past the minimum, clipping
  the panel, and restoring an autosaved frame does not consult the minimum at all.
- 2026-09-08 **The reaction endpoint's shape is not known for this instance.** The single guessed
  shape, `PUT /rest/internal/2/issue/{key}/comment/{id}/reaction/{emojiId}`, returns 404 on
  works.digikala.com. `JiraClient.reactionCalls` now tries four shapes in order and stops at the
  first accepted; only a 404 advances to the next, so an expired token or an unreachable host is
  still the real answer. A 404 records nothing, so the misses cannot leave anything on somebody's
  board. The toggle also reads the reactions back and says so when the reaction did not stick,
  because Jira's internal API can answer 200 and record nothing. Still unproven end to end.
  Note `JiraReaction.emojiId(for:)` uses only the first unicode scalar, so "❤️" becomes `2764`
  rather than `2764-fe0f`: if one emoji works and that one does not, this is why.
- 2026-09-08 The reaction picker opens **against the chip that asked for it**. The page's own click
  handler cancels the link and posts the chip's `getBoundingClientRect()` with the comment id over
  a second script channel, and the panel floats over the thread at that point, clamped inside it.
  It used to be appended after the whole thread, which on anything but a short one put it far below
  the fold: clicking the chip looked like it did nothing. The link stays in the HTML as the
  fallback for when that script does not run.
- 2026-09-08 A **two-finger swipe right across the header** goes back to the column list. Read from
  a local `.scrollWheel` monitor, because `DragGesture` is a click and drag and a trackpad swipe
  arrives as a scroll event with precise deltas and a phase that no SwiftUI gesture reports. Two
  guards: only in the top strip of the panel, and only when the movement is decisively sideways, so
  scrolling the thread with a sideways drift never triggers it.
- 2026-09-08 The move control is an **ellipsis**, and each destination in its menu is named after
  the **board column** that gathers the destination status (`ColumnGlyph`). The column name because
  the dropdown says "Testing" where this workflow's transition says "Test", and two names for one
  place is one too many. A glyph is added **only when the name has none**: board 95's columns are
  already named with a coloured circle, "🟠 Working on it", "🟣 QC Ready", "🟢 Done", and prefixing
  another put two emoji on every row. Where one is added it is an emoji rather than a tinted SF
  Symbol, because a macOS menu strips the tint and the colour would not survive.
- 2026-09-08 DEBUG logging writes to `FileHandle.standardError`, never `print`. `print` to a pipe
  is block buffered, and the first attempt at logging the undocumented reaction calls produced an
  empty file because the buffer never flushed.

- 2026-09-08 A **two-finger swipe across the list header steps through the board's columns**, left
  for the next and right for the previous, the same direction sense as the swipe back inside an
  issue (`ColumnPaging`). The ends hold rather than wrapping: a board is a line from backlog to
  done, and going from Done to Sprint Backlog on one more swipe reads as a glitch. Its monitor is
  guarded on no issue being open, so a swipe over an issue still means go back.

- 2026-09-09 **A trackpad swipe is judged on the whole gesture's travel, never event by event**
  (`SwipeTracker`). The `.began` and `.ended` scroll events carry zero deltas, so testing each
  event for "more sideways than vertical" rejects the `.ended` event, `0 > 0` being false, and the
  gesture never completes: both swipes were dead on arrival for exactly this reason. Neither
  monitor consumes its events either, so the list and the comment thread still scroll normally.

## Privacy (local-first)
No telemetry, no analytics, no account. Network calls, exhaustively: `works.digikala.com` (or
whatever base URL the user sets) for the endpoints in the table above. Nothing else. Nothing the
user stores leaves this Mac.

## Reference material and QC
- `_samples/`: popover and settings screenshots once they exist. They are the visual spec. Where
  this doc is ambiguous, the screenshot wins.
- Screenshot-QC every significant component with `mac-qc` before calling it done. Measure, do not
  eyeball. `_qc/` is scratch and is deleted with `scripts/clean.sh` at the end of every pass.
- QC hooks, DEBUG only, in `QCHooks.swift`. They force a state on screen without touching the
  server, which is the only way to photograph the failure states on demand:

  ```
  Jirabar.app/Contents/MacOS/Jirabar --qc-state=<value>
  ```

  | Value | Shows |
  |---|---|
  | `sample` | four fixture issues, the real board 95 column names in the dropdown |
  | `detail` | the same, opened straight into the detail view with fixture comments, reactions and transitions |
  | `empty` | the genuinely-no-issues state |
  | `loading` | the first-load spinner |
  | `needs-token` | onboarding |
  | `token-rejected` | the 401 state |
  | `unreachable` | the off-VPN state |
  | `failed` | a generic server failure |

  **A forced state draws a yellow SAMPLE DATA banner.** It has to: the fixtures render identically
  to a live board, and a build left running with the flag was mistaken for the real thing.
- `mac-qc` cannot click the status item unless the terminal host has Accessibility. Without it,
  use `--qc-state` plus `macqc windows --all` and shoot the layer-25 window directly.

## Playground convention
Dev-only tuning windows: an `@Observable` params object the shipping views read, a `Codable`
snapshot decoded key by key with defaults, a mock stage, a controls sidebar. DEBUG only, opened
with `--playground`, as an app-owned `NSWindow`. Never build mock objects inside `body`. Use the
`swift-playground` skill.

## Changelog
After any user-visible or behavioral change:

```bash
python3 ~/Documents/GitHub/claude-skills/skills/release/changelog.py add <type> "<entry>"
```

Types: added, changed, deprecated, removed, fixed, security. Write for someone reading release
notes. Skip pure refactors, formatting and doc-only edits. Releases are cut with the `release`
skill.

## Working style
- Read this file and `PLAN.md` first. Follow the phase order.
- Never transition, comment on, or otherwise write to a real Jira issue during development without
  explicit permission. Reads are free; writes touch other people's boards.
- Put testable logic in `Jirabar/Core/`, free of SwiftUI and AppKit imports.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.
- No em dashes: prose, UI strings, code comments, commit messages.

## Definition of done (v1)
- [x] A PAT pasted once survives quit, relaunch and reboot, and lives only in the Keychain
- [x] Badge count matches the Jira search result count
- [x] The dropdown lists board 95's real columns and switching one reloads the list
- [x] An expired token shows the token-expired state and never an empty list (screenshot)
- [x] Off VPN shows the unreachable state and never an empty list (screenshot)
- [x] Icon is legible in template and color mode, on light and dark menu bars
- [x] Comments render newest first, at one size, with add, edit and reactions
- [x] The panel detaches into a floating window and stays put
- [ ] An issue newly arriving in the selected column produces exactly one notification, and
      clicking it opens that issue
- [ ] An issue can be moved from the popover, confirmed in the browser (needs permission: this
      writes to a real board)
- [ ] Emoji reactions actually work against works.digikala.com. The endpoint is undocumented and
      has never been confirmed; a failure is silent by design, so the chips simply would not appear.
- [ ] The description renders readably in light and dark, tables and code blocks included
- [ ] Polling pauses across sleep and does not burst on wake
