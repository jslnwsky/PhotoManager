import SwiftUI
import SwiftData

@main
struct PhotoManagerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Photo.self,
            PhotoThumbnail.self,
            PhotoLocation.self,
            Tag.self,
            Folder.self,
            PhotoTag.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            let storeURL = modelConfiguration.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        let container = sharedModelContainer
        BackupAutomationCoordinator.configure {
            container
        }
        BackupAutomationCoordinator.registerBackgroundTask()
        BackupAutomationCoordinator.scheduleNextIfNeeded()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await BackupAutomationCoordinator.runIfDueInForeground(modelContainer: sharedModelContainer)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    BackupAutomationCoordinator.scheduleNextIfNeeded()
                    Task {
                        await BackupAutomationCoordinator.runIfDueInForeground(modelContainer: sharedModelContainer)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
