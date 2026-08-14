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
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return dir
    }

    /// Persists `image` as a JPEG (quality 0.7 — plenty for thumbnails)
    /// and returns the relative filename, or `nil` on failure. Screenshots
    /// show post-login pages (balances, account data), so files are written
    /// with complete file protection — unreadable while the device is locked.
    @discardableResult
    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return name
        } catch {
            return nil
        }
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// In-memory decode cache so list/grid rows never decode JPEGs on the
    /// main thread more than once per file.
    private static var imageCache: [String: UIImage] = [:]

    static func loadImage(_ filename: String) -> UIImage? {
        if let cached = imageCache[filename] { return cached }
        guard let image = UIImage(contentsOfFile: url(for: filename).path) else { return nil }
        imageCache[filename] = image
        return image
    }

    /// Decode off the main thread; used by result rows/thumbnails so
    /// scrolling a large result list doesn't hitch on JPEG decode.
    static func loadImageAsync(_ filename: String) async -> UIImage? {
        if let cached = imageCache[filename] { return cached }
        let path = url(for: filename).path
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        if let image { imageCache[filename] = image }
        return image
    }

    static func delete(_ filename: String) {
        imageCache.removeValue(forKey: filename)
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    static func deleteAll() {
        imageCache.removeAll()
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
