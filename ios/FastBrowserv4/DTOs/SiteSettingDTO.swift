import Foundation

nonisolated struct SiteSettingDTO: Sendable, Identifiable {
    var id: String { domain }

    let domain: String
    let usernameSelector: String
    let passwordSelector: String
    let submitButtonSelector: String
    let isAutoLoginEnabled: Bool
    let isSureLoginEnabled: Bool
    let sureLoginRetryCount: Int
    let sureLoginDelaySeconds: Double
    let isAutoRCEnabled: Bool
    let isAutoBurnOnRC: Bool
    let createdAt: Date
    let updatedAt: Date

    @MainActor
    init(from model: SiteSetting) {
        self.domain = model.domain
        self.usernameSelector = model.usernameSelector
        self.passwordSelector = model.passwordSelector
        self.submitButtonSelector = model.submitButtonSelector
        self.isAutoLoginEnabled = model.isAutoLoginEnabled
        self.isSureLoginEnabled = model.isSureLoginEnabled
        self.sureLoginRetryCount = model.sureLoginRetryCount
        self.sureLoginDelaySeconds = model.sureLoginDelaySeconds
        self.isAutoRCEnabled = model.isAutoRCEnabled
        self.isAutoBurnOnRC = model.isAutoBurnOnRC
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
    }

    nonisolated init(
        domain: String,
        usernameSelector: String = "",
        passwordSelector: String = "",
        submitButtonSelector: String = "",
        isAutoLoginEnabled: Bool = false,
        isSureLoginEnabled: Bool = false,
        sureLoginRetryCount: Int = 1,
        sureLoginDelaySeconds: Double = 1.0,
        isAutoRCEnabled: Bool = false,
        isAutoBurnOnRC: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.domain = domain
        self.usernameSelector = usernameSelector
        self.passwordSelector = passwordSelector
        self.submitButtonSelector = submitButtonSelector
        self.isAutoLoginEnabled = isAutoLoginEnabled
        self.isSureLoginEnabled = isSureLoginEnabled
        self.sureLoginRetryCount = sureLoginRetryCount
        self.sureLoginDelaySeconds = sureLoginDelaySeconds
        self.isAutoRCEnabled = isAutoRCEnabled
        self.isAutoBurnOnRC = isAutoBurnOnRC
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SiteSetting {
    func applyDTO(_ dto: SiteSettingDTO) {
        self.usernameSelector = dto.usernameSelector
        self.passwordSelector = dto.passwordSelector
        self.submitButtonSelector = dto.submitButtonSelector
        self.isAutoLoginEnabled = dto.isAutoLoginEnabled
        self.isSureLoginEnabled = dto.isSureLoginEnabled
        self.sureLoginRetryCount = dto.sureLoginRetryCount
        self.sureLoginDelaySeconds = dto.sureLoginDelaySeconds
        self.isAutoRCEnabled = dto.isAutoRCEnabled
        self.isAutoBurnOnRC = dto.isAutoBurnOnRC
        self.updatedAt = Date()
    }

    static func fromDTO(_ dto: SiteSettingDTO) -> SiteSetting {
        let setting = SiteSetting(domain: dto.domain)
        setting.usernameSelector = dto.usernameSelector
        setting.passwordSelector = dto.passwordSelector
        setting.submitButtonSelector = dto.submitButtonSelector
        setting.isAutoLoginEnabled = dto.isAutoLoginEnabled
        setting.isSureLoginEnabled = dto.isSureLoginEnabled
        setting.sureLoginRetryCount = dto.sureLoginRetryCount
        setting.sureLoginDelaySeconds = dto.sureLoginDelaySeconds
        setting.isAutoRCEnabled = dto.isAutoRCEnabled
        setting.isAutoBurnOnRC = dto.isAutoBurnOnRC
        setting.createdAt = dto.createdAt
        setting.updatedAt = dto.updatedAt
        return setting
    }
}
