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
- A two-finger swipe right across an issue's header goes back to the column list
- Swipe across the header with two fingers to move between board columns
- An app icon, built from an Icon Composer bundle
- An issue's Component/s, Labels, Story Points and Affects Version/s under the header
- Opening an issue slides it in from the right and going back slides it out again, by button or by swipe
- Jira's issue type icon leads every row in the list
- A task or sub-task shows its parent story, and an epic link when it has one
- Switching column slides the list in the direction you went, by swipe or from the dropdown
- A task's row carries the story it belongs to as a tag
- Right-click an issue in the list to move it to another column without opening it
- Command Return in the comment box now posts the comment, or saves it when editing. Return on its own still starts a new line.

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
- The move control is an ellipsis, and each destination in its menu is named after the board column it lands in, with a colour emoji to tell them apart
- The menu bar icon is now the diamond mark, from a bundled PNG cropped to its own artwork. It still tints to the bar in monochrome mode and still carries the urgency color when colors are on.
- The detach control is a pin, filled while the panel is pinned open
- The app is now called Jirabar. Your saved token and every setting carry over, because the rename left the underlying storage identifiers alone
- Issue type and priority show Jira's own icons instead of plain text chips
- An issue title stays on one line and ends in an ellipsis rather than being clipped
- The move menu names each destination exactly as the board names that column, with no added emoji
- Component/s and Labels read as tag chips, and the Updated line is gone
- The platform tag moved out of the issue header down to the row of chips with the issue's other attributes
- The issue count sits with the column name in the header instead of in a badge of its own
- Removed the standing "Paste a screenshot to attach it" hint under the comment box, and widened the gap between the composer and the comment thread.
- The issue count badge now sits after the column name in the header instead of in front of it.
- Two-finger swipes work anywhere on the panel: sideways over the list moves between columns, and to the right on an issue goes back
- Type and priority sit in the same badge as the chips beside them
- Switching column slides the list the way you swiped, and going back to the list is no longer quicker than going in
- The list follows your fingers while you swipe between columns, springs back when the swipe is too small, and gives way less at either end of the board
- Move menus list only the board's columns, so a workflow status the board has no column for is no longer offered
- Swiping between board columns now slides in a placeholder list that matches the real row layout, and fills in the issues when they arrive, instead of showing a spinner on an empty panel.
- While swiping between board columns, the next or previous column's placeholder now travels in from the edge with your fingers instead of uncovering empty space.
- Releasing a column swipe now carries the gesture through in one motion: the current column slides out and the new one slides in from where the placeholder was, instead of snapping back first.
- Moving an issue to another column now animates: the row fades out and the rows below it slide up to close the gap, instead of the list jumping.
- Every field value under the header reads as a badge, story points included, not only the tag lists
- Components, labels, story points and the parent story join the badges under the title instead of sitting in a table below them
- The story points badge reads "4 SP" rather than a bare number

### Removed
- The one-click Done button on list rows; moving an issue now happens in the detail view
- The issue count beside the menu bar icon, and its setting

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
- Images attached to a comment or a description now show, fetched with your token and inlined, instead of appearing as a broken icon with the file name
- Cmd+V works in the comment box, so a screenshot on the clipboard actually attaches
- The detached window can no longer be dragged narrower than the panel, and a window saved too narrow by an earlier build is widened when it reopens
- The add-a-reaction chip opens the emoji picker beside the comment you clicked, instead of placing it below the whole thread where it could not be seen
- Adding or removing an emoji reaction tries the shapes this Jira's internal API accepts, and says so plainly when the reaction does not stick
- Cmd+V, Cmd+C, Cmd+X, Cmd+A and undo work in the comment box and the token field, for plain text as well as pasted images
- Two-finger swipes now register: the gesture is judged on its whole travel, so swiping between columns and swiping back both work
- The move menu no longer shows two emoji per row on a board whose columns are already named with one
- More issue types show their icon, not only stories and tasks
- Issue types whose icon this Jira serves as its own avatar, Task among them, now show it
- Switching column fades instead of tearing the list apart mid animation
- The detached window fills with the panel instead of leaving it floating in the middle
- The issue count badge no longer disappears while a column loads, so the column name and chevron stop jumping sideways on every column switch.
- Opening an issue now always takes the list out towards the leading edge, instead of following whichever direction the last column swipe went.
- Moves whose destination Jira reports without a status id are offered again, instead of looking like the workflow refused them
- The issue count badge in the header no longer blinks out and back when switching columns. It stays in place and rolls to the new value.
- The header no longer grows by a fraction of a point while a refresh is in flight, which was nudging the divider and the whole list down and back.
- Cmd+V, Cmd+C, Cmd+X, Cmd+A and undo now work with a non-Latin keyboard layout selected. They matched the letter printed on the key, so switching to Persian to write a comment silently broke pasting an image.
- The add-a-reaction control is hidden on a Jira that has no reactions API, instead of failing with "Not found on this server" every time

