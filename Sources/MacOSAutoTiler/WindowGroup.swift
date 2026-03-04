import CoreGraphics
import Foundation

typealias WindowGroupID = UUID

struct WindowGroup: Codable, Identifiable {
    let id: WindowGroupID
    var name: String
    var windowIDs: Set<CGWindowID>
    var createdAt: Date

    init(name: String) {
        id = UUID()
        self.name = name
        windowIDs = []
        createdAt = Date()
    }
}

struct WindowGroupStore: Codable {
    var groups: [WindowGroup]
    var activeGroupID: WindowGroupID?
}
