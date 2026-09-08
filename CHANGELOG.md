# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries accumulate under [Unreleased] as work lands, and move into a versioned
section when a release is cut.

## [Unreleased]

### Added
- Menu bar client for Jira Server/DC: the DDS board's issues in a popover, without opening a browser
- Personal Access Token stored in the Keychain, one item per host, validated against the server before it is saved
- Top-centre dropdown to pick which board column to list, read from the board itself so a rearranged board needs no update
- Rejected token, unreachable host and genuinely empty are three separate states, each with its own message and its own action
- Issue detail with the description rendered as Jira sends it, a Done button and the workflow's other transitions
- Notifications for issues newly arriving in the selected column, with the existing contents recorded silently the first time a column is opened
- Polling every 2 to 5 minutes, paused across sleep and backed off while the server is unreachable
- Comments on an issue, rendered as Jira sends them, below the description in the detail view
- Settings toggles to hide the description or the comments; hiding a section also stops it being fetched
- Add and edit comments from the popover, including pasting a screenshot to attach it
- Emoji reactions on comments, with a short picker per comment
- Switches for the status chips, the description and the comments in the detail view
- Detach the panel into a floating window that stays put instead of closing when it loses focus
- The assignee's avatar on the trailing side of each issue row, fetched with your token and falling back to their initials
- A placeholder in the avatar slot for an unassigned issue, and initials for anyone who has never uploaded an avatar
- The comment box lays itself out right to left when the draft starts in Persian, and back again when it starts in English

### Changed
- The issue title is now the detail header; the issue key moved to the browser link
- One move control in the detail header instead of a Done button beside a separate Move menu
- Comments are listed newest first, with the composer above the thread
- Comment text renders at one size regardless of the inline sizes Jira stored, keeping bold, colour and structure
- List rows show the issue key, platform and due date over the title
- Rows no longer repeat the column's status: the pill shows only when a board column gathers more than one status
- The comment box grows with what you type, up to five lines, then scrolls
- The add-a-reaction control is a neutral outline icon, not a smiling face that looked like a reaction you had already added
- The detach control shows a window icon, and a menu bar icon to put it back, instead of the picture-in-picture pair
- The move control shows a circled forward arrow instead of the board grid glyph

### Removed
- The one-click Done button on list rows; moving an issue now happens in the detail view

### Fixed
- Comments no longer all show as edited when the server sends no updated timestamp
- The detail view had two nested scroll areas competing for the trackpad
- The comment thread no longer scrolls inside its own box under a stuck composer: the detail view is one scroll area, and the rendered thread reports its height as it lays out
- Persian and other right-to-left comments read in their own direction instead of being reordered by the document's left-to-right base direction
- The app no longer crashes while running: a window saving its frame triggered a menu bar icon redraw inside AppKit's layout pass, which AppKit aborts on
- The detached window keeps its size when you move between the column list and an issue, and the content fills it instead of being capped at popover height
- The platform pill no longer wraps mid-word when the header is tight
- Pasting a screenshot attaches the image instead of inserting its file name as text
- The back button, title and header buttons line up when an issue title wraps to two lines

