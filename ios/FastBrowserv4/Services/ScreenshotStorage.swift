import Foundation
import UIKit
import CryptoKit

/// On-disk store for RCR post-submit screenshots. Files live under
/// `Application Support/RCRScreenshots` and are named with random UUIDs so
/// no PII leaks into the filesystem.
@MainActor
enum ScreenshotStorage {
    static let directoryName = "RCRScreenshots"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Persists `image` as a JPEG (quality 0.7 — plenty for thumbnails)
    /// and returns the relative filename, or `nil` on failure.
    @discardableResult
    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    static func loadImage(_ filename: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: filename).path)
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    static func deleteAll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}

/// Truncated SHA-256 used to fingerprint a password without ever storing it
/// outside the keychain.
nonisolated enum PasswordFingerprint {
    static func hash(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
}
