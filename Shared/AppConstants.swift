import Foundation
import FileProvider

enum AppConstants {
    /// App group shared between the app and the File Provider extension. Comes from Info.plist (set by project.yml).
    static let appGroup: String = (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String)
        ?? "V4S4N7FT58.io.github.crispy-09.skyfolder"

    /// OIDC client registered in OpenCloud's built-in IdP for desktop clients (loopback redirect, PKCE, no secret).
    static let clientID = "OpenCloudDesktop"
    static let scopes = "openid profile email offline_access"

    static let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "skyfolder")
    static let domainDisplayName = "Skyfolder"

    /// OpenCloud servers often have the favorites capability disabled, so "Starred" is stored as a server-side tag.
    static let favoriteTag = "favorite"

    static let keychainService = "io.github.crispy-09.skyfolder"

    static var groupContainer: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Should never happen in a correctly signed build; fall back to a private dir so we don't crash.
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skyfolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
}

/// Everything we need to know about the signed-in account. Stored (non-secret) in the shared app-group defaults.
struct AccountConfig: Codable, Equatable {
    var serverURL: URL
    var username: String
    var displayName: String
    var userID: String
    var spaceID: String        // personal space id, e.g. "storage$space"
    var rootID: String         // fileid of the personal space root, e.g. "storage$space!space"
    var tokenEndpoint: URL
    var authorizationEndpoint: URL
    var endSessionEndpoint: URL?

    private static let file = "account.json"

    static func load() -> AccountConfig? {
        if let a = SharedFile.read(AccountConfig.self, file) { return a }
        // Migrate from the app-group defaults used by earlier builds.
        if let data = AppConstants.sharedDefaults.data(forKey: "account"),
           let a = try? JSONDecoder().decode(AccountConfig.self, from: data) {
            a.save()
            return a
        }
        return nil
    }

    func save() { SharedFile.write(self, Self.file) }

    static func clear() {
        SharedFile.remove(file)
        AppConstants.sharedDefaults.removeObject(forKey: "account")
    }

    /// Link to the item in the OpenCloud web UI.
    func webURL(forFileID id: String) -> URL {
        var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        comps.path = "/f/" + id
        return comps.url ?? serverURL
    }
}

/// Small JSON files in the app-group container, shared by the (unsandboxed) app and the (sandboxed) extension.
/// Files are used instead of UserDefaults because suite defaults can live in different places for
/// sandboxed vs. unsandboxed processes.
enum SharedFile {
    static func url(_ name: String) -> URL { AppConstants.groupContainer.appendingPathComponent(name) }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    /// Read-modify-write under a cross-process file lock.
    static func update<T: Codable>(_ name: String, default def: T, _ body: (inout T) -> Void) {
        let fd = open(url(name + ".lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var value = read(T.self, name) ?? def
        body(&value)
        write(value, name)
    }
}
