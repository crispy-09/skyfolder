import Foundation

/// Items the user marked "Available offline". Folders pin their whole subtree (children inherit the content policy).
/// Shared between the app and the extension as a JSON file in the app-group container.
enum PinnedStore {
    struct Info: Codable, Hashable {
        var name: String
        var isFolder: Bool
        var path: String?
    }

    private static let pinnedFile = "pinned.json"
    private static let dirtyFile = "dirty.json"

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (mtime: Date, value: [String: Info])?

    static func all() -> [String: Info] {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: SharedFile.url(pinnedFile).path)[.modificationDate]) as? Date
        if let mtime {
            if let c = cacheLock.withLock({ cached }), c.mtime == mtime { return c.value }
            if let dict = SharedFile.read([String: Info].self, pinnedFile) {
                cacheLock.withLock { cached = (mtime, dict) }
                return dict
            }
        }
        // Migrate pins saved in app-group defaults by earlier builds.
        if let data = AppConstants.sharedDefaults.data(forKey: "pinnedItems"),
           let dict = try? JSONDecoder().decode([String: Info].self, from: data) {
            SharedFile.write(dict, pinnedFile)
            AppConstants.sharedDefaults.removeObject(forKey: "pinnedItems")
            return dict
        }
        return [:]
    }

    static func isPinned(_ id: String) -> Bool { all()[id] != nil }

    /// True if the item is pinned itself or sits inside a pinned folder.
    static func covers(_ id: String, path: String?, in pins: [String: Info]) -> Bool {
        if pins[id] != nil { return true }
        guard let p = path else { return false }
        return pins.values.contains { info in
            guard info.isFolder, let fp = info.path else { return false }
            return fp.isEmpty || p.hasPrefix(fp + "/")
        }
    }

    /// Earlier builds told the system to keep pinned items downloaded (`keepDownloaded`), which makes macOS refuse
    /// Finder's "Remove Download". Pins are now enforced by Skyfolder itself, so re-report every pinned item once
    /// so the system drops the old policy.
    static func migrateContentPolicyIfNeeded() {
        let marker = "policy-v2.json"
        guard SharedFile.read(Bool.self, marker) != true else { return }
        let ids = Array(all().keys)
        if !ids.isEmpty { markDirty(ids) }
        SharedFile.write(true, marker)
    }

    static func set(_ id: String, pinned: Bool, info: Info?) {
        SharedFile.update(pinnedFile, default: [String: Info]()) { dict in
            if pinned, let info { dict[id] = info } else { dict.removeValue(forKey: id) }
        }
        markDirty([id])
    }

    /// Keeps a pin's stored name and path current after the item was renamed or moved.
    static func updateLocation(_ id: String, name: String, path: String) {
        guard let info = all()[id], info.path != path || info.name != name else { return }
        SharedFile.update(pinnedFile, default: [String: Info]()) { dict in
            dict[id]?.name = name
            dict[id]?.path = path
        }
    }

    static func clearAll() {
        SharedFile.remove(pinnedFile)
        SharedFile.remove(dirtyFile)
        DownloadedStore.clearAll()
    }

    /// Items whose metadata (e.g. pin state) changed locally and must be re-reported to the system.
    static func markDirty(_ ids: [String]) {
        SharedFile.update(dirtyFile, default: [String]()) { list in
            list = Array(Set(list).union(ids))
        }
    }

    static func takeDirty() -> [String] {
        var out: [String] = []
        SharedFile.update(dirtyFile, default: [String]()) { list in
            out = list
            list = []
        }
        return out
    }
}

/// Files the extension has downloaded to this Mac (by opening them, Finder "Download Now", or pinning).
/// The app checks each one's real on-disk state, since the system can evict files without telling us.
enum DownloadedStore {
    struct Record: Codable, Hashable {
        var name: String
        var path: String?
        var date: Date
        /// Server etag of the downloaded version. Lets the app tell "evicted by the user" from "outdated".
        var etag: String?
    }

    private static let file = "downloaded.json"

    static func all() -> [String: Record] {
        SharedFile.read([String: Record].self, file) ?? [:]
    }

    static func record(_ id: String, name: String, path: String?, etag: String? = nil) {
        SharedFile.update(file, default: [String: Record]()) { dict in
            dict[id] = Record(name: name, path: path ?? dict[id]?.path, date: Date(), etag: etag)
        }
    }

    static func updatePath(_ id: String, name: String, path: String?) {
        SharedFile.update(file, default: [String: Record]()) { dict in
            guard dict[id] != nil else { return }
            dict[id]?.name = name
            if let path { dict[id]?.path = path }
        }
    }

    /// Same as `updatePath` for many items, with a single write.
    static func updatePaths(_ entries: [(id: String, name: String, path: String?)]) {
        guard !entries.isEmpty else { return }
        SharedFile.update(file, default: [String: Record]()) { dict in
            for e in entries where dict[e.id] != nil {
                dict[e.id]?.name = e.name
                if let path = e.path { dict[e.id]?.path = path }
            }
        }
    }

    static func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        SharedFile.update(file, default: [String: Record]()) { dict in
            for id in ids { dict.removeValue(forKey: id) }
        }
    }

    static func clearAll() { SharedFile.remove(file) }
}
