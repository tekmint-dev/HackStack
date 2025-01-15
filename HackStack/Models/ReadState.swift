import Foundation
import SwiftData

@Model
final class ReadState {
    @Attribute(.unique) var storyId: Int
    var timestamp: Date
    
    init(storyId: Int) {
        self.storyId = storyId
        self.timestamp = Date()
    }
}
