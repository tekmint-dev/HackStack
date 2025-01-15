import SwiftUI
import SwiftData

struct CommentView: View {
    @ObservedObject var node: CommentNode
    @ObservedObject var viewModel: CommentsViewModel
    @Environment(\.colorScheme) var colorScheme
    
    private var isCollapsed: Bool {
        viewModel.collapsedComments.contains(node.id)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Comment header
            commentHeader
            
            // Comment content - only visible when not collapsed
            if !isCollapsed {
                commentContent
                
                // Child comments
                if !node.comment.kids.isEmpty {
                    childComments
                }
            }
        }
        .padding(.vertical, 8)
        .id(node.id)
    }
    
    private var commentHeader: some View {
        HStack(spacing: 8) {
            if !node.comment.kids.isEmpty {
                Button {
                    Task {
                        await viewModel.toggleComment(node.id)
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Text(node.comment.by)
                .font(.system(.callout))
                .foregroundStyle(.secondary)
            
            Text(node.comment.relativeTime)
                .font(.system(.callout))
                .foregroundStyle(.secondary)
            
            if isCollapsed {
                Text("[\(node.comment.kids.count) replies]")
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var commentContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.comment.isDeleted {
                Text("[deleted]")
                    .foregroundStyle(.secondary)
                    .italic()
            } else if node.comment.isDead {
                Text("[dead]")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(node.comment.parsedText)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .tint(colorScheme == .dark ? .gray : .secondary)
            }
            
            if let error = node.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(.callout))
            }
        }
    }
    
    @ViewBuilder
    private var childComments: some View {
        if !node.hasLoadedChildren {
            ProgressView()
                .padding(.leading, 16)
                .task {
                    await viewModel.loadChildren(for: node)
                }
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(node.children) { childNode in
                    CommentView(
                        node: childNode,
                        viewModel: viewModel
                    )
                    .padding(.leading, 16)
                }
            }
        }
    }
}

//struct CommentPreview: View {
//    var body: some View {
//        NavigationView {
//            let config = ModelConfiguration(isStoredInMemoryOnly: true)
//            let container = try! ModelContainer(for: Story.self, Comment.self, configurations: config)
//            let modelContext = container.mainContext
//            
//            let story = Story(
//                id: 1,
//                title: "Test Story",
//                url: "https://example.com",
//                by: "testuser",
//                score: 100,
//                timestamp: Date(),
//                commentCount: 1
//            )
//            
//            modelContext.insert(story)
//            
//            let comment = Comment(
//                id: 1,
//                by: "commenter",
//                text: "Test comment with some <b>HTML</b> formatting",
//                timestamp: Date(),
//                kids: [],
//                parent: story.id,
//                isDeleted: false,
//                isDead: false
//            )
//            
//            let node = CommentNode(comment: comment)
//            let viewModel = CommentsViewModel(story: story, modelContext: modelContext)
//            
//            CommentView(node: node, viewModel: viewModel)
//                .frame(width: 400)
//                .padding()
//                .modelContainer(container)
//        }
//    }
//}
//
//#Preview {
//    CommentPreview()
//}
