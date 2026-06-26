import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let settings = Settings.shared
    private var controller: AFKController!
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only; no Dock icon (also enforced by LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)

        controller = AFKController(settings: settings)

        // Fully local: if we don't already have cached credentials, try to import
        // the existing Slack desktop session (may show a one-time Keychain prompt).
        if !controller.isConnected {
            Task { await controller.useLocalSession() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = icon(for: controller.status)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                controller: controller,
                onConnect: { [weak self] in self?.connectSlack() },
                onDisconnect: { [weak self] in self?.controller.disconnect() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // Keep the menu bar icon in sync with state.
        controller.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.statusItem.button?.image = self?.icon(for: status)
                self?.statusItem.button?.image?.isTemplate = !status.isAttention
            }
            .store(in: &cancellables)
    }

    private func icon(for status: AFKStatus) -> NSImage? {
        let name: String
        let description: String
        switch status {
        case .disconnected:
            name = "moon.zzz"
            description = "Auto AFK (disconnected)"
        case .idle:
            name = "moon.zzz.fill"
            description = "Auto AFK"
        case .afk:
            name = "moon.fill"
            description = "AFK active"
        case .error:
            name = "exclamationmark.triangle.fill"
            description = "Auto AFK error"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            controller.refreshConnectionState()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func connectSlack() {
        Task {
            let ok = await controller.useLocalSession()
            if !ok {
                let alert = NSAlert()
                alert.messageText = "Couldn't read local Slack session"
                alert.informativeText = controller.lastError
                    ?? "Make sure the Slack desktop app is installed and you're signed in."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

private extension AFKStatus {
    /// Whether the icon should be drawn in a non-template (colored) way.
    var isAttention: Bool {
        if case .error = self { return true }
        return false
    }
}
