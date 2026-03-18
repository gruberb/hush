import SwiftUI

@main
struct HushApp: App {
    @State private var viewModel = AppListViewModel()

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: viewModel.anyMuted ? "speaker.slash" : "speaker.wave.2") {
            MenuContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
