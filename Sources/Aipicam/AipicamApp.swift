import SwiftUI

@main
struct AipicamApp: App {
    @StateObject private var http = HTTPManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(http)
        }
    }
}
