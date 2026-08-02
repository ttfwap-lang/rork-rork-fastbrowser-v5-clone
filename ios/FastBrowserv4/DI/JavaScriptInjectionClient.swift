import Foundation

nonisolated struct FillCredentialRequest: Sendable {
    let username: String
    let password: String
    let usernameSelector: String?
    let passwordSelector: String?
}

nonisolated struct FillResult: Sendable {
    let filledCount: Int
    let userFound: Bool
    let passFound: Bool
}

nonisolated struct LoginFormDetection: Sendable {
    let hasLoginForm: Bool
    let passwordFieldCount: Int
    let loginFormCount: Int
}

nonisolated struct ExtractedCredentials: Sendable {
    let found: Bool
    let username: String
    let password: String
}

nonisolated struct JavaScriptInjectionClient: Sendable {
    var fillHelperScript: @Sendable () -> String
    var fillCredentialScript: @Sendable (_ request: FillCredentialRequest) -> String
    var submitFormScript: @Sendable (_ submitSelector: String?) -> String
    var detectLoginFormScript: @Sendable () -> String
    var extractFilledCredentialsScript: @Sendable () -> String
}

extension JavaScriptInjectionClient {
    nonisolated static let unimplemented = JavaScriptInjectionClient(
        fillHelperScript: { fatalError("JavaScriptInjectionClient.fillHelperScript unimplemented") },
        fillCredentialScript: { _ in fatalError("JavaScriptInjectionClient.fillCredentialScript unimplemented") },
        submitFormScript: { _ in fatalError("JavaScriptInjectionClient.submitFormScript unimplemented") },
        detectLoginFormScript: { fatalError("JavaScriptInjectionClient.detectLoginFormScript unimplemented") },
        extractFilledCredentialsScript: { fatalError("JavaScriptInjectionClient.extractFilledCredentialsScript unimplemented") }
    )

    nonisolated static let preview = JavaScriptInjectionClient(
        fillHelperScript: { "" },
        fillCredentialScript: { _ in "" },
        submitFormScript: { _ in "" },
        detectLoginFormScript: { "" },
        extractFilledCredentialsScript: { "" }
    )
}

private enum JavaScriptInjectionClientKey: DependencyKey {
    nonisolated static let liveValue: JavaScriptInjectionClient = .unimplemented
    nonisolated static let previewValue: JavaScriptInjectionClient = .preview
}

extension DependencyValues {
    var javaScriptInjectionClient: JavaScriptInjectionClient {
        get { self[JavaScriptInjectionClientKey.self] }
        set { self[JavaScriptInjectionClientKey.self] = newValue }
    }
}
