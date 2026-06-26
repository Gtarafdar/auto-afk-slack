import Foundation
import Security

/// A single Slack workspace the user is signed into (via the Slack desktop app).
/// All workspaces share the same `d` cookie; each has its own `xoxc` token.
struct SlackWorkspace: Codable, Identifiable, Equatable {
    var id: String            // Slack team id, e.g. T01234567
    var name: String          // human-readable workspace name
    var url: String?          // e.g. https://myteam.slack.com
    var token: String         // xoxc-... token for this workspace
}

/// The full local Slack session: one shared cookie + all detected workspaces.
/// Stored securely in the macOS Keychain. No secrets in UserDefaults/bundle.
struct SlackAccount: Codable, Equatable {
    var cookieHeader: String           // full Cookie header, e.g. "d=...; d-s=..."
    var workspaces: [SlackWorkspace]
}

enum KeychainStore {
    private static let service = "com.autoafk.slack"
    private static let account = "slack-credentials"

    @discardableResult
    static func save(_ slackAccount: SlackAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(slackAccount) else { return false }

        // Remove ALL existing items for this service first (incl. any orphaned
        // entries), then add a fresh one with the correct account attribute.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        attributes[kSecValueData as String] = data
        // ThisDeviceOnly: the session secret never leaves this Mac (no iCloud
        // Keychain sync) but is still readable after first unlock (so the lock
        // handler can run while the screen is locked).
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.info("Keychain save failed: status=\(status)")
        }
        return status == errSecSuccess
    }

    static func load() -> SlackAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let account = try? JSONDecoder().decode(SlackAccount.self, from: data)
        else {
            return nil
        }
        return account
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }
}
