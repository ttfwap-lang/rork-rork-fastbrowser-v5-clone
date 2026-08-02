import SwiftData
import Foundation

@Model
class Bookmark {
    #Index<Bookmark>([\.sortOrder], [\.domain])

    var id: String
    var url: String
    var title: String
    var domain: String
    var createdAt: Date
    var sortOrder: Int

    init(url: String, title: String, domain: String, sortOrder: Int = 0) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title
        self.domain = domain.lowercased()
        self.createdAt = Date()
        self.sortOrder = sortOrder
    }
}
