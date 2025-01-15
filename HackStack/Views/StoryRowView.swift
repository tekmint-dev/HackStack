import SwiftUI
import SwiftData

struct StoryRowView: View {
    let story: Story
    let viewModel: StoriesViewModel
    @State private var isHovered = false
    @State private var appearOpacity = 0.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(story.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.toggleFavorite(story)
                    }
                }) {
                    Image(systemName: story.isFavorite ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(story.isFavorite ? .yellow : .gray)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                        
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovered = hovering
                    }
                }
            }
            
            HStack(spacing: 16) {
                Label("\(story.score)", systemImage: "arrow.up")
                    .foregroundStyle(.orange)
                Label("\(story.commentCount)", systemImage: "bubble.left")
                    .foregroundStyle(.blue)
                Text("by \(story.by)")
                    .foregroundStyle(.secondary)
                Text(story.relativeTime)
                    .foregroundStyle(.secondary)
                Spacer()
                if !story.isRead {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)    
                        .padding(.horizontal, 5)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .opacity(appearOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appearOpacity = 1.0
            }
        }
    }
}
