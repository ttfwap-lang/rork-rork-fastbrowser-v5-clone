import Foundation

nonisolated struct BrowsingHistoryEntryDTO: Sendable, Identifiable {
    let id: String
    let url: String
    let title: String
    let domain: String
    let visitedAt: Date

    @MainActor
    init(from model: BrowsingHistoryEntry) {
        self.id = model.id
        self.url = model.url
        self.title = model.title
        self.domain = model.domain
        self.visitedAt = model.visitedAt
    }

    nonisolated init(
        id: String = UUID().uuidString,
        url: String,
        title: String,
        domain: String,
        visitedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.domain = domain
        self.visitedAt = visitedAt
    }
}

extension BrowsingHistoryEntry {
    func applyDTO(_ dto: BrowsingHistoryEntryDTO) {
        self.url = dto.url
        self.title = dto.title
        self.domain = dto.domain
        self.visitedAt = dto.visitedAt
    }

    static func fromDTO(_ dto: BrowsingHistoryEntryDTO) -> BrowsingHistoryEntry {
        let entry = BrowsingHistoryEntry(url: dto.url, title: dto.title, domain: dto.domain)
        entry.id = dto.id
        entry.visitedAt = dto.visitedAt
        return entry
    }
}
