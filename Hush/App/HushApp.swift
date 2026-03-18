import SwiftUI

@main
struct HushApp: App {
    @State private var viewModel = AppListViewModel()

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: viewModel.anyMuted ? "speaker.wave.2" : "speaker.wave.2.fill") {
            MenuContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
