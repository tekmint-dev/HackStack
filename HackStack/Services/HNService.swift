import Foundation

enum StoryType {
    case search, top, new, best, ask, show, job, favorites
    
    var endpoint: String {
        switch self {
        case .search: return "search"
        case .top: return "topstories"
        case .new: return "newstories"
        case .best: return "beststories"
        case .ask: return "askstories"
        case .show: return "showstories"
        case .job: return "jobstories"
        case .favorites: return "topstories" // Fallback to topstories since favorites are handled locally
        }
    }
}

// Algolia Search Response Models
struct AlgoliaSearchResponse: Codable {
    let hits: [AlgoliaHit]
}

struct AlgoliaHit: Codable {
    let objectID: String
    let title: String?
    let url: String?
    let author: String
    let points: Int?
    let num_comments: Int?
    let created_at_i: TimeInterval
    let children: [Int]?
    let story_text: String?
    
    func toStory() -> Story {
        Story(
            id: Int(objectID) ?? 0,
            title: title ?? "[No Title]",
            url: url,
            by: author,
            score: points ?? 0,
            timestamp: Date(timeIntervalSince1970: created_at_i),
            commentCount: num_comments ?? 0,
            kids: children ?? [], // Map children array to kids
            story_text: story_text
        )
    }
}

actor HNService {
    static let shared = HNService()
    private let baseURL = "https://hacker-news.firebaseio.com/v0"
    private let algoliaURL = "https://hn.algolia.com/api/v1"
    
    // Cache structure
    private struct StoryCacheEntry {
        let stories: [Story]
        let timestamp: Date
    }
    
    private struct CommentCacheEntry {
        let comment: Comment
        let timestamp: Date
    }
    
    private var storyCache: [StoryType: StoryCacheEntry] = [:]
    private var commentCache: [Int: CommentCacheEntry] = [:]
    private let cacheValidityDuration: TimeInterval = 300 // 5 minutes
    private let commentsPerPage = 20
    private let maxConcurrentRequests = 20
    
    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
//        print("[DEBUG] Fetching URL: \(url.absoluteString)")
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Print response data for debugging
        if url.absoluteString.contains("algolia") {
            print("[DEBUG] Response data: \(String(data: data, encoding: .utf8) ?? "nil")")
        }
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[DEBUG] Decoding error: \(error)")
            throw error
        }
    }
    
    func searchStories(query: String) async throws -> [Story] {
        guard !query.isEmpty else { return [] }
        
        print("[DEBUG] Original query: \(query)")
        
        // Create URL components to handle encoding properly
        var components = URLComponents(string: "\(algoliaURL)/search")!
        
        // Format query - wrap multi-word queries in quotes
        let formattedQuery = query.contains(" ") ? "\"\(query)\"" : query
        print("[DEBUG] Formatted query: \(formattedQuery)")
        
        // Add query parameters
        components.queryItems = [
            URLQueryItem(name: "query", value: formattedQuery),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "numericFilters", value: "num_comments>5"),
            URLQueryItem(name: "hitsPerPage", value: "50")
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        print("[DEBUG] Final search URL: \(url.absoluteString)")
        
        let searchResponse: AlgoliaSearchResponse = try await fetch(url)
        print("[DEBUG] Number of hits: \(searchResponse.hits.count)")
        
        // For each search result, fetch the full story from the HN API
        return try await withThrowingTaskGroup(of: Story?.self) { group in
            var stories: [Story] = []
            
            for hit in searchResponse.hits {
                if let id = Int(hit.objectID) {
                    group.addTask {
                        try await self.fetchStory(id: id)
                    }
                }
            }
            
            for try await story in group {
                if let story = story {
                    stories.append(story)
                }
            }
            
            print("[DEBUG] Final number of stories: \(stories.count)")
            
            // Sort by points and then by number of comments
            return stories.sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return ($0.commentCount ?? 0) > ($1.commentCount ?? 0)
            }
        }
    }
    
    private func fetchStoryIds(type: StoryType) async throws -> [Int] {
        let url = URL(string: "\(baseURL)/\(type.endpoint).json")!
        return try await fetch(url)
    }
    
    private func fetchStory(id: Int) async throws -> Story? {
        let url = URL(string: "\(baseURL)/item/\(id).json")!
        do {
            let response: StoryResponse = try await fetch(url)
            return response.toStory()
        } catch {
            // Log the error but don't crash - return nil for failed stories
            print("Failed to fetch story \(id): \(error)")
            return nil
        }
    }
    
    private func fetchComment(id: Int, level: Int, forceFresh: Bool = false) async throws -> Comment {
        // Check cache first if not forcing fresh data
        if !forceFresh, let cached = commentCache[id],
           Date().timeIntervalSince(cached.timestamp) < cacheValidityDuration {
            return cached.comment
        }
        
        let url = URL(string: "\(baseURL)/item/\(id).json")!
        let response: CommentResponse = try await fetch(url)
        let comment = response.toComment(level: level)
        
        // Cache the comment
        commentCache[id] = CommentCacheEntry(comment: comment, timestamp: Date())
        return comment
    }
    
    private func isStoryCacheValid(for type: StoryType) -> Bool {
        guard let entry = storyCache[type] else { return false }
        let age = Date().timeIntervalSince(entry.timestamp)
        return age < cacheValidityDuration
    }
    
    func invalidateStoryCache(for type: StoryType) {
        storyCache.removeValue(forKey: type)
    }
    
    func invalidateCommentCache(for storyId: Int) {
        // Clear the entire comment cache when switching stories
        // This ensures we fetch fresh comments for the new story
        commentCache.removeAll()
    }
    
    func fetchStories(type: StoryType, limit: Int = 100, forceFresh: Bool = false) async throws -> [Story] {
        // For favorites, we don't need to fetch from the API
        if type == .favorites {
            return []  // StoriesViewModel will handle loading favorites from SwiftData
        }
        
        // Check cache if not forcing fresh data
        if !forceFresh, isStoryCacheValid(for: type) {
            return storyCache[type]?.stories ?? []
        }
        
        // Fetch fresh data
        let ids = try await fetchStoryIds(type: type)
        let limitedIds = Array(ids.prefix(limit))
        
        let stories = try await withThrowingTaskGroup(of: Story?.self) { group in
            var storiesDict: [Int: Story] = [:] // Use dictionary to maintain order
            
            // Limit concurrent requests
            var processedIds = 0
            while processedIds < limitedIds.count {
                let batchEnd = min(processedIds + maxConcurrentRequests, limitedIds.count)
                let currentBatch = limitedIds[processedIds..<batchEnd]
                
                for id in currentBatch {
                    group.addTask {
                        try await self.fetchStory(id: id)
                    }
                }
                
                for try await story in group {
                    if let story = story {
                        storiesDict[story.id] = story
                    }
                }
                
                processedIds = batchEnd
            }
            
            // For top, ask, and show stories, maintain the original order from the API
            if type == .top || type == .ask || type == .show {
                return limitedIds.compactMap { storiesDict[$0] }
            } else {
                // For other types, sort by score as before
                return storiesDict.values.sorted { $0.score > $1.score }
            }
        }
        
        // Update cache
        storyCache[type] = StoryCacheEntry(stories: stories, timestamp: Date())
        
        return stories
    }
    
    func fetchComments(for story: Story, page: Int = 0, forceFresh: Bool = false) async throws -> [Comment] {
        guard let commentIds = story.kids, !commentIds.isEmpty else {
            return []
        }
        
        // Calculate page range
        let startIndex = page * commentsPerPage
        guard startIndex < commentIds.count else {
            return []
        }
        
        let endIndex = min(startIndex + commentsPerPage, commentIds.count)
        let pageIds = Array(commentIds[startIndex..<endIndex])
        
        // Fetch comments for current page
        return try await withThrowingTaskGroup(of: Comment.self) { group in
            var commentsDict: [Int: Comment] = [:]
            
            for id in pageIds {
                group.addTask {
                    try await self.fetchComment(id: id, level: 0, forceFresh: forceFresh)
                }
            }
            
            for try await comment in group {
                // Skip deleted/dead comments unless they have children
                if !comment.kids.isEmpty || (!comment.isDeleted && !comment.isDead) {
                    commentsDict[comment.id] = comment
                }
            }
            
            // Return comments in the same order as the API's kids array
            return pageIds.compactMap { commentsDict[$0] }
        }
    }
    
    func fetchChildComments(for comment: Comment) async throws -> [Comment] {
        guard !comment.kids.isEmpty else {
            return []
        }
        
        return try await withThrowingTaskGroup(of: Comment.self) { group in
            var commentsDict: [Int: Comment] = [:]
            
            for id in comment.kids {
                group.addTask {
                    try await self.fetchComment(id: id, level: comment.level + 1)
                }
            }
            
            for try await childComment in group {
                // Skip deleted/dead comments unless they have children
                if !childComment.kids.isEmpty || (!childComment.isDeleted && !childComment.isDead) {
                    commentsDict[childComment.id] = childComment
                }
            }
            
            // Return child comments in the same order as the API's kids array
            return comment.kids.compactMap { commentsDict[$0] }
        }
    }
}
