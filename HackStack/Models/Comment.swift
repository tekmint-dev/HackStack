import Foundation
import SwiftData
import SwiftUI

@Model
final class Comment {
    @Attribute(.unique) var id: Int
    var text: String
    var by: String
    var timestamp: Date
    var relativeTime: String
    var kidsString: String
    var level: Int
    var isCollapsed: Bool
    var hasLoadedChildren: Bool
    var isDeleted: Bool
    var isDead: Bool
    
    // Cache for parsed HTML and child comments
    @Transient private var _parsedText: AttributedString?
    @Transient private var _childComments: [Comment]?
    
    var kids: [Int] {
        get {
            kidsString.isEmpty ? [] : kidsString.split(separator: ",").compactMap { Int($0) }
        }
        set {
            kidsString = newValue.map(String.init).joined(separator: ",")
        }
    }
    
    var parsedText: AttributedString {
        if let cached = _parsedText {
            return cached
        }
        let parsed = HTMLParser.parseHTML(text)
        _parsedText = parsed
        return parsed
    }
    
    var childComments: [Comment] {
        get { _childComments ?? [] }
        set { _childComments = newValue }
    }
    
    init(id: Int, text: String, by: String, timestamp: Date, kids: [Int] = [], level: Int = 0, isDeleted: Bool = false, isDead: Bool = false) {
        self.id = id
        self.text = text
        self.by = by
        self.timestamp = timestamp
        self.relativeTime = TimeFormatter.getRelativeTime(from: timestamp)
        self.kidsString = kids.map(String.init).joined(separator: ",")
        self.level = level
        self.isCollapsed = false
        self.hasLoadedChildren = false
        self.isDeleted = isDeleted
        self.isDead = isDead
        self._childComments = []
    }
}

// MARK: - API Response
struct CommentResponse: Codable {
    let id: Int
    let text: String?
    let by: String?
    let time: TimeInterval
    let kids: [Int]?
    let deleted: Bool?
    let dead: Bool?
    
    func toComment(level: Int = 0) -> Comment {
        // Handle deleted or dead comments
        if deleted == true || dead == true {
            return Comment(
                id: id,
                text: deleted == true ? "[deleted]" : "[dead]",
                by: "[unknown]",
                timestamp: Date(timeIntervalSince1970: time),
                kids: kids ?? [],
                level: level,
                isDeleted: deleted == true,
                isDead: dead == true
            )
        }
        
        // Handle missing text or author
        let commentText = text ?? "[no content]"
        let author = by ?? "[unknown]"
        
        return Comment(
            id: id,
            text: commentText,
            by: author,
            timestamp: Date(timeIntervalSince1970: time),
            kids: kids ?? [],
            level: level
        )
    }
}
