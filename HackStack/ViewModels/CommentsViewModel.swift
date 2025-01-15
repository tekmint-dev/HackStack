import Foundation
import SwiftUI
import SwiftData

@MainActor
class CommentsViewModel: ObservableObject {
    private var story: Story
    private let service: HNService
    private var modelContext: ModelContext
    
    // Published properties for UI updates
    @Published private(set) var commentTree: [CommentNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var collapsedComments: Set<Int> = []
    
    // State tracking
    private var loadedCommentIds: Set<Int> = []
    private var isFetchingMore = false
    private var currentPage = 0
    private let pageSize = 30
    
    // Throttling and limits
    private var lastLoadTime: Date = .distantPast
    private let loadThrottleInterval: TimeInterval = 0.5 // Minimum time between loads
    private let maxCommentsToLoad = 300 // Maximum number of top-level comments to load
    private let commentCacheValidityDuration: TimeInterval = 86400 // 24 hours cache validity
    
    // Reply loading queue
    private var replyLoadingQueue: [(CommentNode, Int, @MainActor () -> Void)] = [] // node, retryCount, completion
    private var isProcessingQueue = false
    private let maxConcurrentReplies = 2
    private var activeReplyLoads = 0
    private let maxRetries = 2
    private let retryDelay: TimeInterval = 1.0
    
    init(story: Story, service: HNService = .shared, modelContext: ModelContext) {
        self.story = story
        self.service = service
        self.modelContext = modelContext
    }
    
    // MARK: - Public Methods
    
    func updateModelContext(_ newContext: ModelContext) {
        self.modelContext = newContext
    }
    
    func updateStory(_ newStory: Story) {
        // Only update if it's a different story
        guard newStory.id != story.id else { return }
        story = newStory
        Task {
            await resetAndLoad()
        }
    }
    
    func loadInitialComments(loadAll: Bool = false) async {
        await resetAndLoad(loadAll: loadAll)
    }
    
    func loadMoreComments() async {
        // Check throttling and limits
        guard !isLoading, !isFetchingMore, hasMoreComments,
              Date().timeIntervalSince(lastLoadTime) >= loadThrottleInterval,
              loadedCommentIds.count < maxCommentsToLoad else {
            return
        }
        
        isFetchingMore = true
        lastLoadTime = Date()
        await fetchComments(page: currentPage)
        isFetchingMore = false
    }
    
    func refreshComments() async {
        await resetAndLoad(forceFresh: true)
    }
    
    func toggleComment(_ id: Int) async {
        if collapsedComments.contains(id) {
            collapsedComments.remove(id)
            // Load children if not already loaded
            if let node = findNode(id: id), !node.hasLoadedChildren {
                await enqueueReplyLoading(for: node)
            }
        } else {
            collapsedComments.insert(id)
        }
    }
    
    // Changed to non-throwing public method
    func loadChildren(for node: CommentNode) async {
        await enqueueReplyLoading(for: node)
    }
    
    private func enqueueReplyLoading(for node: CommentNode, retryCount: Int = 0) async {
        guard !node.hasLoadedChildren, !node.isLoadingReplies else { return }
        
        node.isLoadingReplies = true
        node.error = nil // Clear any previous error
        
        replyLoadingQueue.append((node, retryCount, {
            node.isLoadingReplies = false
        }))
        
        if !isProcessingQueue {
            await processReplyQueue()
        }
    }
    
    private func processReplyQueue() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        
        while !replyLoadingQueue.isEmpty {
            while activeReplyLoads < maxConcurrentReplies, !replyLoadingQueue.isEmpty {
                let (node, retryCount, completion) = replyLoadingQueue.removeFirst()
                activeReplyLoads += 1
                
                do {
                    try await loadChildrenInternal(for: node)
                    activeReplyLoads -= 1
                    completion()
                    
                    if activeReplyLoads < maxConcurrentReplies {
                        await processReplyQueue()
                    }
                } catch {
                    activeReplyLoads -= 1
                    
                    // Handle retry logic
                    if retryCount < maxRetries {
                        print("Retrying load for comment \(node.id), attempt \(retryCount + 1)")
                        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        await enqueueReplyLoading(for: node, retryCount: retryCount + 1)
                    } else {
                        node.error = "Failed to load replies"
                        node.isLoadingReplies = false
                        completion()
                    }
                    
                    if activeReplyLoads < maxConcurrentReplies {
                        await processReplyQueue()
                    }
                }
            }
            
            if activeReplyLoads >= maxConcurrentReplies {
                break
            }
        }
        
        isProcessingQueue = false
    }
    
    // Internal throwing version
    private func loadChildrenInternal(for node: CommentNode) async throws {
        guard !node.hasLoadedChildren else { return }
        
        print("[DEBUG] 🔍 Checking cache for \(node.comment.kids.count) child comments of comment \(node.id)")
        
        // Try to load children from cache first
        let cachedChildren = try await loadCachedComments(ids: node.comment.kids)
        let missingIds = Set(node.comment.kids).subtracting(cachedChildren.map(\.id))
        
        if !cachedChildren.isEmpty {
            print("[DEBUG] ✅ Found \(cachedChildren.count) comments in cache for comment \(node.id)")
        }
        
        var allChildren = cachedChildren
        
        // Fetch only missing comments from API
        if !missingIds.isEmpty {
            print("[DEBUG] 🌐 Fetching \(missingIds.count) missing comments from API for comment \(node.id)")
            let children = try await service.fetchChildComments(for: node.comment)
            
            // Insert new comments into SwiftData
            for comment in children {
                modelContext.insert(comment)
                if !cachedChildren.contains(where: { $0.id == comment.id }) {
                    allChildren.append(comment)
                }
            }
            
            try modelContext.save()
            print("[DEBUG] 💾 Saved \(children.count) new comments to disk cache")
        }
        
        // Create nodes for child comments
        let childNodes = allChildren.map { CommentNode(comment: $0) }
        
        // Set parent-child relationships
        for childNode in childNodes {
            childNode.parent = node
        }
        
        // Update node
        node.children = childNodes
        node.hasLoadedChildren = true
        
        // Update loaded IDs
        loadedCommentIds.formUnion(allChildren.map(\.id))
        
        // Automatically enqueue loading for immediate children with replies
        for childNode in childNodes where !childNode.comment.kids.isEmpty {
            await enqueueReplyLoading(for: childNode)
        }
    }
    
    // MARK: - Private Methods
    
    public var hasMoreComments: Bool {
        guard let commentIds = story.kids,
              !commentIds.isEmpty,
              currentPage * pageSize < commentIds.count else {
            return false
        }
        return loadedCommentIds.count < min(commentIds.count, maxCommentsToLoad)
    }
    
    private func resetAndLoad(forceFresh: Bool = false, loadAll: Bool = false) async {
        isLoading = true
        error = nil
        commentTree = []
        loadedCommentIds = []
        currentPage = 0
        collapsedComments = []
        replyLoadingQueue = []
        activeReplyLoads = 0
        isProcessingQueue = false
        lastLoadTime = .distantPast
        
        print("[DEBUG] 🔄 Resetting comments view. Force fresh: \(forceFresh)")
        
        // Only clear comments if forcing fresh data
        if forceFresh {
            print("[DEBUG] 🗑️ Clearing existing comments from cache")
            await clearExistingComments()
            await service.invalidateCommentCache(for: story.id)
        }
        
        // Check if story has any comments before attempting to load
        guard let commentCount = story.kids?.count, commentCount > 0 else {
            print("[DEBUG] ℹ️ Story has no comments to load")
            isLoading = false
            return
        }
        
        if loadAll {
            print("[DEBUG] 📥 Loading all comments")
            // Load all comments at once
            while hasMoreComments {
                await fetchComments(page: currentPage, forceFresh: forceFresh)
            }
        } else {
            print("[DEBUG] 📥 Loading first page of comments")
            // Load just the first page
            await fetchComments(page: 0, forceFresh: forceFresh)
        }
        
        isLoading = false
    }
    
    private func clearExistingComments() async {
        do {
            // Delete all existing comments
            let descriptor = FetchDescriptor<Comment>()
            let existingComments = try modelContext.fetch(descriptor)
            print("[DEBUG] 🗑️ Deleting \(existingComments.count) comments from disk cache")
            existingComments.forEach { modelContext.delete($0) }
            try modelContext.save()
        } catch {
            print("Failed to clear existing comments: \(error)")
        }
    }
    
    private func loadCachedComments(ids: [Int]) async throws -> [Comment] {
        print("[DEBUG] 🔍 Checking disk cache for \(ids.count) comments")
        
        let descriptor = FetchDescriptor<Comment>(
            predicate: #Predicate<Comment> { comment in
                ids.contains(comment.id)
            }
        )
        
        let cachedComments = try modelContext.fetch(descriptor)
        
        // Filter out stale cached comments
        let validComments = cachedComments.filter { comment in
            let age = Date().timeIntervalSince(comment.timestamp)
            return age < commentCacheValidityDuration
        }
        
        let staleCount = cachedComments.count - validComments.count
        if staleCount > 0 {
            print("[DEBUG] ⏰ Found \(staleCount) stale comments in cache (older than 24h)")
        }
        
        print("[DEBUG] 💿 Found \(validComments.count) valid comments in disk cache")
        return validComments
    }
    
    private func fetchComments(page: Int, forceFresh: Bool = false) async {
        do {
            var commentsToAdd: [Comment] = []
            
            if !forceFresh {
                // Try to load from cache first
                guard let commentIds = story.kids else {
                    print("[DEBUG] ℹ️ Story has no comments")
                    return
                }
                
                let startIndex = page * pageSize
                // Check if we have any comments to load for this page
                guard startIndex < commentIds.count else {
                    print("[DEBUG] ℹ️ No more comments to load (page \(page) exceeds available comments)")
                    return
                }
                
                let endIndex = min(startIndex + pageSize, commentIds.count)
                print("[DEBUG] 📄 Loading comments page \(page) (indices \(startIndex)..<\(endIndex))")
                let pageIds = Array(commentIds[startIndex..<endIndex])
                
                print("[DEBUG] 🔍 Checking cache for page \(page) (\(pageIds.count) comments)")
                let cachedComments = try await loadCachedComments(ids: pageIds)
                let missingIds = Set(pageIds).subtracting(cachedComments.map(\.id))
                
                commentsToAdd.append(contentsOf: cachedComments)
                
                // Only fetch missing comments from API
                if !missingIds.isEmpty {
                    print("[DEBUG] 🌐 Fetching \(missingIds.count) missing comments from API")
                    let newComments = try await service.fetchComments(for: story, page: page, forceFresh: true)
                    for comment in newComments {
                        if !cachedComments.contains(where: { $0.id == comment.id }) {
                            commentsToAdd.append(comment)
                            modelContext.insert(comment)
                        }
                    }
                    print("[DEBUG] 💾 Saved \(newComments.count) new comments to disk cache")
                }
            } else {
                print("[DEBUG] 🌐 Fetching fresh comments from API for page \(page)")
                // Fetch all comments fresh from API
                let newComments = try await service.fetchComments(for: story, page: page, forceFresh: true)
                commentsToAdd.append(contentsOf: newComments)
                
                // Insert new comments
                for comment in newComments {
                    modelContext.insert(comment)
                }
                print("[DEBUG] 💾 Saved \(newComments.count) fresh comments to disk cache")
            }
            
            try modelContext.save()
            
            // Create nodes for top-level comments
            let nodes = commentsToAdd.map { CommentNode(comment: $0) }
            
            // Update state
            commentTree.append(contentsOf: nodes)
            loadedCommentIds.formUnion(commentsToAdd.map(\.id))
            currentPage += 1
            error = nil
            
            print("[DEBUG] 🌳 Added \(nodes.count) comments to tree (total: \(commentTree.count))")
            
            // Automatically load children for each new node
            for node in nodes where !node.comment.kids.isEmpty {
                await enqueueReplyLoading(for: node)
            }
        } catch {
            print("Failed to load comments: \(error)")
            self.error = "Failed to load comments: \(error.localizedDescription)"
        }
    }
    
    private func findNode(id: Int) -> CommentNode? {
        func search(in nodes: [CommentNode]) -> CommentNode? {
            for node in nodes {
                if node.comment.id == id {
                    return node
                }
                if let found = search(in: node.children) {
                    return found
                }
            }
            return nil
        }
        
        return search(in: commentTree)
    }
}

// MARK: - Comment Node

class CommentNode: Identifiable, ObservableObject {
    let id: Int
    let comment: Comment
    weak var parent: CommentNode?
    @Published var children: [CommentNode]
    @Published var hasLoadedChildren: Bool
    @Published var error: String?
    @Published var isLoadingReplies: Bool = false
    
    init(comment: Comment) {
        self.id = comment.id
        self.comment = comment
        self.children = []
        self.hasLoadedChildren = false
    }
}
