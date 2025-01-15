import SwiftUI
import SwiftData

@main
struct HackStackApp: App {
    let modelContainer: ModelContainer
    
    init() {
        do {
            // Define the schema with version
            let schema = Schema([
                Story.self,
                Comment.self,
                ReadState.self
            ])
            
            // Get the container directory for the app
            let containerURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("dev.tekmint.HackStack", isDirectory: true)
                .appendingPathComponent("data", isDirectory: true)
            
            // Create the directory if it doesn't exist
            if let containerURL = containerURL {
                try FileManager.default.createDirectory(
                    at: containerURL,
                    withIntermediateDirectories: true
                )
            }
            
            // Set up the store URL
            let storeURL = containerURL?.appendingPathComponent("store.sqlite")
            
            // Configure the model container
            let modelConfiguration = ModelConfiguration(
                nil,
                schema: schema,
                url: storeURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("temp.sqlite"),
                allowsSave: true,
                cloudKitDatabase: .none // Disable CloudKit for now
            )
            
            modelContainer = try ModelContainer(
                for: schema,
                configurations: modelConfiguration
            )
        } catch {
            print("Failed to initialize ModelContainer: \(error)")
            
            // Fallback to in-memory store only if we can't access the persistent store
            do {
                let fallbackSchema = Schema([
                    Story.self,
                    Comment.self,
                    ReadState.self
                ])
                let fallbackConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(
                    for: fallbackSchema,
                    configurations: fallbackConfig
                )
            } catch let fallbackError {
                fatalError("Could not create fallback ModelContainer: \(fallbackError)")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(modelContext: modelContainer.mainContext)
        }
        .modelContainer(modelContainer)
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        // .commands {
        //     CommandGroup(after: .textEditing) {
        //         Button("Focus Search") {
        //             NSApp.sendAction(#selector(NSApplication.focusSearch), to: nil, from: nil)
        //         }
        //         .keyboardShortcut("f", modifiers: .command)
        //     }
        // }
    }
}
