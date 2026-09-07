import SwiftUI

struct SettingsView: View {
    @Bindable var store: IssueStore
    let notifications: NotificationService
    let onRefresh: () -> Void

    @AppStorage(Keys.baseURL) private var baseURLText = Keys.defaultBaseURL
    @AppStorage(Keys.pollMinutes) private var pollMinutes = 3
    @AppStorage(Keys.monochromeIcon) private var monochromeIcon = false
    @AppStorage(Keys.showBadgeCount) private var showBadgeCount = true
    @AppStorage(Keys.notifyOnNewIssue) private var notifyOnNewIssue = true
    @AppStorage(Keys.showDescription) private var showDescription = true
    @AppStorage(Keys.showComments) private var showComments = true

    /// The paste field. It is never populated from the Keychain: the stored token has no reason
    /// to travel back into a view, and a field that shows it is a field that can be copied out of.
    @State private var pastedToken = ""
    @State private var isTesting = false
    /// Set only when the user explicitly asks to replace a token that is already saved.
    @State private var isReplacingToken = false
    @State private var testResult: TestResult?
    @State private var launchAtLogin = false
    @State private var launchAtLoginMessage: String?

    /// The field is shown when there is nothing saved yet, or when the user asked to replace it.
    private var isEditingToken: Bool { !store.hasToken || isReplacingToken }

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        SettingsTabBody {
            accountSection
            issueDetailSection
            refreshSection
            menuBarSection
            notificationsSection
            generalSection
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        SettingsSection("Jira Account",
                        footnote: "Personal Access Tokens expire, often after 90 days. When yours does, Ticketbar says so instead of showing an empty list.") {
            SettingsFieldRow(title: "Server",
                             placeholder: Keys.defaultBaseURL,
                             text: $baseURLText,
                             monospaced: true)
            SettingsDivider()

            // Once a token is saved there is nothing to type, so the field goes away. Leaving an
            // empty input sitting there invites a re-paste that is not needed, and it takes first
            // responder, which is what makes macOS offer the Passwords popup every time the window
            // opens. Replacing a token is a deliberate act, so it gets a deliberate button.
            if isEditingToken {
                SettingsRow("Personal Access Token",
                            subtitle: "Paste the token from Jira. It is checked against the server before it is saved.") {
                    SecureField("Paste token", text: $pastedToken)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: SettingsMetrics.controlWidth)
                }
            } else {
                SettingsRow("Personal Access Token",
                            subtitle: "Held in your Keychain for \(parsedBaseURL?.host ?? "this server"). Ticketbar never stores it anywhere else.") {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            SettingsDivider()

            SettingsBlock {
                HStack(spacing: 8) {
                    if isEditingToken {
                        Button("Create a Token...") {
                            if let url = tokenPageURL { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                        .disabled(tokenPageURL == nil)

                        Button(isTesting ? "Testing..." : "Test and Save") {
                            Task { await test() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(isTesting || pastedToken.isEmpty)

                        if store.hasToken {
                            Button("Cancel") {
                                isReplacingToken = false
                                pastedToken = ""
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button(isTesting ? "Testing..." : "Test Connection") {
                            Task { await test() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(isTesting)

                        Button("Replace Token...") {
                            isReplacingToken = true
                            testResult = nil
                        }
                        .controlSize(.small)

                        Button("Sign Out") {
                            store.forgetAccount()
                            pastedToken = ""
                            isReplacingToken = false
                            testResult = nil
                        }
                        .controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }
            }

            if let testResult {
                SettingsDivider()
                SettingsBlock {
                    switch testResult {
                    case .success(let name):
                        Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var tokenPageURL: URL? {
        parsedBaseURL?.appendingPathComponent("secure/ViewProfile.jspa")
    }

    private var parsedBaseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Validate, then store. The token only reaches the Keychain once the server has confirmed it
    /// works, so a typo cannot quietly replace a working token with a broken one.
    private func test() async {
        guard let baseURL = parsedBaseURL else {
            testResult = .failure("That server address is not a valid URL.")
            return
        }
        let candidate = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = candidate.isEmpty ? store.tokenStore.token(for: baseURL) : candidate
        guard let token, !token.isEmpty else {
            testResult = .failure("Paste a token first.")
            return
        }

        isTesting = true
        defer { isTesting = false }

        switch await store.verifyToken(baseURL: baseURL, token: token) {
        case .success(let user):
            if !candidate.isEmpty {
                do {
                    try store.tokenStore.save(candidate, for: baseURL)
                } catch {
                    testResult = .failure("The token works, but it could not be saved to the Keychain.")
                    return
                }
            }
            pastedToken = ""
            isReplacingToken = false
            testResult = .success(user.displayName)
            // Asked for here and nowhere else: after the app has proved it can reach the server.
            await notifications.requestAuthorizationIfNeeded()
            onRefresh()
        case .failure(let error):
            testResult = .failure(Self.message(for: error, host: baseURL.host ?? "the server"))
        }
    }

    /// Test failures get the same three-way distinction the popover makes, for the same reason.
    private static func message(for error: JiraError, host: String) -> String {
        switch error {
        case .tokenRejected:
            return "\(host) rejected that token. It may have expired or been revoked."
        case .hostUnreachable(let reason):
            return "\(reason) \(host) is internal, so check the VPN."
        case .tlsFailure(let reason):
            return reason
        case .notFound:
            return "That address answered, but it is not a Jira REST API. Check the server URL."
        case .badRequest(let message), .decodingFailed(let message), .unexpected(let message):
            return message
        case .serverError(let code):
            return "\(host) answered \(code)."
        case .notConfigured:
            return "Paste a token first."
        }
    }

    // MARK: - Other sections

    private var issueDetailSection: some View {
        SettingsSection("Issue Detail",
                        footnote: "Turning a section off also stops Ticketbar fetching it, so a long description or a busy comment thread costs nothing when you are not reading it.") {
            SettingsRow("Show the description") {
                SettingsSwitch(isOn: $showDescription)
            }
            SettingsDivider()
            SettingsRow("Show comments") {
                SettingsSwitch(isOn: $showComments)
            }
        }
    }

    private var refreshSection: some View {
        SettingsSection("Refresh",
                        footnote: "Jira Server cannot push to a Mac, so Ticketbar polls. Polling stops while this Mac sleeps and while the server is unreachable.") {
            SettingsRow("Check every") {
                Picker("", selection: $pollMinutes) {
                    ForEach(Array(Keys.pollMinutesRange), id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
            }
        }
    }

    private var menuBarSection: some View {
        SettingsSection("Menu Bar") {
            SettingsRow("Show the issue count") {
                SettingsSwitch(isOn: $showBadgeCount)
            }
            SettingsDivider()
            SettingsRow("Monochrome icon",
                        subtitle: "Uses the menu bar's own color instead of the status colors, which turn orange when something is due today and red when something is overdue.") {
                SettingsSwitch(isOn: $monochromeIcon)
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection("Notifications",
                        footnote: "On first launch the issues already assigned to you are recorded silently, so the existing backlog never arrives as a wall of notifications.") {
            SettingsRow("Notify me about newly assigned issues") {
                SettingsSwitch(isOn: $notifyOnNewIssue)
            }
        }
    }

    private var generalSection: some View {
        SettingsSection("General", footnote: launchAtLoginMessage) {
            SettingsRow("Launch at login") {
                SettingsSwitch(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        launchAtLoginMessage = LaunchAtLogin.set(enabled)
                        // Write back what macOS actually did, not what was asked for.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            }
        }
    }
}
