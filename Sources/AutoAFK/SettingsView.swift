import SwiftUI

/// SwiftUI settings panel shown in a small window from the menu bar.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: AFKController

    var onConnect: () -> Void
    var onDisconnect: () -> Void
    var onQuit: () -> Void

    @State private var launchAtLogin: Bool = LoginItem.isEnabled

    private let commonEmojis = [
        ":zzz:", ":coffee:", ":no_entry:", ":spiral_calendar_pad:",
        ":house:", ":bus:", ":palm_tree:", ":sleeping:", ":lock:", ":walking:"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            Toggle("Enable auto AFK on lock", isOn: $settings.enabled)
                .toggleStyle(.switch)

            workspacesSection

            VStack(alignment: .leading, spacing: 6) {
                Text("AFK message").font(.subheadline).foregroundStyle(.secondary)
                TextField("Away from keyboard", text: $settings.message)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Emoji").font(.subheadline).foregroundStyle(.secondary)
                TextField(":zzz:", text: $settings.emoji)
                    .textFieldStyle(.roundedBorder)
                emojiGrid
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Clear status after").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $settings.timerPreset) {
                    ForEach(TimerPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if settings.timerPreset == .custom {
                    HStack {
                        Stepper(value: $settings.customMinutes, in: 1...1440, step: 5) {
                            Text("\(settings.customMinutes) min")
                        }
                    }
                }
                Text("On unlock, the status is cleared immediately — overriding this timer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { newValue in
                    LoginItem.setEnabled(newValue)
                }

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 360)
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Workspaces").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if controller.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", action: onConnect)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if controller.workspaces.isEmpty {
                Text(controller.isImporting
                     ? "Reading your Slack app session…"
                     : "No workspaces found. Open the Slack desktop app, sign in, then Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apply AFK status to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.workspaces) { ws in
                        Toggle(isOn: binding(for: ws.id)) {
                            Text(ws.name)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.selectedWorkspaceIDs.contains(id) },
            set: { isOn in
                if isOn { settings.selectedWorkspaceIDs.insert(id) }
                else { settings.selectedWorkspaceIDs.remove(id) }
            }
        )
    }

    private var footer: some View {
        HStack {
            if controller.isConnected {
                Button("Test AFK") { controller.setAFKNow() }
                Button("Clear") { controller.clearNow() }
            }
            Spacer()
            Button("Quit", action: onQuit)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto AFK Slack").font(.headline)
                statusLine
            }
            Spacer()
            connectButton
        }
    }

    private var appIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon_1024", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var statusLine: some View {
        Group {
            switch controller.status {
            case .disconnected:
                Label("Not connected", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .idle:
                Label(connectedLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .afk:
                Label("AFK active", systemImage: "moon.fill")
                    .foregroundStyle(.orange)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private var connectedLabel: String {
        let selected = settings.selectedWorkspaceIDs
            .intersection(Set(controller.workspaces.map { $0.id })).count
        let total = controller.workspaces.count
        if total > 0 {
            return "Connected · \(selected)/\(total) workspace\(total == 1 ? "" : "s")"
        }
        return "Connected"
    }

    private var connectButton: some View {
        Group {
            if controller.isImporting {
                ProgressView().controlSize(.small)
            } else if controller.isConnected {
                Menu("Connected") {
                    Button("Refresh local session", action: onConnect)
                    Button("Disconnect", action: onDisconnect)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("Use Slack app session", action: onConnect)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emojiGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(commonEmojis, id: \.self) { code in
                Button(action: { settings.emoji = code }) {
                    Text(emojiGlyph(for: code))
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .help(code)
            }
        }
    }

    /// Maps a few common shortcodes to glyphs for the picker preview.
    private func emojiGlyph(for code: String) -> String {
        switch code {
        case ":zzz:": return "💤"
        case ":coffee:": return "☕️"
        case ":no_entry:": return "⛔️"
        case ":spiral_calendar_pad:": return "🗓"
        case ":house:": return "🏠"
        case ":bus:": return "🚌"
        case ":palm_tree:": return "🌴"
        case ":sleeping:": return "😴"
        case ":lock:": return "🔒"
        case ":walking:": return "🚶"
        default: return "🙂"
        }
    }
}
