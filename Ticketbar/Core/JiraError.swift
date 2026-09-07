import Foundation

/// Everything that can go wrong, kept as separate cases on purpose.
///
/// The single worst bug this app can have is collapsing a failure into "no issues". The type
/// system is the cheapest place to prevent that: there is no case here that a view can render as
/// an empty list, and `ContentState` has no path from an error to `.empty`.
///
/// No case ever carries the token. Messages are built from status codes and Jira's own
/// `errorMessages`, never from the request.
enum JiraError: Error, Equatable {
    /// No token stored yet. Onboarding, not a failure.
    case notConfigured
    /// 401 or 403. The PAT expired, was revoked, or lacks permission. Expected roughly quarterly.
    case tokenRejected
    /// DNS, connection or timeout. On an internal host this almost always means the VPN is down.
    case hostUnreachable(String)
    /// TLS refused the handshake. Not the same as unreachable, and telling the user to check the
    /// VPN when the certificate is the problem is the same class of lie as showing an empty list.
    case tlsFailure(String)
    /// 400, usually a JQL the server would not parse.
    case badRequest(String)
    case notFound(String)
    case serverError(Int)
    case decodingFailed(String)
    case unexpected(String)

    /// Maps a transport failure. Anything not clearly a reachability problem stays `unexpected`
    /// so it cannot masquerade as "you are off the VPN".
    static func from(urlError: URLError) -> JiraError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff:
            return .hostUnreachable("This Mac has no network connection.")
        case .cannotFindHost, .dnsLookupFailed:
            return .hostUnreachable("The host name does not resolve.")
        case .cannotConnectToHost, .timedOut:
            return .hostUnreachable("The host did not answer.")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .tlsFailure("The secure connection was refused.")
        case .cancelled:
            return .unexpected("The request was cancelled.")
        default:
            return .unexpected(urlError.localizedDescription)
        }
    }

    /// Maps an HTTP status. `body` is Jira's response, already reduced to its `errorMessages`.
    static func from(statusCode: Int, message: String?) -> JiraError? {
        switch statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .tokenRejected
        case 400:
            return .badRequest(message ?? "The server rejected the request.")
        case 404:
            return .notFound(message ?? "Not found on this server.")
        case 500...599:
            return .serverError(statusCode)
        default:
            return .unexpected(message ?? "The server answered \(statusCode).")
        }
    }
}
