# CLAUDE.md: Ticketbar (macOS menu-bar client for Jira Server/DC)

## Goal
Shows the Jira issues assigned to me in the menu bar, notifies me when a new one lands, renders
the full description in the popover, and moves an issue to Done without opening a browser. It
replaces keeping a Jira tab open all day.

Keep it minimal and dependency-light. No cloud sync, no accounts, no analytics.

## Naming (DECIDED, do not re-litigate)
- Display name is **Ticketbar**. The word "Jira" never appears in the shipped app name, the icon,
  or the About window. Atlassian's trademark policy covers the shipped app name. The repo name,
  this file, the README, and a description like "a menu bar client for Jira Server/DC" are fine.
- GitHub repo: `jira-ticketbar`. The local folder is `osx-jira-ticketbar`, matching the house
  `osx-*` convention and the existing Claude session path. Those are allowed to differ.
- Bundle id `in.pooya.ticketbar`, Debug `in.pooya.ticketbar.debug`. `PRODUCT_NAME` is `Ticketbar`,
  so the artifact is `Ticketbar.app`.

## Status
2026-09-02: repo initialized. `project.yml`, `.gitignore`, `CLAUDE.md`, `PLAN.md` written.
No Swift code yet. Next: M1, Keychain plus `/rest/api/2/myself` proven with a real token.

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

## Endpoints, exhaustively
| What | Call |
|---|---|
| Validate a token, get the display name | `GET /rest/api/2/myself` |
| My open issues | `GET /rest/api/2/search`, `jql=assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC`, `fields=summary,description,status,priority,issuetype,updated,duedate,parent,customfield_10411`, `expand=renderedFields`, `maxResults=50` |
| Available transitions | `GET /rest/api/2/issue/{key}/transitions` |
| Move an issue | `POST /rest/api/2/issue/{key}/transitions` with the matching transition id |
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
- Format: XcodeGen `project.yml` is the source of truth; `Ticketbar.xcodeproj` is generated and
  gitignored.

> Do NOT add a Swift package unless a task truly needs it. Ask first. There are no approved
> exceptions yet. `URLSession`, `WKWebView`, `Security`, `UserNotifications` and `ServiceManagement`
> cover the whole app.

## Project layout
```
project.yml            XcodeGen spec, the source of truth
CLAUDE.md              this file
PLAN.md                phase order, check the boxes as they land
Ticketbar/
  App/                 AppDelegate, status item controller, icon drawing
  Views/               popover, list, row, detail, error states, settings panes
  Core/                no SwiftUI here: JiraClient, models, Keychain, poller, seen-set
  Resources/           Assets.xcassets
  Info.plist
  Ticketbar.entitlements
TicketbarTests/        unit tests, app is the TEST_HOST
```
Build: `xcodegen generate && xcodebuild -project Ticketbar.xcodeproj -scheme Ticketbar build`.
Run: `open build/Ticketbar.app`. Quit the running app before repackaging: replacing the bundle
under a running process invalidates its code signature.

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
- 2026-09-02 The PAT is never logged, never printed in an error message, and never written to
  UserDefaults, a plist or a crash report. Redact the `Authorization` header in any request dump.

## Privacy (local-first)
No telemetry, no analytics, no account. Network calls, exhaustively: `works.digikala.com` (or
whatever base URL the user sets) for the endpoints in the table above. Nothing else. Nothing the
user stores leaves this Mac.

## Reference material and QC
- `_samples/`: popover and settings screenshots once they exist. They are the visual spec. Where
  this doc is ambiguous, the screenshot wins.
- Screenshot-QC every significant component with `mac-qc` before calling it done. Measure, do not
  eyeball. `_qc/` is scratch and is deleted with `scripts/clean.sh` at the end of every pass.
- QC hooks: launch flags that force a state on screen without touching the server, so the three
  failure states and the empty state can all be screenshotted. Add them as they are needed and
  list them here.

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
- Put testable logic in `Ticketbar/Core/`, free of SwiftUI and AppKit imports.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.
- No em dashes: prose, UI strings, code comments, commit messages.

## Definition of done (v1)
- [ ] A PAT pasted once survives quit, relaunch and reboot, and lives only in the Keychain
- [ ] Badge count matches the Jira search result count
- [ ] A newly assigned issue produces exactly one notification, and clicking it opens that issue
- [ ] An expired token shows the token-expired state and never an empty list
- [ ] Off VPN shows the unreachable state and never an empty list
- [ ] An issue can be moved to Done from the popover, confirmed in the browser
- [ ] The description renders readably in light and dark, tables and code blocks included
- [ ] Icon is legible in template and color mode, on light and dark menu bars
- [ ] Polling pauses across sleep and does not burst on wake
