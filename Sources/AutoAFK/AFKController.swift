import AppKit
import Combine

/// High-level connection / activity state, surfaced to the menu bar UI.
enum AFKStatus: Equatable {
    case disconnected
    case idle          // connected, present
    case afk           // connected, status set by us
    case error(String)
}

/// Watches macOS screen lock/unlock events and drives the Slack status across
/// every workspace the user selected:
/// - On lock: set AFK status (message + emoji + timer expiration) on each selected workspace.
/// - On unlock: clear status immediately, overriding any timer (like a manual cancel).
///
/// Only clears a status we actually set, so a manually-set status isn't wiped.
@MainActor
final class AFKController: ObservableObject {
    @Published private(set) var status: AFKStatus = .disconnected
    @Published private(set) var lastError: String?
    /// All workspaces detected from the local Slack desktop session.
    @Published private(set) var workspaces: [SlackWorkspace] = []
    /// True while a local-session import / refresh is running.
    @Published private(set) var isImporting = false

    private let settings: Settings
    private let client: SlackClient
    private let center = DistributedNotificationCenter.default()

    /// Workspaces where THIS app set the AFK status (so we only clear those).
    private var afkWorkspaceIDs: Set<String> = []
    /// The exact text/emoji we applied, used to detect if the user changed it.
    private var appliedText = ""
    private var appliedEmoji = ""
    /// Debounce guard against rapid lock/unlock toggling.
    private var lastEventAt: Date = .distantPast

    init(settings: Settings = .shared, client: SlackClient = SlackClient()) {
        self.settings = settings
        self.client = client
        loadAccount()
        startObserving()
    }

    deinit {
        center.removeObserver(self)
    }

    // MARK: - Connection state

    private func loadAccount() {
        let account = KeychainStore.load()
        workspaces = account?.workspaces ?? []
        refreshConnectionState()
    }

    func refreshConnectionState() {
        if isConnected {
            if case .afk = status { /* keep */ } else { status = .idle }
        } else {
            status = .disconnected
        }
    }

    var isConnected: Bool {
        guard let account = KeychainStore.load() else { return false }
        return !account.workspaces.isEmpty
    }

    /// Workspaces that are both detected and selected by the user.
    private func targetWorkspaces() -> [SlackWorkspace] {
        let selected = settings.selectedWorkspaceIDs
        return workspaces.filter { selected.contains($0.id) }
    }

    // MARK: - Lock / unlock observation

    private func startObserving() {
        center.addObserver(
            self,
            selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func screenLocked() {
        Log.debug("screenIsLocked (enabled=\(settings.enabled), connected=\(isConnected), targets=\(targetWorkspaces().count))")
        guard shouldHandleEvent() else { return }
        handleLock()
    }

    @objc private func screenUnlocked() {
        Log.debug("screenIsUnlocked (connected=\(isConnected), weSet=\(afkWorkspaceIDs.count))")
        guard shouldHandleEvent() else { return }
        handleUnlock()
    }

    /// Returns true if enough time has passed since the last handled event.
    private func shouldHandleEvent() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastEventAt) < 1.0 { return false }
        lastEventAt = now
        return true
    }

    private func handleLock() {
        guard settings.enabled else {
            Log.debug("lock ignored: auto-AFK disabled in settings")
            return
        }
        guard isConnected else {
            Log.debug("lock ignored: not connected to Slack")
            self.status = .error("Connect Slack to enable AFK")
            return
        }
        performSetAFK()
    }

    private func handleUnlock() {
        guard isConnected, !afkWorkspaceIDs.isEmpty else { return }
        performClear()
    }

    // MARK: - Status set / clear (across selected workspaces)

    private func performSetAFK(force: Bool = false) {
        let text = settings.message
        let emoji = settings.normalizedEmoji
        let expiration = settings.currentExpiration()
        let targets = targetWorkspaces()

        guard !targets.isEmpty else {
            Log.debug("no workspaces selected; nothing to do")
            self.status = .error("Pick a workspace in settings")
            return
        }

        guard let cookie = KeychainStore.load()?.cookieHeader else {
            self.status = .error("Not connected")
            return
        }

        Task {
            var firstError: Error?
            var anySuccess = false
            var newlySet: Set<String> = []
            var preserved = false
            for ws in targets {
                // If Slack notifications are snoozed / Do Not Disturb is active on
                // this workspace, don't touch the status at all. (Manual "Test
                // AFK" passes force=true to bypass this.)
                if !force, await client.isDNDActive(token: ws.token, cookie: cookie) {
                    preserved = true
                    Log.debug("snooze/DND active on '\(ws.name)'; not changing status")
                    continue
                }
                // Never clobber a status the user set manually. If a status is
                // already present and it isn't our AFK status, leave it alone.
                // (Manual "Test AFK" passes force=true to override.)
                if !force,
                   let current = try? await client.getStatus(token: ws.token, cookie: cookie),
                   (!current.text.isEmpty || !current.emoji.isEmpty),
                   !(current.text == text && current.emoji == emoji) {
                    preserved = true
                    Log.debug("preserving existing manual status on '\(ws.name)'")
                    continue
                }
                do {
                    try await self.setStatusWithRetry(
                        workspace: ws, cookie: cookie,
                        text: text, emoji: emoji, expiration: expiration)
                    anySuccess = true
                    newlySet.insert(ws.id)
                    Log.debug("AFK set on '\(ws.name)'")
                } catch {
                    firstError = firstError ?? error
                    Log.debug("AFK set failed on '\(ws.name)': \(error.localizedDescription)")
                }
            }
            if anySuccess {
                self.afkWorkspaceIDs = newlySet
                self.appliedText = text
                self.appliedEmoji = emoji
                self.status = .afk
                self.lastError = nil
            } else if preserved {
                // All selected workspaces already had a manual status — respect it.
                self.status = .idle
                self.lastError = nil
            }
            if let error = firstError, !anySuccess {
                self.handle(error)
            }
        }
    }

    private func performClear(force: Bool = false) {
        // Auto-unlock clears only what we set; manual "Clear" clears selection.
        let toClear = force ? targetWorkspaces()
                            : workspaces.filter { afkWorkspaceIDs.contains($0.id) }
        guard let cookie = KeychainStore.load()?.cookieHeader, !toClear.isEmpty else {
            afkWorkspaceIDs = []
            status = .idle
            return
        }

        let setText = appliedText
        let setEmoji = appliedEmoji
        Task {
            for ws in toClear {
                // Only clear if the status is still the one WE set. If the user
                // changed it (e.g. set "Lunch" from their phone), leave it.
                // (Manual "Clear" passes force=true to clear unconditionally.)
                if !force,
                   let current = try? await client.getStatus(token: ws.token, cookie: cookie),
                   !(current.text == setText && current.emoji == setEmoji) {
                    Log.debug("status on '\(ws.name)' changed since lock; leaving it")
                    continue
                }
                do {
                    try await client.clearStatus(token: ws.token, cookie: cookie)
                    Log.debug("status cleared on '\(ws.name)'")
                } catch {
                    Log.debug("clear failed on '\(ws.name)': \(error.localizedDescription)")
                }
            }
            self.afkWorkspaceIDs = []
            self.status = .idle
            self.lastError = nil
        }
    }

    /// Sets the status on a workspace; if its cached token expired, re-imports
    /// the local Slack session once and retries with the refreshed token.
    private func setStatusWithRetry(workspace: SlackWorkspace, cookie: String,
                                    text: String, emoji: String, expiration: Int) async throws {
        do {
            try await client.setStatus(text: text, emoji: emoji, expiration: expiration,
                                       token: workspace.token, cookie: cookie)
        } catch let error as SlackError {
            if case .authExpired = error, await reimportLocalSession() {
                if let refreshed = KeychainStore.load(),
                   let ws = refreshed.workspaces.first(where: { $0.id == workspace.id }) {
                    Log.debug("token expired on '\(workspace.name)'; retrying after re-import")
                    try await client.setStatus(text: text, emoji: emoji, expiration: expiration,
                                               token: ws.token, cookie: refreshed.cookieHeader)
                    return
                }
            }
            throw error
        }
    }

    // MARK: - Manual actions (menu)

    /// Manually trigger an AFK set (used for "Test" from the menu).
    /// Bypasses the enable toggle so it works purely as a connection test.
    func setAFKNow() {
        guard isConnected else {
            self.status = .error("Connect Slack first")
            return
        }
        performSetAFK(force: true)
    }

    /// Manually clear on all selected workspaces.
    func clearNow() {
        guard isConnected else { return }
        performClear(force: true)
    }

    func disconnect() {
        KeychainStore.clear()
        workspaces = []
        afkWorkspaceIDs = []
        status = .disconnected
    }

    // MARK: - Local session import (multi-workspace)

    /// Imports the local Slack desktop session: reads the shared cookie + all
    /// workspace tokens, resolves each via auth.test (which also filters stale
    /// tokens), and stores the result. Returns true if at least one workspace
    /// was imported.
    @discardableResult
    func useLocalSession() async -> Bool {
        isImporting = true
        defer { isImporting = false }
        do {
            let session = try LocalSlackSession.readSession()

            // Build the workspace list directly from the Slack app's own
            // localConfig (id + name + url + token for every signed-in team).
            // This is fully local — no network, no enumeration needed.
            var resolved = session.teams.map {
                SlackWorkspace(id: $0.id, name: $0.name.isEmpty ? "Slack" : $0.name,
                               url: $0.url, token: $0.token)
            }
            Log.debug("localConfig workspaces = \(resolved.map { $0.name })")

            // Fallback: if localConfig yielded no usable identities (e.g. only
            // raw tokens), resolve them over the network via auth.test.
            if resolved.allSatisfy({ $0.name == "Slack" }) {
                var net: [SlackWorkspace] = []
                for ws in resolved {
                    if let info = try? await client.authTest(token: ws.token, cookie: session.cookieHeader),
                       !net.contains(where: { $0.id == info.teamID }) {
                        net.append(SlackWorkspace(id: info.teamID, name: info.team,
                                                  url: info.url, token: ws.token))
                    }
                }
                if !net.isEmpty { resolved = net }
            }

            guard !resolved.isEmpty else {
                let message = "Found Slack tokens but none are valid. Open Slack and sign in, then retry."
                status = .error(message)
                lastError = message
                return false
            }

            resolved.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard KeychainStore.save(SlackAccount(cookieHeader: session.cookieHeader,
                                                  workspaces: resolved)) else {
                let message = "Couldn't save the Slack session to your Keychain."
                status = .error(message)
                lastError = message
                Log.info("local session import failed: keychain save")
                return false
            }
            workspaces = resolved
            applyDefaultSelectionIfNeeded()
            lastError = nil
            refreshConnectionState()
            Log.info("imported \(resolved.count) workspace(s)")
            Log.debug("workspaces: \(resolved.map { $0.name }.joined(separator: ", "))")
            return true
        } catch {
            let message = (error as? LocalSlackSession.ExtractError)?.errorDescription
                ?? error.localizedDescription
            status = .error(message)
            lastError = message
            Log.info("local session import failed: \(message)")
            return false
        }
    }

    /// Keeps only still-valid selected IDs; if none remain selected, selects all.
    private func applyDefaultSelectionIfNeeded() {
        let valid = Set(workspaces.map { $0.id })
        var selection = settings.selectedWorkspaceIDs.intersection(valid)
        if selection.isEmpty {
            selection = valid
        }
        settings.selectedWorkspaceIDs = selection
    }

    @discardableResult
    private func reimportLocalSession() async -> Bool {
        await useLocalSession()
    }

    private func handle(_ error: Error) {
        let message: String
        if let slackError = error as? SlackError {
            message = slackError.errorDescription ?? "Slack error"
            if case .authExpired = slackError {
                self.status = .error("Session expired — refresh from the Slack app")
                self.lastError = message
                return
            }
        } else {
            message = error.localizedDescription
        }
        self.status = .error(message)
        self.lastError = message
    }
}
