import Foundation

nonisolated enum KeychainError: Error, Sendable, LocalizedError {
    case saveFailed(OSStatus)
    case itemNotFound
    case dataConversionFailed
    case deleteFailed(OSStatus)
    case unexpectedStatus(OSStatus)

    nonisolated var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed (status: \(status))"
        case .itemNotFound:
            return "Keychain item not found"
        case .dataConversionFailed:
            return "Failed to convert keychain data"
        case .deleteFailed(let status):
            return "Keychain delete failed (status: \(status))"
        case .unexpectedStatus(let status):
            return "Unexpected keychain status: \(status)"
        }
    }
}

nonisolated enum BiometricError: Error, Sendable, LocalizedError {
    case notAvailable
    case authenticationFailed(String)
    case userCancelled
    case systemCancelled
    case passcodeNotSet
    case biometryNotEnrolled
    case biometryLockedOut

    nonisolated var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .userCancelled:
            return "Authentication was cancelled"
        case .systemCancelled:
            return "Authentication was cancelled by the system"
        case .passcodeNotSet:
            return "Device passcode is not set"
        case .biometryNotEnrolled:
            return "No biometric data is enrolled"
        case .biometryLockedOut:
            return "Biometry is locked out due to too many failed attempts"
        }
    }
}
