import Foundation

/// The Personal Access Token, and nothing else, in the Keychain.
///
/// Rules that are not negotiable (CLAUDE.md, Decisions):
/// - The token is never written to UserDefaults, a plist, a log line or an error message.
/// - The service name is a storage address. Renaming it strands the user's token.
/// - Callers read the token, use it immediately, and do not retain it.
///
/// One item per host, so changing the base URL does not silently reuse a token minted for a
/// different Jira instance.
struct TokenStore {
    /// Debug builds carry `in.pooya.ticketbar.debug`, so a dev build gets its own item and cannot
    /// clobber the token the installed release is using.
    static let service: String = (Bundle.main.bundleIdentifier ?? "in.pooya.ticketbar") + ".pat"

    private let keychain: KeychainStore

    init(service: String = TokenStore.service) {
        self.keychain = KeychainStore(service: service)
    }

    /// Keychain accounts are per host, so `works.digikala.com` and a staging instance coexist.
    static func account(for baseURL: URL?) -> String {
        baseURL?.host ?? "default"
    }

    func token(for baseURL: URL?) -> String? {
        guard let data = try? keychain.secret(for: Self.account(for: baseURL)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True when a token exists, without reading it. The UI asks this constantly; nothing should
    /// pull the secret into memory just to draw a checkmark.
    func hasToken(for baseURL: URL?) -> Bool {
        (try? keychain.accounts())?.contains(Self.account(for: baseURL)) ?? false
    }

    func save(_ token: String, for baseURL: URL?) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw KeychainStore.StoreError.notFound
        }
        // The label is what Keychain Access shows. It names the item; it never holds the secret.
        try keychain.set(data, for: Self.account(for: baseURL), label: "Ticketbar token")
    }

    func delete(for baseURL: URL?) throws {
        try keychain.delete(account: Self.account(for: baseURL))
    }
}
