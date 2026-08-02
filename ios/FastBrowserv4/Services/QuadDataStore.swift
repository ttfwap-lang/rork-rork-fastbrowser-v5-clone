import Foundation
import WebKit

/// Stable, persistent WebKit data-store identifiers for the up-to-twelve
/// multi-window sessions. Using `WKWebsiteDataStore(forIdentifier:)` (iOS
/// 17+) gives each session its own fully isolated cookies, cache, local
/// storage and IndexedDB — no window can ever see another window's data or
/// fingerprint, at any grid size.
enum QuadDataStore {
    static let identifiers: [UUID] = [
        UUID(uuidString: "A1A1A1A1-0001-4000-8000-000000000001")!,
        UUID(uuidString: "A2A2A2A2-0002-4000-8000-000000000002")!,
        UUID(uuidString: "A3A3A3A3-0003-4000-8000-000000000003")!,
        UUID(uuidString: "A4A4A4A4-0004-4000-8000-000000000004")!,
        UUID(uuidString: "A5A5A5A5-0005-4000-8000-000000000005")!,
        UUID(uuidString: "A6A6A6A6-0006-4000-8000-000000000006")!,
        UUID(uuidString: "A7A7A7A7-0007-4000-8000-000000000007")!,
        UUID(uuidString: "A8A8A8A8-0008-4000-8000-000000000008")!,
        UUID(uuidString: "A9A9A9A9-0009-4000-8000-000000000009")!,
        UUID(uuidString: "B1B1B1B1-0010-4000-8000-000000000010")!,
        UUID(uuidString: "B2B2B2B2-0011-4000-8000-000000000011")!,
        UUID(uuidString: "B3B3B3B3-0012-4000-8000-000000000012")!
    ]

    static func identifier(for index: Int) -> UUID {
        identifiers[index % identifiers.count]
    }

    /// Wipes every byte of state for the given Quad session — cookies,
    /// cache, local storage, IndexedDB, service-worker registrations, etc.
    /// Other sessions are untouched.
    static func burn(index: Int) async {
        await burn(dataStoreID: identifier(for: index))
    }

    /// Generic wipe for any isolated store (single-tab or multi-window).
    static func burn(dataStoreID: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))
        await MainActor.run {
            WebViewConfigurationFactory.shared.releaseProcessPool(for: dataStoreID)
        }
    }
}
