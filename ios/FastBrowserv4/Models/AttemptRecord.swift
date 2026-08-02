import Foundation
import SwiftData

/// Permanent record of one (credential, password, target) attempt. Anchored
/// by `credentialID + passwordHash` so it survives vault edits, burns, and
/// quad re-partitions.
@Model
final class AttemptRecord {
    #Index<AttemptRecord>([\.credentialID], [\.timestamp], [\.statusRaw])

    @Attribute(.unique) var id: String
    /// SwiftData `Credential.id` — string UUID.
    var credentialID: String
    /// Snapshot of the credential's email at the time of the attempt — kept
    /// even if the credential is later renamed/deleted.
    var username: String
    /// Truncated SHA-256 (16 hex chars) of the password tried. Never store
    /// the password itself outside the keychain.
    var passwordHash: String
    /// 1-based index of the password in the credential's keychain list at
    /// the time of the attempt (`2 of 5`).
    var passwordIndex: Int
    var passwordTotal: Int
    /// Host the attempt was made against (the RCR target URL's host).
    var targetDomain: String
    /// Full URL the page settled on after submit (used for forensics).
    var resultURL: String?
    var resultPageTitle: String?
    /// `"single"`, or `"S1"`/`"S2"`/`"S3"`/`"S4"` for quad cells.
    var sessionTag: String
    var statusRaw: String
    var timestamp: Date
    /// Filename (relative to the screenshots dir) of the post-submit
    /// snapshot, when one was captured.
    var screenshotFilename: String?
    /// OCR-detected category from the post-submit screenshot — "success",
    /// "failure", "captcha", "locked", "unknown", or nil if not yet analysed.
    var ocrCategory: String?

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    enum Status: String, CaseIterable {
        case pending
        case success
        case failed
        case disabled
        case tempDisabled
        case skipped
    }

    init(
        credentialID: String,
        username: String,
        passwordHash: String,
        passwordIndex: Int,
        passwordTotal: Int,
        targetDomain: String,
        sessionTag: String,
        status: Status = .pending
    ) {
        self.id = UUID().uuidString
        self.credentialID = credentialID
        self.username = username
        self.passwordHash = passwordHash
        self.passwordIndex = passwordIndex
        self.passwordTotal = passwordTotal
        self.targetDomain = targetDomain
        self.sessionTag = sessionTag
        self.statusRaw = status.rawValue
        self.timestamp = Date()
        self.ocrCategory = nil
    }
}
