import SwiftUI
import SwiftData

struct StoryDetailView: View {
    let story: Story
    let viewModel: StoriesViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @StateObject private var commentsViewModel: CommentsViewModel
    @State private var isHoveredBookMark = false
    @State private var isHoveredSafari = false
    @State private var isHoveredRefresh = false
    
    init(story: Story, viewModel: StoriesViewModel) {
        self.story = story
        self.viewModel = viewModel
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Story.self, Comment.self, configurations: config)
            _commentsViewModel = StateObject(wrappedValue: CommentsViewModel(
                story: story,
                modelContext: container.mainContext
            ))
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Sticky story header
            storyHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(NSColor.windowBackgroundColor))
                .background(.thinMaterial)
            
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Story text if available
                    if let storyText = story.story_text {
                        Text(HTMLParser.parseHTML(storyText))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                    }
                    
                    // Comments section
                    CommentsSection(
                        viewModel: commentsViewModel,
                        story: story
                    )
                }
            }
        }
        .onAppear {
            viewModel.markAsRead(story)
        }
        .onChange(of: story.id) { _, _ in
            viewModel.markAsRead(story)
            commentsViewModel.updateStory(story)
        }
        .task {
            commentsViewModel.updateModelContext(modelContext)
            await commentsViewModel.loadInitialComments()
        }
    }
    
    private var storyHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Text(story.title)
                    .font(.title)
                    .lineLimit(2)
                
                Spacer()
                
                Button(action: {
                    viewModel.toggleFavorite(story)
                }) {
                    Image(systemName: story.isFavorite ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(story.isFavorite ? .yellow : .gray)
                        .font(.title2)
                        .scaleEffect(isHoveredBookMark ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveredBookMark = hovering
                    }
                }
                
                if let url = story.url {
                    Link(destination: URL(string: url)!) {
                        Label("Open", systemImage: "safari")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .scaleEffect(isHoveredSafari ? 1.1 : 1.0)
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveredSafari = hovering
                        }
                    }
                }
            }
            .padding(.bottom, 4)
            
            HStack(spacing: 16) {
                Label("\(story.score) points", systemImage: "arrow.up")
                    .foregroundStyle(.orange)
                Label("\(story.commentCount) comments", systemImage: "bubble.left")
                    .foregroundStyle(.blue)
                Button {
                    Task {
                        await commentsViewModel.refreshComments()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")                                
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                )
                .buttonStyle(.plain)
                .disabled(commentsViewModel.isLoading)
                .scaleEffect(isHoveredRefresh ? 1.05 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveredRefresh = hovering
                    }
                }

                if commentsViewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                }

                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Posted by \(story.by)")
                    Text(story.relativeTime)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

// Separate view for comments section
private struct CommentsSection: View {
    @ObservedObject var viewModel: CommentsViewModel
    let story: Story
    @State private var showProgressView = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = viewModel.error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
            
            if viewModel.isLoading && viewModel.commentTree.isEmpty {
                ProgressView("Loading comments...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .opacity(showProgressView ? 1 : 0)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showProgressView = true
                        }
                    }
            } else if viewModel.commentTree.isEmpty && !viewModel.isLoading {
                Text("No comments yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.commentTree) { node in
                        CommentView(
                            node: node,
                            viewModel: viewModel
                        )
                        .padding(.horizontal, 24)
                        
                        Divider()
                            .padding(.horizontal, 24)
                    }
                    
                    if !viewModel.commentTree.isEmpty && viewModel.hasMoreComments {
                        Button(action: {
                            Task {
                                await viewModel.loadMoreComments()
                            }
                        }) {
                            if viewModel.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Load More Comments")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isLoading)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .padding(.vertical, 16)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Story.self, Comment.self, configurations: config)
    let viewModel = StoriesViewModel(modelContext: container.mainContext)
    
    let story = Story(
        id: 1,
        title: "Test Story with a very long title that might need to wrap to multiple lines",
        url: "https://example.com",
        by: "testuser",
        score: 100,
        timestamp: Date(),
        commentCount: 42,
        story_text: """
        This is a test story with <b>bold</b> and <i>italic</i> text.
        <p>It includes paragraphs</p>
        <p>And <a href="https://example.com">links</a> too!</p>
        <pre><code>
        function test() {
            console.log('Hello, World!');
        }
        </code></pre>
        """
    )
    container.mainContext.insert(story)
    
    return StoryDetailView(story: story, viewModel: viewModel)
        .modelContainer(container)
}
