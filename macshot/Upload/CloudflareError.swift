#if !OFFLINE
import Foundation

/// Everything the Cloudflare clients can fail with, phrased so a later UI phase
/// can show `localizedDescription` directly. (Messages are plain English for
/// now; localize them when the Settings/Export UI lands.)
nonisolated enum CloudflareError: Error, Equatable, Sendable, LocalizedError {
    /// No account ID / API token saved yet.
    case notConfigured
    /// 401, or an "invalid token" envelope code.
    case authFailed
    /// The token is recognised but is not active (expired, disabled).
    case tokenInactive(status: String)
    /// 403: the token (or account ID) can't use this product.
    case permissionMissing(capability: String)
    /// Client-side or 413 size limit, in bytes.
    case fileTooLarge(what: String, limitBytes: Int)
    /// The local file can't be uploaded (missing, empty, unreadable).
    case invalidFile(String)
    /// Cloudflare answered with `success: false` or an unexpected status.
    case api(code: Int?, message: String, status: Int?)
    /// The response wasn't what the tus / REST contract promises.
    case invalidResponse(String)
    /// Transport failure after any resume attempts were used up.
    case network(String)
    /// The task was cancelled; nothing further was sent.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloudflare isn't set up yet. Add your account ID and API token in Settings."
        case .authFailed:
            return "Cloudflare rejected the API token. Check that the token is correct and hasn't been revoked."
        case .tokenInactive(let status):
            return "The Cloudflare API token is \(status). Create a new token with Stream Edit and Images Edit permissions."
        case .permissionMissing(let capability):
            return "The Cloudflare API token can't use \(capability). Make sure the token has Stream Edit and Images Edit permissions for this account and the account ID is correct."
        case .fileTooLarge(let what, let limit):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "\(what) is larger than Cloudflare's limit of \(formatter.string(fromByteCount: Int64(limit)))."
        case .invalidFile(let detail):
            return detail
        case .api(let code, let message, _):
            if let code { return "Cloudflare error \(code): \(message)" }
            return "Cloudflare error: \(message)"
        case .invalidResponse(let detail):
            return "Unexpected response from Cloudflare: \(detail)"
        case .network(let detail):
            return "Couldn't reach Cloudflare: \(detail)"
        case .cancelled:
            return "The Cloudflare request was cancelled."
        }
    }

    /// Maps anything thrown while talking to the network onto `CloudflareError`.
    static func wrap(_ error: Error) -> CloudflareError {
        if let error = error as? CloudflareError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }
}
#endif
