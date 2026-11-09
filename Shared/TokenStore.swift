import Foundation
import Security

struct TokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date

    var isFresh: Bool { expiresAt > Date().addingTimeInterval(30) }
}

enum AuthError: LocalizedError {
    case notSignedIn
    case sessionExpired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You're not signed in."
        case .sessionExpired: return "Your session expired. Please sign in again."
        case .server(let m): return m
        }
    }
}

/// Persists tokens in the data-protection keychain under the app-group access group so both the app and the
/// File Provider extension can read them. Falls back to a 0600 file in the group container if the keychain
/// rejects the access group (e.g. unusual signing setups).
enum TokenStore {
    private static let account = "tokens"
    private static var fallbackURL: URL { AppConstants.groupContainer.appendingPathComponent(".tokens.json") }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppConstants.appGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func load() -> TokenSet? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let t = try? JSONDecoder().decode(TokenSet.self, from: data) {
            return t
        }
        if let data = try? Data(contentsOf: fallbackURL) {
            return try? JSONDecoder().decode(TokenSet.self, from: data)
        }
        return nil
    }

    static func save(_ tokens: TokenSet) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let q = baseQuery()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackURL)
        } else {
            NSLog("Skyfolder: keychain save failed (\(status)); using file fallback")
            try? data.write(to: fallbackURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
    }
}

/// Hands out valid access tokens, refreshing when needed. Refreshes are single-flight within a process and
/// serialized across the app + extension with a file lock, because the IdP rotates refresh tokens.
actor TokenProvider {
    static let shared = TokenProvider()

    private var cached: TokenSet?
    private var refreshTask: Task<TokenSet, Error>?

    func setTokens(_ t: TokenSet) {
        cached = t
        TokenStore.save(t)
    }

    func clear() {
        cached = nil
        TokenStore.clear()
    }

    /// - Parameter rejected: an access token the server just refused with 401; forces a refresh if still current.
    func accessToken(rejected: String? = nil) async throws -> String {
        if let t = cached ?? TokenStore.load(), t.isFresh, t.accessToken != rejected {
            cached = t
            return t.accessToken
        }
        if let task = refreshTask {
            return try await task.value.accessToken
        }
        let task = Task.detached { try await Self.refreshLocked(rejected: rejected) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let t = try await task.value
            cached = t
            return t.accessToken
        } catch {
            cached = nil
            throw error
        }
    }

    private static func refreshLocked(rejected: String?) async throws -> TokenSet {
        let lockPath = AppConstants.groupContainer.appendingPathComponent(".token.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

        // Another process may have refreshed while we waited for the lock.
        guard let current = TokenStore.load() else { throw AuthError.notSignedIn }
        if current.isFresh && current.accessToken != rejected { return current }
        guard let refresh = current.refreshToken, let account = AccountConfig.load() else {
            throw AuthError.sessionExpired
        }
        let new = try await OIDC.refresh(refreshToken: refresh, tokenEndpoint: account.tokenEndpoint)
        TokenStore.save(new)
        return new
    }
}

enum OIDC {
    struct Discovery: Decodable {
        let issuer: String
        let authorization_endpoint: URL
        let token_endpoint: URL
        let end_session_endpoint: URL?
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
    }

    struct ErrorResponse: Decodable {
        let error: String
        let error_description: String?
    }

    static func discover(server: URL) async throws -> Discovery {
        let url = server.appendingPathComponent(".well-known/openid-configuration")
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.server("This doesn't look like an OpenCloud server (no OpenID configuration found).")
        }
        return try JSONDecoder().decode(Discovery.self, from: data)
    }

    static func exchange(code: String, verifier: String, redirectURI: String, tokenEndpoint: URL) async throws -> TokenSet {
        try await tokenRequest(tokenEndpoint, [
            "grant_type": "authorization_code",
            "client_id": AppConstants.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ], previousRefresh: nil)
    }

    static func refresh(refreshToken: String, tokenEndpoint: URL) async throws -> TokenSet {
        try await tokenRequest(tokenEndpoint, [
            "grant_type": "refresh_token",
            "client_id": AppConstants.clientID,
            "refresh_token": refreshToken,
        ], previousRefresh: refreshToken)
    }

    private static func tokenRequest(_ endpoint: URL, _ params: [String: String], previousRefresh: String?) async throws -> TokenSet {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                if e.error == "invalid_grant" { throw AuthError.sessionExpired }
                throw AuthError.server(e.error_description ?? e.error)
            }
            throw AuthError.server("Sign-in failed (HTTP \(status)).")
        }
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenSet(accessToken: r.access_token,
                        refreshToken: r.refresh_token ?? previousRefresh,
                        idToken: r.id_token,
                        expiresAt: Date().addingTimeInterval(r.expires_in ?? 300))
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
