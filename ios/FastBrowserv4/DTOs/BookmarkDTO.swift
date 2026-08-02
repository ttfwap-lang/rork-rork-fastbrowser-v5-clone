import Foundation

nonisolated struct BookmarkDTO: Sendable, Identifiable {
    let id: String
    let url: String
    let title: String
    let domain: String
    let createdAt: Date
    let sortOrder: Int

    @MainActor
    init(from model: Bookmark) {
        self.id = model.id
        self.url = model.url
        self.title = model.title
        self.domain = model.domain
        self.createdAt = model.createdAt
        self.sortOrder = model.sortOrder
    }

    nonisolated init(
        id: String = UUID().uuidString,
        url: String,
        title: String,
        domain: String,
        createdAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.domain = domain
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}

extension Bookmark {
    func applyDTO(_ dto: BookmarkDTO) {
        self.url = dto.url
        self.title = dto.title
        self.domain = dto.domain
        self.sortOrder = dto.sortOrder
    }

    static func fromDTO(_ dto: BookmarkDTO) -> Bookmark {
        let bookmark = Bookmark(url: dto.url, title: dto.title, domain: dto.domain, sortOrder: dto.sortOrder)
        bookmark.id = dto.id
        bookmark.createdAt = dto.createdAt
        return bookmark
    }
}
