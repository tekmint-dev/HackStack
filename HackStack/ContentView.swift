import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: StoriesViewModel
    @State private var selectedStory: Story?
    @State private var lastCleanupDate: Date = Date()
    
    init(modelContext: ModelContext) {
        _viewModel = StateObject(wrappedValue: StoriesViewModel(modelContext: modelContext))
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $viewModel.selectedType) {
                Section("Stories") {
                    NavigationLink(value: StoryType.top) {
                        Label("Top Stories", systemImage: "flame")
                    }
                    NavigationLink(value: StoryType.new) {
                        Label("New Stories", systemImage: "newspaper")
                    }
                    NavigationLink(value: StoryType.best) {
                        Label("Best Stories", systemImage: "star")
                    }
                }
                
                Section("Categories") {
                    NavigationLink(value: StoryType.ask) {
                        Label("Ask HN", systemImage: "questionmark.circle")
                    }
                    NavigationLink(value: StoryType.show) {
                        Label("Show HN", systemImage: "eye")
                    }
                    NavigationLink(value: StoryType.job) {
                        Label("Jobs", systemImage: "briefcase")
                    }
                }
                
                Section("Personal") {
                    NavigationLink(value: StoryType.favorites) {
                        Label("Saved", systemImage: "bookmark.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            VStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.stories.isEmpty {
                        if viewModel.selectedType == .favorites {
                            Text("No favorites yet")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.selectedType == .search && !viewModel.searchText.isEmpty {
                            VStack(spacing: 12) {
                                Text("No results found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Try different search terms")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        List(selection: $selectedStory) {
                            ForEach(viewModel.stories, id: \.self.id) { story in
                                StoryRowView(story: story, viewModel: viewModel)
                                    .tag(story)
                            }
                        }
                        .background(Color.gray.opacity(0.5))
                    }
            }
            .id(viewModel.selectedType) // Force view recreation when stories change
            .navigationSplitViewColumnWidth(min: 320, ideal: 400)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: {
                        Task {
                            await viewModel.refreshCurrentView()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh stories (invalidates cache)")
                }

                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button {
                            viewModel.sortType = .default
                        } label: {
                            Label("Default Order", systemImage: "list.number")
                                .labelStyle(.titleAndIcon)
                        }
                        
                        Button {
                            viewModel.sortType = .date
                        } label: {
                            Label("Sort by Date", systemImage: "calendar")
                                .labelStyle(.titleAndIcon)
                        }
                        
                        Button {
                            viewModel.sortType = .points
                        } label: {
                            Label("Sort by Points", systemImage: "chart.bar.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    } label: {
                        Label("Sort", systemImage: "line.3.horizontal.decrease")
                    }
                    .help("Sort stories")
                }
                
                ToolbarItem(placement: .automatic) {
                    Spacer()
                }
                
                ToolbarItem(placement: .automatic) {
                    SearchField(
                        text: $viewModel.searchText,
                        placeholder: "Search stories...",
                        onSubmit: {
                            Task {
                                await viewModel.performSearch()
                            }
                        },
                        onClear: {
                            Task {
                                await viewModel.performSearch()
                            }
                        }
                    )
                    .frame(width: 200)
                }
            }
            // no title
            .navigationTitle("")
        } detail: {
            // Story Detail
            if let story = selectedStory {
                StoryDetailView(story: story, viewModel: viewModel)
                    .id(story.id) // Force view recreation when story changes
            } else {
                Text("Select a story")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // Initial data load
            await viewModel.fetchStories()
            
            // Run cleanup only once per day
            let calendar = Calendar.current
            if !calendar.isDate(lastCleanupDate, inSameDayAs: Date()) {
                viewModel.cleanup()
                lastCleanupDate = Date()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Only fetch stories when becoming active
                Task {
                    await viewModel.fetchStories()
                }
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: () -> Void

    @State private var focusedField: Bool = false
        
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            
            TextField(placeholder, text: $text, onEditingChanged: { focused in
                focusedField = focused
            })
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            
            if !text.isEmpty {
                Button(action: {
                    text = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(focusedField ? Color.orange.opacity(0.8) : Color.gray.opacity(0.3), lineWidth: focusedField ? 2 : 0.5)
                }
        }
        .animation(.smooth, value: focusedField)
    }
}

#Preview {
    do {
        let schema = Schema([
            Story.self,
            Comment.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ContentView(modelContext: container.mainContext)
    } catch {
        return Text("Failed to create preview: \(error.localizedDescription)")
    }
}
