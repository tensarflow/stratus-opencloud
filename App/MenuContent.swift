import SwiftUI
import StratusKit

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.accountLabel ?? "Not signed in")
        if model.needsSignIn {
            Button("Sign in again…") { Task { await model.signInAgain() } }
                .disabled(model.isSigningIn)
        }
        if !model.drives.isEmpty {
            Divider()
            ForEach(model.drives, id: \.id) { drive in
                if model.disabledDrives.contains(drive.id) {
                    Menu("\(DomainManager.displayName(drive)) — turned off") {
                        Button("Turn on in System Settings…") { model.openExtensionSettings() }
                    }
                } else {
                    Menu(DomainManager.displayName(drive)) {
                        Button("Show in Finder") { model.showInFinder(drive) }
                    }
                }
            }
        }
        if let kept = model.preservedURLs.first {
            Divider()
            Button("Show Kept Unsynced Files…") { model.showPreserved(kept) }
        }
        Divider()
        Text(model.status)
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Stratus") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
