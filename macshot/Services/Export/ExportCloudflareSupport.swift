import Foundation

/// The two Cloudflare facts the export UI needs, behind the OFFLINE fence so
/// callers don't each carry `#if`: is an account saved, and which one.
enum ExportCloudflareSupport {
    static var isConfigured: Bool {
        #if OFFLINE
        return false
        #else
        return CloudflareAccount.shared.isConfigured
        #endif
    }

    static var accountID: String? {
        #if OFFLINE
        return nil
        #else
        return CloudflareAccount.shared.accountID
        #endif
    }

    /// Whether this build has Cloudflare at all.
    static var isAvailable: Bool { !BuildVariant.isOffline }
}

/// The TrainWithDixon (Coach OS) facts the export UI needs, behind the OFFLINE
/// fence: is an address saved, and where its Media page is.
enum ExportCoachOSSupport {
    static var isConfigured: Bool { mediaPageURL != nil }

    static var mediaPageURL: URL? {
        #if OFFLINE
        return nil
        #else
        return CoachOSSettings.mediaPageURL()
        #endif
    }
}
