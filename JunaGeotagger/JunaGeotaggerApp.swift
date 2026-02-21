import SwiftUI

@main
struct JunaGeotaggerApp: App {
    @State private var viewModel = MainViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
    }
}
