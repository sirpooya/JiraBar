# PLAN.md: Ticketbar

The phase order. Nothing in a later milestone starts before the milestone above it is observable
on screen or on the server. Check the boxes as they land; the "Proof" column is what counts as
done, not "the code compiles".

Model and thinking column is advice for whoever runs the session: Opus wherever state,
concurrency or a secret is involved, Sonnet wherever the answer is a template or a screenshot.

---

## M0. Scaffold

Model: Sonnet 5, no extended thinking. Template filling and one `xcodegen` run.

- [x] `project.yml`, `.gitignore`, `CLAUDE.md`, `PLAN.md`
- [x] `git init`, first commit
- [x] Source tree: `Ticketbar/{App,Views,Core,Resources}`, `TicketbarTests/`
- [x] `xcodegen generate` then `xcodebuild -scheme Ticketbar build` succeeds
- [x] App launches as `LSUIElement` with a placeholder status item and no Dock tile

Proof: `open build/Ticketbar.app`, an icon in the menu bar, nothing in the Dock.

---

## M1. Keychain token storage plus `/myself`

Model: Opus 5, `think`. Keychain ACLs, signing-identity stability, and keeping the PAT out of
logs, defaults and crash reports. Cheap to get wrong, expensive to notice.

- [x] `KeychainStore` (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`), service
      `in.pooya.ticketbar.pat`
- [x] `TokenStore`: read, write, delete, plus a `hasToken` that never returns the token itself
- [x] `JiraClient.myself()` against `GET /rest/api/2/myself`, `Authorization: Bearer <pat>`
- [ ] Settings window (app-owned `NSWindow`, built from `SettingsComponents.swift`): base URL
      prefilled with `https://works.digikala.com`, "Create a token" button opening
      `/secure/ViewProfile.jspa`, a paste field, a Test button
- [x] Test button shows the resolved display name, or the specific failure
- [x] Unit tests against a throwaway Keychain service with `deleteAll()` in teardown

Proof: paste a real PAT, press Test, see your own display name. Quit, relaunch, Test again with
no re-paste. `defaults read in.pooya.ticketbar` contains no token.

---

## M2. Status item, popover shell, icon

Model: Sonnet 5 for the wiring, Opus 5 with `think` for the icon. Status-item plumbing is
boilerplate. The dual-mode icon is what `menubar-icon-theming` exists for.

- [x] `NSStatusItem` plus `NSPopover`, `behavior = .transient`, `animates = false`,
      `sizingOptions = [.preferredContentSize]`
- [x] `MenuBarExtra("Ticketbar", isInserted: $never) { EmptyView() }` so SwiftUI has a scene
- [ ] `applicationShouldTerminateAfterLastWindowClosed`, `applicationShouldOpenUntitledFile`,
      `applicationShouldHandleReopen` all false; close the popover on `didResignActiveNotification`
- [x] Icon: filled shape plus knockout glyph, probed with `button.effectiveAppearance`, never
      `NSApp`. Legible template and color, light and dark menu bar, and over a bright wallpaper
- [ ] Badge count of open assigned issues, driven by a stub number for now
- [ ] `LaunchAtLogin` via `SMAppService.mainApp`, toggle in Settings

Proof: `mac-qc` screenshots of the icon in light and dark, template and color. Toggle launch at
login on, check System Settings shows it.

---

## M3. Issue list and the three failure states

Model: Opus 5, `think hard`. The failure split is the point of the app and the easiest thing to
silently collapse back into an empty list.

- [x] `JiraIssue` models, decoding `summary`, `status`, `priority`, `issuetype`, `updated`,
      `duedate`, `parent`, `customfield_10411`, and `renderedFields.description`
- [ ] `GET /rest/api/2/search`, `jql=assignee = currentUser() AND resolution = Unresolved ORDER BY
      updated DESC`, `expand=renderedFields`, `maxResults=50`
- [x] `JiraError` with three distinct cases, each with its own view and its own action:
      - `tokenRejected` (401 or 403): "Your token expired or was revoked", button opens the token page
      - `hostUnreachable` (`URLError` .notConnectedToInternet, .cannotFindHost, .timedOut, .cannotConnectToHost):
        "Cannot reach works.digikala.com. Are you on the VPN?", button retries
      - genuinely zero results: the only case that shows the empty state
- [x] Row: key, summary, status pill, platform from `customfield_10411` falling back to the
      emoji suffix in the summary
- [x] A debug way to force each state so the QC pass can screenshot all three

Proof: three screenshots. Real list, revoked-token state, VPN-off state. Off-VPN is tested by
actually dropping the VPN, not by mocking it.

---

## M4. Detail view, transitions, Done

Model: Sonnet 5, `think`. Transition lookup then POST is plumbing. The HTML rendering choice is
the one real decision.

- [x] Selecting a row expands to the rendered description
- [ ] Decide and record: `WKWebView` versus HTML to `AttributedString`. Jira wiki markup renders
      tables, panels and code blocks, so `WKWebView` is the honest renderer. Style it to match the
      popover in both appearances, block navigation, open links in the default browser
- [x] `GET /rest/api/2/issue/{key}/transitions`, then `POST` the matching id. Never write
      `fields.status`
- [x] Done button, resolving "Done" from the transition list rather than hardcoding an id
- [x] Status picker for the other available transitions
- [x] Open in browser link
- [ ] Optimistic row update, rolled back if the POST fails

Proof: a real issue on works.digikala.com moves to Done from the popover, verified in the browser.

---

## M5. Polling, sleep and wake, notifications

Model: Opus 5, `think hard`, `ultrathink` if it fights back. Timer lifecycle across sleep and
wake, actor isolation on the poller, the seen-set racing the first fetch, and notification clicks
routed into a popover that may not exist yet. This is where the bugs will be.

- [x] Poll interval configurable 2 to 5 minutes, default 3, one `Keys` enum, defaults registered
      at launch
- [ ] Pause on `NSWorkspace.willSleepNotification`, resume on `didWakeNotification`, refresh once
      immediately on wake
- [x] Back off instead of hammering while the host is unreachable, and stop backing off the moment
      a request succeeds
- [x] `UNUserNotificationCenter` permission requested after the first successful token test, never
      at launch
- [x] Persisted set of seen issue keys. On first run seed it silently so the existing backlog does
      not fire at once. Seeding is a separate, explicit step, not a side effect of the first fetch
- [ ] One notification per newly assigned issue, clicking it opens the popover on that issue
- [ ] No notification storms after a long sleep or a token repair

Proof: seed the set, assign yourself a fresh issue, get exactly one notification, click it, land
on that issue. Sleep the Mac for ten minutes, wake it, confirm one refresh and no burst.

---

## M6. Review, QC, release prep

Model: Sonnet 5 for `mac-qc`, Opus 5 with `think hard` for `swift-pro`. Screenshot loops need
vision, not reasoning. The audit needs reasoning.

- [x] `swift-pro` audit: concurrency and `Sendable`, secrets, accessibility, SwiftUI performance
- [ ] `mac-qc` pass: popover in light and dark, all three failure states, detail view, settings
- [ ] `scripts/clean.sh` at the end of the QC pass
- [x] `changelog.py init`, Changelog block honored from here on
- [ ] Decide whether Sparkle is in scope. If yes, `release` skill wires the appcast

Proof: screenshots committed under `_samples/`, review findings fixed or recorded as decisions.

---

## Out of scope for v1

Creating issues, sprint boards, worklogs, attachments, and editing any field other than the
status transition.


---

## M7. Board columns (added 2026-09-08, mid-build, at the user's request)

Model: Opus 5, `think`. A scope change rather than a new subsystem, but the seen-issue set and the
badge both had to follow it or they would start lying.

- [x] `/rest/agile/1.0/board/95/configuration` read for the real columns, with discovery by
      project key and then the nine workflow statuses as fallbacks
- [x] Board pinned to `rapidView=95`, project `DDS`, from the board's own URL
- [x] Dropdown at the top centre of the popover, one entry per column, selection persisted
- [x] Columns cached in defaults so the dropdown is populated on the first frame after launch
- [x] A column with no statuses mapped to it is dropped rather than offered
- [x] "Assigned to me" removed from the dropdown at the user's request
- [x] Seen-issue set namespaced per column, so switching columns is not a notification storm
- [x] Badge and icon urgency follow the selected column

Proof: the dropdown was opened against the live board and listed Sprint Backlog, Planning Web,
Planning App, In-Progress, Storybook, Testing, Blocked / Rejected, UAT and Done, with the current
one checked.

---

## Still open

- Moving a real issue to Done, which needs permission because it writes to somebody's board.
- The description in light and dark with a real wiki-markup issue, tables and code blocks included.
- Sleep and wake behaviour over a real overnight sleep.
- The Accessibility permission for this terminal host, without which `mac-qc` cannot click the
  status item; every screenshot here came from a forced QC state or a direct window capture.
