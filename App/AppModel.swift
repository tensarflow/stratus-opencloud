import AppKit
import Observation
import os
import ServiceManagement
import StratusKit

@MainActor @Observable
final class AppModel {
    private(set) var account: Account?
    private(set) var drives: [Drive] = []
    /// Spaces whose Finder location is switched off in System Settings.
    private(set) var disabledDrives: Set<String> = []
    private(set) var status = "Not signed in"
    private(set) var lastError: String?
    private(set) var isSigningIn = false
    /// The account exists but its refresh token was rejected: "Sign in again" renews the tokens.
    private(set) var needsSignIn = false
    /// Unsynced local files that removing a domain kept, shown until dismissed.
    private(set) var preservedURLs: [URL] = []
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginNeedsApproval = false

    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var clientId = UserDefaults.standard.string(forKey: "clientId") ?? "OpenCloudDesktop" {
        didSet { UserDefaults.standard.set(clientId, forKey: "clientId") }
    }

    @ObservationIgnored private let log = Logger(subsystem: "com.arteq.stratus", category: "app")
    @ObservationIgnored private var store: AccountStore?
    @ObservationIgnored private var client: OpenCloudClient?
    @ObservationIgnored private var receiver: LoopbackReceiver?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var rootEtags: [String: String] = [:]
    /// The personal space's id, remembered so its domain is never removed automatically, even when
    /// a listing lacks it.
    @ObservationIgnored private var personalDriveId = UserDefaults.standard.string(forKey: "personalDriveId") {
        didSet { UserDefaults.standard.set(personalDriveId, forKey: "personalDriveId") }
    }

    init() {
        do {
            let store = AccountStore(accessGroup: try AppGroup.keychainGroup())
            self.store = store
            account = try store.load()
        } catch {
            fail(error)
        }
        refreshLoginItem()
        if account != nil { startPolling() }
    }

    var accountLabel: String? {
        account.map { "\($0.username)@\($0.serverURL.host() ?? $0.serverURL.absoluteString)" }
    }

    // MARK: Sign in / out

    func signIn(server: String) async {
        guard let store, let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              url.host() != nil else {
            lastError = "Enter the server address, e.g. https://cloud.example.com"
            return
        }
        let clientId = clientId
        await browserSignIn(server: url, clientId: clientId) { tokens, username in
            let account = Account(serverURL: url, username: username, clientId: clientId, tokens: tokens)
            try store.save(account)
            self.account = account
            self.registerLoginItemOnce()
        }
    }

    /// Renews the tokens of the existing account after its refresh token was rejected. The domains
    /// (and so the Finder locations) stay; a sign-in as another user is refused.
    func signInAgain() async {
        guard let store, let account else { return }
        await browserSignIn(server: account.serverURL, clientId: account.clientId) { tokens, username in
            let renewed = try account.reauthenticated(username: username, tokens: tokens)
            try store.save(renewed)
            self.account = renewed
            await DomainManager.signalAll()
        }
    }

    /// The OIDC browser flow; `finish` stores the result. Polling restarts afterwards.
    private func browserSignIn(server: URL, clientId: String,
                               finish: (Tokens, String) async throws -> Void) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        let before = status
        status = "Signing in…"
        let pkce = PKCE(), state = PKCE().verifier
        let receiver = LoopbackReceiver(state: state)
        self.receiver = receiver
        defer {
            receiver.stop()
            self.receiver = nil
            isSigningIn = false
        }
        do {
            let oidc = OIDCClient(serverURL: server, clientId: clientId)
            let config = try await oidc.discover()
            let redirect = try await receiver.start()
            NSWorkspace.shared.open(oidc.authorizeURL(config: config, redirectURI: redirect, pkce: pkce, state: state))
            let reply = try await receiver.callback()
            guard reply["state"] == state else { throw AuthError.stateMismatch }
            guard let code = reply["code"] else { throw AuthError.missingCode }
            let tokens = try await oidc.exchange(code: code, redirectURI: redirect, pkce: pkce, config: config)
            let username = try await OpenCloudClient(baseURL: server, auth: FixedBearer(token: tokens.accessToken)).me()
            try await finish(tokens, username)
            client = nil
            needsSignIn = false
            lastError = nil
            log.info("signed in")
            NSApp.activate()
            startPolling()
        } catch is CancellationError {
            status = before
        } catch {
            fail(error)
            if account == nil { status = "Not signed in" }
        }
    }

    func cancelSignIn() { receiver?.stop() }

    /// Only ever on the user's request: removes every domain (keeping unsynced local edits), then the account.
    func signOut() async {
        pollTask?.cancel()
        pollTask = nil
        do {
            preservedURLs += try await DomainManager.removeAll()
        } catch {
            fail(error)
        }
        do {
            try store?.delete()
        } catch {
            fail(error)
        }
        account = nil
        client = nil
        drives = []
        disabledDrives = []
        rootEtags = [:]
        needsSignIn = false
        status = "Not signed in"
        log.info("signed out")
    }

    func showPreserved(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func dismissPreserved() { preservedURLs = [] }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            fail(error)
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    /// Server changes reach Finder only while the app runs, so the first sign-in turns on launch at
    /// login. Later the toggle in Settings decides.
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemRegistered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemRegistered")
        setLaunchAtLogin(true)
    }

    // MARK: Spaces

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDrives()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Lists the spaces, keeps one domain per personal/project space, and signals a domain whose
    /// root etag moved. Errors only update the status; they never sign out.
    func refreshDrives() async {
        guard let account, let store else { return }
        do {
            let client = try client ?? OpenCloudClient(
                baseURL: account.serverURL,
                auth: OIDCAuthProvider(store: store, lockURL: AppGroup.authLockURL(),
                                       refresher: OIDCAuthProvider.oidcRefresher()))
            self.client = client
            let drives = try await client.drives().filter { $0.type == "personal" || $0.type == "project" }
            guard self.account != nil, !Task.isCancelled else { return }     // signed out meanwhile
            self.drives = drives
            if let personal = drives.first(where: { $0.type == "personal" }) { personalDriveId = personal.id }
            preservedURLs += try await DomainManager.reconcile(drives, keep: Set([personalDriveId].compactMap { $0 })) {
                try await client.driveExists($0)
            }
            // The first value seen after launch counts as a change too: the extension may have
            // missed edits while the app was not running. A disabled domain is signalled again once
            // it is switched on.
            var disabled = await DomainManager.userDisabledIds()
            for drive in drives where !disabled.contains(drive.id) && rootEtags[drive.id] != drive.rootEtag {
                do {
                    try await DomainManager.signalWorkingSet(driveId: drive.id)
                    rootEtags[drive.id] = drive.rootEtag
                } catch where FPErrors.isDomainDisabled(error) {
                    disabled.insert(drive.id)
                } catch {
                    log.error("signal failed: \(ErrorLog.code(error), privacy: .public)")
                }
            }
            disabledDrives = disabled
            needsSignIn = false
            lastError = nil
            status = "Connected"
        } catch {
            if self.account != nil, !Task.isCancelled { fail(error) }
        }
    }

    func showInFinder(_ drive: Drive) {
        Task {
            do {
                if let url = try await DomainManager.rootURL(driveId: drive.id) { NSWorkspace.shared.open(url) }
            } catch {
                fail(error)
            }
        }
    }

    /// System Settings, File Provider extensions (where a location is switched on).
    func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    private func fail(_ error: Error) {
        log.error("\(ErrorLog.code(error), privacy: .public) \(String(describing: error), privacy: .private)")
        switch error {
        case AuthError.signInRequired:
            needsSignIn = true
            status = "Sign in again"
            lastError = "The server ended the session. Click Sign in again."
        case AuthError.accountMismatch:
            lastError = "That browser sign-in was for another user. Sign in as \(account?.username ?? "the same user"), "
                + "or sign out first to switch accounts."
            if needsSignIn { status = "Sign in again" }
        default:
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastError = message
            status = "Error: \(message)"
        }
    }
}

/// The freshly issued access token, for the one `me()` call before the account is saved.
private struct FixedBearer: AuthProvider {
    let token: String
    func authorizationHeader() async throws -> String { "Bearer " + token }
    func refreshAfterUnauthorized() async throws { throw OpenCloudError.unauthorized }
}
