import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Account") {
                if let label = model.accountLabel {
                    LabeledContent("Signed in as", value: label)
                    HStack {
                        if model.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the browser…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { model.cancelSignIn() }
                        } else {
                            Spacer()
                            if model.needsSignIn {
                                Button("Sign in again") { Task { await model.signInAgain() } }
                                    .keyboardShortcut(.defaultAction)
                            }
                            Button("Sign out") { Task { await model.signOut() } }
                        }
                    }
                } else {
                    TextField("Server", text: $model.serverURL, prompt: Text("https://cloud.example.com"))
                        .disabled(model.isSigningIn)
                    HStack {
                        if model.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the browser…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { model.cancelSignIn() }
                        } else {
                            Spacer()
                            Button("Sign in with browser") { Task { await model.signIn(server: model.serverURL) } }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if !model.preservedURLs.isEmpty {
                Section("Unsynced files kept") {
                    Text("Removing a space kept local changes that had not reached the server.")
                        .foregroundStyle(.secondary)
                    ForEach(model.preservedURLs, id: \.self) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Show in Finder") { model.showPreserved(url) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Dismiss") { model.dismissPreserved() }
                    }
                }
            }
            Section("General") {
                Toggle("Start Stratus at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    Text("Allow Stratus in System Settings, General, Login Items.").foregroundStyle(.secondary)
                }
                Text("Changes made on the server reach Finder only while Stratus is running.")
                    .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("OIDC client ID", text: $model.clientId)
                    .disabled(model.account != nil || model.isSigningIn)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshLoginItem() }
    }
}
