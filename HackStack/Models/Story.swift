import Foundation
import SwiftData

@Model
final class Story {
    @Attribute(.unique) var id: Int
    var title: String
    var url: String?
    var by: String
    var score: Int
    var timestamp: Date
    var relativeTime: String
    var commentCount: Int
    var isRead: Bool
    var isFavorite: Bool
    var story_text: String?
    private var kidsString: String?
    
    var kids: [Int]? {
        get {
            guard let kidsString = kidsString, !kidsString.isEmpty else { return nil }
            // Filter out any invalid integers while converting
            let numbers = kidsString.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return numbers.isEmpty ? nil : numbers
        }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                kidsString = newValue.map { String($0) }.joined(separator: ",")
            } else {
                kidsString = nil
            }
        }
    }
    
    init(id: Int, title: String, url: String? = nil, by: String, score: Int, timestamp: Date, commentCount: Int, kids: [Int]? = nil, story_text: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.by = by
        self.score = score
        self.timestamp = timestamp
        self.relativeTime = TimeFormatter.getRelativeTime(from: timestamp)
        self.commentCount = commentCount
        self.isRead = false
        self.isFavorite = false
        self.kids = kids
        self.story_text = story_text
    }
}

// MARK: - API Response
struct StoryResponse: Codable {
    let id: Int
    let title: String
    let url: String?
    let by: String
    let score: Int
    let time: TimeInterval
    let descendants: Int?  // Made optional since job posts don't have this field
    let kids: [Int]?
    let text: String?
    
    func toStory() -> Story {
        Story(
            id: id,
            title: title,
            url: url,
            by: by,
            score: score,
            timestamp: Date(timeIntervalSince1970: time),
            commentCount: descendants ?? 0,  // Default to 0 if descendants is nil
            kids: kids,
            story_text: text
        )
    }
}
