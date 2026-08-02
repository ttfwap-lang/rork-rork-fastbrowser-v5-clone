import Foundation

nonisolated struct KeychainClient: Sendable {
    var savePassword: @Sendable (_ password: String, _ credentialID: String) async throws -> Void
    var getPassword: @Sendable (_ credentialID: String) async throws -> String?
    var batchGetPasswords: @Sendable (_ credentialIDs: [String]) async throws -> [String: String]
    var deletePassword: @Sendable (_ credentialID: String) async throws -> Void
}

extension KeychainClient {
    nonisolated static let unimplemented = KeychainClient(
        savePassword: { _, _ in fatalError("KeychainClient.savePassword unimplemented") },
        getPassword: { _ in fatalError("KeychainClient.getPassword unimplemented") },
        batchGetPasswords: { _ in fatalError("KeychainClient.batchGetPasswords unimplemented") },
        deletePassword: { _ in fatalError("KeychainClient.deletePassword unimplemented") }
    )

    nonisolated static let preview = KeychainClient(
        savePassword: { _, _ in },
        getPassword: { _ in nil },
        batchGetPasswords: { _ in [:] },
        deletePassword: { _ in }
    )
}

private enum KeychainClientKey: DependencyKey {
    nonisolated static let liveValue: KeychainClient = .unimplemented
    nonisolated static let previewValue: KeychainClient = .preview
}

extension DependencyValues {
    var keychainClient: KeychainClient {
        get { self[KeychainClientKey.self] }
        set { self[KeychainClientKey.self] = newValue }
    }
}
