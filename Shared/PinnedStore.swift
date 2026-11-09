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

    static func set(_ id: String, pinned: Bool, info: Info?) {
        SharedFile.update(pinnedFile, default: [String: Info]()) { dict in
            if pinned, let info { dict[id] = info } else { dict.removeValue(forKey: id) }
        }
        markDirty([id])
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
    }

    private static let file = "downloaded.json"

    static func all() -> [String: Record] {
        SharedFile.read([String: Record].self, file) ?? [:]
    }

    static func record(_ id: String, name: String, path: String?) {
        SharedFile.update(file, default: [String: Record]()) { dict in
            dict[id] = Record(name: name, path: path ?? dict[id]?.path, date: Date())
        }
    }

    static func updatePath(_ id: String, name: String, path: String?) {
        SharedFile.update(file, default: [String: Record]()) { dict in
            guard dict[id] != nil else { return }
            dict[id]?.name = name
            if let path { dict[id]?.path = path }
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
