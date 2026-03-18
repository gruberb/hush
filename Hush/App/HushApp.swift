import SwiftUI

@main
struct HushApp: App {
    @State private var viewModel = AppListViewModel()

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: viewModel.anyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            MenuContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
