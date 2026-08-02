import Foundation

nonisolated struct CredentialDTO: Sendable, Identifiable {
    let id: String
    let domain: String
    let username: String
    let notes: String?
    let totpSecret: [UInt8]?
    let createdAt: Date
    let updatedAt: Date
    let lastUsedAt: Date?
    let usageCount: Int

    var displayDomain: String {
        if domain == "imported" { return "Imported" }
        return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    }

    @MainActor
    init(from model: Credential) {
        self.id = model.id
        self.domain = model.domain
        self.username = model.username
        self.notes = model.notes
        self.totpSecret = model.totpSecret.map { Array($0) }
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
        self.lastUsedAt = model.lastUsedAt
        self.usageCount = model.usageCount
    }

    nonisolated init(
        id: String,
        domain: String,
        username: String,
        notes: String? = nil,
        totpSecret: [UInt8]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        usageCount: Int = 0
    ) {
        self.id = id
        self.domain = domain
        self.username = username
        self.notes = notes
        self.totpSecret = totpSecret
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
    }
}

extension Credential {
    func applyDTO(_ dto: CredentialDTO) {
        self.username = dto.username
        self.notes = dto.notes
        self.totpSecret = dto.totpSecret.map { Data($0) }
        self.updatedAt = Date()
    }

    static func fromDTO(_ dto: CredentialDTO) -> Credential {
        let credential = Credential(
            domain: dto.domain,
            username: dto.username,
            notes: dto.notes,
            totpSecret: dto.totpSecret.map { Data($0) }
        )
        credential.id = dto.id
        credential.createdAt = dto.createdAt
        credential.updatedAt = dto.updatedAt
        credential.lastUsedAt = dto.lastUsedAt
        credential.usageCount = dto.usageCount
        return credential
    }
}
