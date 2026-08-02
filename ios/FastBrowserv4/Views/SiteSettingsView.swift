import SwiftUI
import SwiftData

struct SiteSettingsView: View {
    let domain: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var setting: SiteSetting?
    @State private var usernameSelector: String = ""
    @State private var passwordSelector: String = ""
    @State private var submitSelector: String = ""
    @State private var isAutoLogin: Bool = false
    @State private var isSureLogin: Bool = false
    @State private var retryCount: Int = 1
    @State private var retryDelay: Double = 1.0
    @State private var isAutoRC: Bool = false
    @State private var isAutoBurnOnRC: Bool = false
    @State private var isDetectResponse: Bool = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(.cyan)
                    Text(domain)
                        .font(.headline)
                }
            }

            Section {
                TextField("Username field selector", text: $usernameSelector)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Password field selector", text: $passwordSelector)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Submit button selector", text: $submitSelector)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Custom CSS Selectors")
            } footer: {
                Text("Leave empty to use auto-detection. Use CSS selectors like #email, .login-btn, input[name=\"user\"]")
            }

            Section {
                Toggle("Auto Login", isOn: $isAutoLogin)

                if isAutoLogin {
                    Toggle("Sure Login (Retry Submit)", isOn: $isSureLogin)

                    if isSureLogin {
                        Stepper("Retries: \(retryCount)", value: $retryCount, in: 1...4)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Delay: \(retryDelay, specifier: "%.1f")s")
                                .font(.subheadline)
                            Slider(value: $retryDelay, in: 0.5...5.0, step: 0.5)
                        }
                    }
                }
            } header: {
                Text("Auto Login")
            } footer: {
                if isAutoLogin {
                    Text("Auto Login presses the submit button after filling credentials. Sure Login retries if the first attempt fails — great for flaky login forms.")
                }
            }

            Section {
                Toggle("Auto Rotate Credential", isOn: $isAutoRC)

                if isAutoRC {
                    Toggle("Auto Burn on Rotate", isOn: $isAutoBurnOnRC)
                }
            } header: {
                Text("Combo Modes")
            } footer: {
                if isAutoRC {
                    Text("Auto RC rotates to the next credential if login appears to fail. Auto Burn clears session data before retrying.")
                }
            }

            Section {
                Toggle("Detect login response", isOn: $isDetectResponse)
            } header: {
                Text("Detection")
            } footer: {
                Text("After each auto-submit, watches the page briefly and shows a toast: succeeded, failed, blocked, or no response. Informational only — never changes RCR behavior.")
            }
        }
        .navigationTitle("Site Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .task { loadSettings() }
    }

    private func loadSettings() {
        let lowDomain = domain.lowercased()
        let descriptor = FetchDescriptor<SiteSetting>(
            predicate: #Predicate<SiteSetting> { $0.domain == lowDomain }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            setting = existing
            usernameSelector = existing.usernameSelector
            passwordSelector = existing.passwordSelector
            submitSelector = existing.submitButtonSelector
            isAutoLogin = existing.isAutoLoginEnabled
            isSureLogin = existing.isSureLoginEnabled
            retryCount = existing.sureLoginRetryCount
            retryDelay = existing.sureLoginDelaySeconds
            isAutoRC = existing.isAutoRCEnabled
            isAutoBurnOnRC = existing.isAutoBurnOnRC
        }
        isDetectResponse = UserDefaults.standard.bool(
            forKey: BrowserViewModel.detectResponseKey(for: domain)
        )
    }

    private func save() {
        let target: SiteSetting
        if let existing = setting {
            target = existing
        } else {
            target = SiteSetting(domain: domain)
            modelContext.insert(target)
        }

        target.usernameSelector = usernameSelector
        target.passwordSelector = passwordSelector
        target.submitButtonSelector = submitSelector
        target.isAutoLoginEnabled = isAutoLogin
        target.isSureLoginEnabled = isSureLogin
        target.sureLoginRetryCount = retryCount
        target.sureLoginDelaySeconds = retryDelay
        target.isAutoRCEnabled = isAutoRC
        target.isAutoBurnOnRC = isAutoBurnOnRC
        target.updatedAt = Date()

        UserDefaults.standard.set(
            isDetectResponse,
            forKey: BrowserViewModel.detectResponseKey(for: domain)
        )

        dismiss()
    }
}
