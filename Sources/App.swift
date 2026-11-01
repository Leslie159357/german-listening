import SwiftUI

@main
struct GermanListeningApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .onOpenURL { url in
                    _ = store.handleIncoming(url)
                }
        }
    }
}
