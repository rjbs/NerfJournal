import SwiftUI

@main
struct NerfJournalApp: App {
    @StateObject private var store = LocalJournalStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environmentObject(store)
        }
        .defaultSize(width: 420, height: 640)
    }
}
