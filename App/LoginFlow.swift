import Foundation
import Network
import CryptoKit
import AppKit

/// OIDC authorization-code + PKCE sign-in through the user's browser, with a loopback redirect
/// (http://127.0.0.1:<port>) — the same flow the official OpenCloud desktop client uses.
@MainActor
final class LoginFlow {
    private var server: LoopbackServer?

    func cancel() {
        server?.stop()
        server = nil
    }

    func signIn(serverURL: URL) async throws -> AccountConfig {
        let discovery = try await OIDC.discover(server: serverURL)

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(24)

        let loopback = LoopbackServer()
        server = loopback
        defer { loopback.stop(); server = nil }
        let port = try await loopback.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: AppConstants.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: AppConstants.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let callback = try await loopback.waitForCallback()
        let params = Dictionary(uniqueKeysWithValues: (callback.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let err = params["error"] {
            throw AuthError.server(params["error_description"] ?? err)
        }
        guard params["state"] == state, let code = params["code"], !code.isEmpty else {
            throw AuthError.server("Sign-in was interrupted. Please try again.")
        }
        NSApp.activate(ignoringOtherApps: true)

        let tokens = try await OIDC.exchange(code: code, verifier: verifier, redirectURI: redirectURI,
                                             tokenEndpoint: discovery.token_endpoint)
        return try await Self.buildAccount(server: serverURL, discovery: discovery, tokens: tokens)
    }

    private static func buildAccount(server: URL, discovery: OIDC.Discovery, tokens: TokenSet) async throws -> AccountConfig {
        func get(_ path: String) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
            req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthError.server("Couldn't load your account from the server.")
            }
            return obj
        }
        let me = try await get("/graph/v1.0/me")
        let drives = try await get("/graph/v1.0/me/drives")
        let personal = (drives["value"] as? [[String: Any]])?.first { ($0["driveType"] as? String) == "personal" }
        guard let spaceID = personal?["id"] as? String else {
            throw AuthError.server("Your account has no personal space on this server.")
        }
        let rootID = ((personal?["root"] as? [String: Any])?["id"] as? String) ?? Self.defaultRootID(spaceID)

        let account = AccountConfig(
            serverURL: server,
            username: (me["onPremisesSamAccountName"] as? String) ?? (me["mail"] as? String) ?? "",
            displayName: (me["displayName"] as? String) ?? "",
            userID: (me["id"] as? String) ?? "",
            spaceID: spaceID,
            rootID: rootID,
            tokenEndpoint: discovery.token_endpoint,
            authorizationEndpoint: discovery.authorization_endpoint,
            endSessionEndpoint: discovery.end_session_endpoint)
        await TokenProvider.shared.setTokens(tokens)
        account.save()

        // Confirm the root id with the WebDAV API (authoritative).
        if let root = try? await DAVClient(account: account).stat(DAVClient(account: account).spacePathURL("")) {
            var fixed = account
            fixed.rootID = root.id
            fixed.save()
            return fixed
        }
        return account
    }

    /// "storage$space" → "storage$space!space"
    private static func defaultRootID(_ spaceID: String) -> String {
        let opaque = spaceID.split(separator: "$").last.map(String.init) ?? spaceID
        return spaceID + "!" + opaque
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tiny one-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "loopback")
    private var callbackContinuation: CheckedContinuation<URLComponents, Error>?
    private var pendingResult: Result<URLComponents, Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let r = self.pendingResult { cont.resume(with: r); return }
                    self.callbackContinuation = cont
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        queue.async {
            if let c = self.callbackContinuation {
                self.callbackContinuation = nil
                c.resume(with: result)
            } else if self.pendingResult == nil {
                self.pendingResult = result
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let comps = URLComponents(string: "http://127.0.0.1" + target)
            let isCallback = comps?.queryItems?.contains { $0.name == "code" || $0.name == "error" } ?? false

            let body = isCallback ? Self.donePage : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback, let comps { self.finish(.success(comps)) }
        }
    }

    private static let donePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Skyfolder</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;
    height:100vh;margin:0;background:#f8fafd;color:#1f1f1f}div{text-align:center}h1{font-weight:500;font-size:22px}
    p{color:#444746}</style></head><body><div><h1>You're signed in</h1>
    <p>You can close this tab and return to Skyfolder.</p></div></body></html>
    """
}
