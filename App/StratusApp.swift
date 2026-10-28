import SwiftUI

@main
struct StratusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // The first scene opens at launch; it only exists to open Settings when no account is set
        // up yet (SwiftUI offers `openSettings` to views only), then closes itself.
        Window("Stratus", id: LaunchView.id) {
            LaunchView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Stratus", systemImage: "cloud") {
            MenuContent(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

private struct LaunchView: View {
    static let id = "launch"
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                if model.account == nil {
                    NSApp.activate()
                    openSettings()
                }
                dismissWindow(id: Self.id)
            }
    }
}
