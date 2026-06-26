import Foundation

enum SlackError: LocalizedError {
    case notConnected
    case authExpired
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Slack."
        case .authExpired:  return "Slack session expired. Please reconnect."
        case .api(let m):   return "Slack error: \(m)"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

/// Talks to Slack's `users.profile.set` endpoint using the same session token
/// (`xoxc` token + `d` cookie) the official desktop client uses.
final class SlackClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sets the user's status on a specific workspace.
    /// `expiration` of 0 means "do not auto-clear".
    func setStatus(text: String, emoji: String, expiration: Int,
                   token: String, cookie: String) async throws {
        let profile: [String: Any] = [
            "status_text": text,
            "status_emoji": emoji,
            "status_expiration": expiration
        ]
        try await postProfile(profile, token: token, cookie: cookie)
    }

    /// Clears the user's status on a specific workspace.
    func clearStatus(token: String, cookie: String) async throws {
        let profile: [String: Any] = [
            "status_text": "",
            "status_emoji": "",
            "status_expiration": 0
        ]
        try await postProfile(profile, token: token, cookie: cookie)
    }

    /// Reads the user's current status (text + emoji + expiration) on a workspace.
    func getStatus(token: String, cookie: String) async throws
        -> (text: String, emoji: String, expiration: Int) {
        let json = try await post(endpoint: "users.profile.get", body: "",
                                  token: token, cookie: cookie)
        let profile = json["profile"] as? [String: Any]
        let text = (profile?["status_text"] as? String) ?? ""
        let emoji = (profile?["status_emoji"] as? String) ?? ""
        let expiration = (profile?["status_expiration"] as? Int) ?? 0
        return (text, emoji, expiration)
    }

    /// Returns true if Slack notifications are currently snoozed or the user is
    /// within their scheduled Do Not Disturb window on this workspace. On any
    /// failure it returns false (so AFK still works rather than silently doing
    /// nothing).
    func isDNDActive(token: String, cookie: String) async -> Bool {
        guard let json = try? await post(endpoint: "dnd.info", body: "",
                                         token: token, cookie: cookie) else {
            return false
        }
        // Manual snooze takes priority.
        if let snooze = json["snooze_enabled"] as? Bool, snooze { return true }
        // Scheduled DND that is active right now.
        if let dndEnabled = json["dnd_enabled"] as? Bool, dndEnabled {
            let now = Date().timeIntervalSince1970
            let start = (json["next_dnd_start_ts"] as? NSNumber)?.doubleValue ?? 0
            let end = (json["next_dnd_end_ts"] as? NSNumber)?.doubleValue ?? 0
            if start > 0, end > 0, now >= start, now < end { return true }
        }
        return false
    }

    /// Validates a token/cookie and returns the workspace identity.
    func authTest(token: String, cookie: String) async throws
        -> (teamID: String, team: String, url: String?) {
        let json = try await post(endpoint: "auth.test", body: "", token: token, cookie: cookie)
        let teamID = (json["team_id"] as? String) ?? (json["team"] as? String) ?? token
        let team = (json["team"] as? String) ?? "Slack"
        let url = json["url"] as? String
        return (teamID, team, url)
    }

    private func postProfile(_ profile: [String: Any], token: String, cookie: String) async throws {
        guard let profileData = try? JSONSerialization.data(withJSONObject: profile),
              let profileJSON = String(data: profileData, encoding: .utf8) else {
            throw SlackError.api("encode_failed")
        }
        let body = "profile=" + (profileJSON.addingPercentEncoding(
            withAllowedCharacters: .urlQueryValueAllowed) ?? profileJSON)
        _ = try await post(endpoint: "users.profile.set", body: body, token: token, cookie: cookie)
    }

    @discardableResult
    private func post(endpoint: String, body: String,
                      token: String, cookie: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://slack.com/api/\(endpoint)") else {
            throw SlackError.api("invalid_url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SlackError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw SlackError.api("rate_limited")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.api("invalid_response")
        }

        let ok = (json["ok"] as? Bool) ?? false
        if !ok {
            let err = (json["error"] as? String) ?? "unknown"
            if err == "invalid_auth" || err == "token_expired"
                || err == "not_authed" || err == "token_revoked" {
                throw SlackError.authExpired
            }
            throw SlackError.api(err)
        }
        return json
    }
}

private extension CharacterSet {
    /// URL-query allowed characters minus sub-delimiters that must be escaped
    /// inside a form value (e.g. `&`, `+`, `=`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?/")
        return set
    }()
}
