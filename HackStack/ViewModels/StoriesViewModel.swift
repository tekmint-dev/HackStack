import Foundation
import SwiftUI
import SwiftData

enum StorySortType {
    case `default` // Preserves API order for top stories
    case date
    case points
    case favorites // New sort type for favorites
}

class StoriesViewModel: ObservableObject {
    private let service = HNService.shared
    private var modelContext: ModelContext
    private var originalStories: [Story] = [] // Store original order
    private var searchTask: Task<Void, Never>?
    private var readStates: Set<Int> = []
    
    @Published var stories: [Story] = []
    @Published var searchText: String = "" {
        didSet {
            print("[DEBUG] Search text changed to: '\(searchText)'")
        }
    }
    @Published var selectedType: StoryType = .top {
        didSet {
            if oldValue != selectedType {
                // Move state updates to next run loop
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Only clear search when not switching to search type
                    if selectedType != .search {
                        self.searchText = ""
                        // Set default sort type based on story type
                        self.sortType = self.defaultSortType(for: self.selectedType)
                        // Only fetch stories for non-search types
                        Task { await self.fetchStories() }
                    }
                }
            }
        }
    }
    @Published var sortType: StorySortType = .default {
        didSet {
            // Move state updates to next run loop
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.sortType == .default && self.selectedType == .top {
                    // Restore original order for top stories
                    self.stories = self.originalStories
                } else if self.sortType == .favorites {
                    self.loadFavorites()
                } else {
                    self.sortStories()
                }
            }
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // Set initial sort type based on default story type (.top)
        sortType = defaultSortType(for: .top)
        loadReadStates()
    }
    
    private func loadReadStates() {
        do {
            let descriptor = FetchDescriptor<ReadState>()
            let states = try modelContext.fetch(descriptor)
            readStates = Set(states.map(\.storyId))
        } catch {
            print("Failed to load read states: \(error)")
        }
    }
    
    func updateModelContext(_ newContext: ModelContext) {
        self.modelContext = newContext
        loadReadStates()
    }
    
    func markAsRead(_ story: Story) {
        // Only create a new ReadState if we haven't seen this story before
        if !readStates.contains(story.id) {
            let readState = ReadState(storyId: story.id)
            modelContext.insert(readState)
            readStates.insert(story.id)
            
            do {
                try modelContext.save()
            } catch {
                print("Failed to save read state: \(error)")
            }
        }
        
        // Set the story's isRead property for UI purposes
        story.isRead = true
    }
    
    @MainActor
    func performSearch() async {
        print("[DEBUG] Starting search with text: '\(searchText)'")
        
        // Cancel any existing search task
        searchTask?.cancel()
        
        // Create a new search task
        searchTask = Task { @MainActor in
            do {
                if !searchText.isEmpty {
                    // Show loading state
                    isLoading = true
                    errorMessage = nil
                    
                    print("[DEBUG] Fetching existing stories from model context")
                    // First, fetch existing stories to preserve their states
                    let descriptor = FetchDescriptor<Story>()
                    let existingStories = try modelContext.fetch(descriptor)
                    let existingStoryMap = Dictionary(uniqueKeysWithValues: existingStories.map { ($0.id, $0) })
                    print("[DEBUG] Found \(existingStories.count) existing stories")
                    
                    // Perform search
                    print("[DEBUG] Calling service.searchStories")
                    let searchResults = try await service.searchStories(query: searchText)
                    print("[DEBUG] Received \(searchResults.count) search results")
                    
                    // Create or update stories while preserving favorite and read status
                    var updatedStories: [Story] = []
                    for story in searchResults {
                        if let existing = existingStoryMap[story.id] {
                            // Update existing story while preserving favorite status
                            existing.title = story.title
                            existing.url = story.url
                            existing.by = story.by
                            existing.score = story.score
                            existing.timestamp = story.timestamp
                            existing.relativeTime = story.relativeTime
                            existing.commentCount = story.commentCount
                            existing.kids = story.kids
                            // Only preserve isFavorite, isRead comes from ReadState
                            existing.isRead = readStates.contains(existing.id)
                            updatedStories.append(existing)
                        } else {
                            // Insert new story
                            story.isRead = readStates.contains(story.id)
                            modelContext.insert(story)
                            updatedStories.append(story)
                        }
                    }
                    
                    try modelContext.save()
                    print("[DEBUG] Saved \(updatedStories.count) stories to model context")
                    
                    stories = updatedStories
                    selectedType = .search
                    sortStories()
                    print("[DEBUG] Updated stories array with \(stories.count) items")
                } else {
                    print("[DEBUG] Empty search text, restoring original stories")
                    // If search is cleared, restore original stories
                    if sortType == .default && selectedType == .top {
                        stories = originalStories
                    } else {
                        stories = originalStories
                        sortStories()
                    }
                }
            } catch {
                if !error.isCancellationError {
                    print("[DEBUG] Search error: \(error)")
                    errorMessage = "Search failed: \(error.localizedDescription)"
                }
            }
            
            isLoading = false
        }
    }
    
    private func defaultSortType(for storyType: StoryType) -> StorySortType {
        switch storyType {
        case .search:
            return .default
        case .top:
            return .default // Use API order
        case .best:
            return .points
        case .new:
            return .date
        case .ask, .show:
            return .default
        case .job:
            return .date
        case .favorites:
            return .default // Use default sort for favorites
        }
    }
    
    private func sortStories() {
        switch sortType {
        case .default:
            if selectedType == .favorites {
                // For favorites, sort by most recently favorited first
                stories.sort { $0.timestamp > $1.timestamp }
            }
        case .date:
            stories.sort { $0.timestamp > $1.timestamp }
        case .points:
            stories.sort { $0.score > $1.score }
        case .favorites:
            stories.sort { story1, story2 in
                if story1.isFavorite != story2.isFavorite {
                    return story1.isFavorite && !story2.isFavorite
                }
                return story1.timestamp > story2.timestamp
            }
        }
    }
    
    private func loadFavorites() {
        do {
            let descriptor = FetchDescriptor<Story>(
                predicate: #Predicate<Story> { story in
                    story.isFavorite == true
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            let fetchedStories = try modelContext.fetch(descriptor)
            DispatchQueue.main.async { [weak self] in
                self?.stories = fetchedStories
            }
        } catch {
            print("Failed to fetch favorites: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.stories = []
            }
        }
    }
    
    @MainActor
    func fetchStories(forceFresh: Bool = false) async {
        // Skip fetching for search type since it uses a different API endpoint
        if selectedType == .search {
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        // If we're in favorites view, just load favorites
        if selectedType == .favorites {
            loadFavorites()
            isLoading = false
            return
        }
        
        do {
            // First, fetch existing stories to preserve their states
            let descriptor = FetchDescriptor<Story>()
            let existingStories = try modelContext.fetch(descriptor)
            let existingStoryMap = Dictionary(uniqueKeysWithValues: existingStories.map { ($0.id, $0) })
            
            // Fetch new stories
            let newStories = try await service.fetchStories(type: selectedType, forceFresh: forceFresh)
            
            // Create or update stories while preserving favorite status
            var updatedStories: [Story] = []
            for story in newStories {
                if let existing = existingStoryMap[story.id] {
                    // Update existing story while preserving favorite status
                    existing.title = story.title
                    existing.url = story.url
                    existing.by = story.by
                    existing.score = story.score
                    existing.timestamp = story.timestamp
                    existing.relativeTime = story.relativeTime
                    existing.commentCount = story.commentCount
                    existing.kids = story.kids
                    // Only preserve isFavorite, isRead comes from ReadState
                    existing.isRead = readStates.contains(existing.id)
                    updatedStories.append(existing)
                } else {
                    // Insert new story
                    story.isRead = readStates.contains(story.id)
                    modelContext.insert(story)
                    updatedStories.append(story)
                }
            }
            
            // Keep favorited stories in the database
            let newIds = Set(newStories.map { $0.id })
            for story in existingStories {
                if !newIds.contains(story.id) && story.isFavorite {
                    updatedStories.append(story)
                }
            }
            
            try modelContext.save()
            
            // Store original order for top stories
            originalStories = updatedStories
            
            // Update view with stories
            if self.sortType == .default && self.selectedType == .top {
                self.stories = updatedStories // Keep original order
            } else {
                self.stories = updatedStories
                self.sortStories()
            }
            
        } catch let error {
            print("Error fetching/updating stories: \(error)")
            errorMessage = "Failed to load stories: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    @MainActor
    func refreshCurrentView() async {
        // Clear search when refreshing
        searchText = ""
        // Invalidate cache for current view
        await service.invalidateStoryCache(for: selectedType)
        // Fetch fresh data
        await fetchStories(forceFresh: true)
    }
    
    func toggleFavorite(_ story: Story) {
        story.isFavorite.toggle()
        do {
            try modelContext.save()
            // Re-sort if we're in favorites view
            if selectedType == .favorites {
                loadFavorites()
            }
        } catch {
            print("Failed to save favorite state: \(error)")
        }
    }
    
    @MainActor
    func cleanup() {
        do {
            // Calculate the cutoff date
            let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
            
            // Remove old comments
            let oldCommentsDescriptor = FetchDescriptor<Comment>(
                predicate: #Predicate<Comment> { comment in
                    comment.timestamp < cutoffDate
                }
            )
            let oldComments = try modelContext.fetch(oldCommentsDescriptor)
            for comment in oldComments {
                modelContext.delete(comment)
            }
            
            try modelContext.save()
        } catch {
            print("Failed to cleanup old data: \(error)")
        }
    }
}

extension Error {
    var isCancellationError: Bool {
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
