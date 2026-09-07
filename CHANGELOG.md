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

