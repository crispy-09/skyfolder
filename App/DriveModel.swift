import Foundation
import SwiftUI
import AppKit
import Observation
import ServiceManagement

enum DriveSection: Hashable {
    case myFiles, recent, starred, offline, trash
    case search(String)

    var title: String {
        switch self {
        case .myFiles: return "My Files"
        case .recent: return "Recent"
        case .starred: return "Starred"
        case .offline: return "Available offline"
        case .trash: return "Trash"
        case .search: return "Search results"
        }
    }
}

enum ViewMode: String { case list, grid }
enum SortKey: String { case name, modified, size }

enum ModifiedFilter: String, CaseIterable, Identifiable {
    case today = "Today", week = "Last 7 days", month = "Last 30 days", year = "This year", lastYear = "Last year"
    var id: String { rawValue }

    func matches(_ date: Date?) -> Bool {
        guard let date else { return false }
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today: return cal.isDateInToday(date)
        case .week: return date > now.addingTimeInterval(-7 * 86400)
        case .month: return date > now.addingTimeInterval(-30 * 86400)
        case .year: return cal.component(.year, from: date) == cal.component(.year, from: now)
        case .lastYear: return cal.component(.year, from: date) == cal.component(.year, from: now) - 1
        }
    }
}

struct Crumb: Hashable {
    var name: String
    var path: String
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

@Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable { case running, done, failed(String), cancelled }
    let id = UUID()
    let kind: Kind
    let name: String
    let isFolder: Bool
    var fraction: Double = 0
    var state: State = .running
    var resultURL: URL?
    /// Counts bytes: `completedUnitCount` of `totalUnitCount` (the total stays at 1 until the size is known).
    let progress = Progress(totalUnitCount: 1)
    var doneBytes: Int64 = 0
    /// 0 while the full size isn't known (e.g. a folder being zipped by the server).
    var totalBytes: Int64 = 0
    /// Bytes per second, averaged over the last few seconds.
    var speed: Double = 0
    private var observation: NSKeyValueObservation?
    private var lastSample: (time: TimeInterval, bytes: Int64)?

    init(kind: Kind, name: String, isFolder: Bool = false) {
        self.kind = kind
        self.name = name
        self.isFolder = isFolder
        observation = progress.observe(\.completedUnitCount) { [weak self] p, _ in
            let done = p.completedUnitCount, total = p.totalUnitCount, f = p.fractionCompleted
            DispatchQueue.main.async { self?.record(done: done, total: total, fraction: f) }
        }
    }

    private func record(done: Int64, total: Int64, fraction f: Double) {
        fraction = f
        doneBytes = done
        totalBytes = total > 1 ? total : 0
        let now = Date.timeIntervalSinceReferenceDate
        guard let last = lastSample else { lastSample = (now, done); return }
        let dt = now - last.time
        guard dt >= 1 else { return }
        let current = Double(max(0, done - last.bytes)) / dt
        speed = speed == 0 ? current : speed * 0.6 + current * 0.4   // smooth out bursts
        lastSample = (now, done)
    }

    /// "3.1 MB of 20 MB · 850 KB/s" while running, the size once finished.
    var detail: String {
        switch state {
        case .running:
            var s = totalBytes > 0 ? "\(doneBytes.formattedBytes) of \(totalBytes.formattedBytes)"
                                   : (doneBytes > 0 ? doneBytes.formattedBytes : "Starting…")
            if speed >= 1 { s += " · \(Int64(speed).formattedBytes)/s" }
            return s
        case .done: return totalBytes > 0 ? totalBytes.formattedBytes : "Done"
        case .failed(let msg): return msg
        case .cancelled: return "Canceled"
        }
    }
}

struct PendingDialog: Identifiable {
    enum Kind { case newFolder, rename(RemoteItem), emptyTrash, deleteForever([RemoteItem]), signOut }
    let id = UUID()
    let kind: Kind
}

@MainActor
@Observable
final class DriveModel {
    // Session
    var account: AccountConfig?
    var client: DAVClient?
    var isSigningIn = false
    var signInError: String?
    var sessionExpired = false
    private let loginFlow = LoginFlow()

    // Finder integration
    var finderEnabled = false
    var finderError: String?

    // Navigation
    var section: DriveSection = .myFiles
    var crumbs: [Crumb] = []
    var currentFolder: RemoteItem?
    var items: [RemoteItem] = []
    var isLoading = false
    var loadError: String?
    var searchText = ""

    // Presentation
    var selection: Set<String> = []
    var lastSelected: String?
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var sortKey: SortKey = .name
    var sortAscending = true
    var typeFilter: FileKind?
    var modifiedFilter: ModifiedFilter?
    var showDetails = false
    var dialog: PendingDialog?
    var moveTargets: [RemoteItem]?
    var previewItem: RemoteItem?

    // Status
    var quota: Quota?
    var toast: Toast?
    var transfers: [Transfer] = []
    var transfersCollapsed = false
    var pinned: [String: PinnedStore.Info] = PinnedStore.all()
    /// Paths (relative to the drive root) whose contents are on this Mac right now, read from the Finder folder
    /// itself: downloaded files, and folders in which everything is downloaded.
    var onDisk: Set<String> = []
    /// The top-most entries of `onDisk` (a fully downloaded folder stands for everything inside it).
    private var onDiskTop: [String] = []
    var lastSync: Date?

    private var pollTimer: Timer?
    private var loadGeneration = 0

    init() {
        if let acc = AccountConfig.load(), TokenStore.load() != nil {
            activate(acc)
        }
    }

    // MARK: Session

    func signIn(server: String) {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host else {
            signInError = "Enter a valid server address, like cloud.example.com."
            return
        }
        // Never send credentials over plain HTTP (except to this machine, for testing).
        if url.scheme?.lowercased() != "https" && !["localhost", "127.0.0.1", "::1"].contains(host) {
            signInError = "The server must use HTTPS (https://\(host))."
            return
        }
        UserDefaults.standard.set(s, forKey: "lastServer")
        isSigningIn = true
        signInError = nil
        Task {
            do {
                let acc = try await loginFlow.signIn(serverURL: url)
                activate(acc)
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    func cancelSignIn() {
        loginFlow.cancel()
        isSigningIn = false
    }

    private func activate(_ acc: AccountConfig) {
        account = acc
        client = DAVClient(account: acc)
        sessionExpired = false
        crumbs = [Crumb(name: "My Files", path: "")]
        section = .myFiles
        reload()
        refreshQuota()
        refreshDownloaded()
        startPolling()
        Task {
            do {
                try await FileProviderBridge.register()
                finderEnabled = true
                finderError = nil
            } catch {
                finderEnabled = false
                finderError = error.localizedDescription
                NSLog("Skyfolder: could not register File Provider domain: \(error)")
            }
        }
    }

    func signOut() {
        pollTimer?.invalidate()
        Task {
            if let kept = await FileProviderBridge.unregister() {
                // Edits that never reached the server were set aside instead of being deleted.
                NSWorkspace.shared.activateFileViewerSelecting([kept])
            }
            await TokenProvider.shared.clear()
            AccountConfig.clear()
            PinnedStore.clearAll()
            ThumbnailLoader.shared.clearAll()
            try? FileManager.default.removeItem(at: Self.openCopiesDir)
            pinned = [:]
            onDisk = []
            onDiskTop = []
            account = nil
            client = nil
            items = []
            finderEnabled = false
        }
    }

    private func handle(_ error: Error) {
        switch error {
        case AuthError.sessionExpired, AuthError.notSignedIn, DAVError.unauthorized:
            sessionExpired = true
        case is CancellationError:
            break
        case let e as URLError where e.code == .cancelled:
            break
        default:
            showToast(error.localizedDescription)
        }
    }

    func reauthenticate() {
        guard let acc = account else { return }
        signIn(server: acc.serverURL.absoluteString)
    }

    // MARK: Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private var pollCount = 0
    private func poll() {
        guard account != nil, !sessionExpired else { return }
        pollCount += 1
        FileProviderBridge.signalChanges()
        pinned = PinnedStore.all()
        refreshDownloaded()
        if !isLoading && dialog == nil { reload(silent: true) }
        if pollCount % 10 == 0 { refreshQuota() }
        lastSync = Date()
    }

    func refreshQuota() {
        guard let client else { return }
        Task { quota = try? await client.quota() }
    }

    // MARK: Navigation

    func go(_ s: DriveSection) {
        section = s
        selection = []
        typeFilter = nil
        modifiedFilter = nil
        if s == .myFiles { crumbs = [Crumb(name: "My Files", path: "")] }
        if case .search = s {} else { searchText = "" }
        reload()
    }

    func openFolder(path: String) {
        var cs = [Crumb(name: "My Files", path: "")]
        var acc = ""
        for comp in path.split(separator: "/") {
            acc = acc.isEmpty ? String(comp) : acc + "/" + comp
            cs.append(Crumb(name: String(comp), path: acc))
        }
        section = .myFiles
        crumbs = cs
        selection = []
        typeFilter = nil
        modifiedFilter = nil
        searchText = ""
        reload()
    }

    func search() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        go(.search(q))
        searchText = q
    }

    var currentPath: String { crumbs.last?.path ?? "" }

    func reload(silent: Bool = false) {
        guard let client else { return }
        loadGeneration += 1
        let gen = loadGeneration
        let section = self.section
        let path = currentPath
        if !silent { isLoading = true; loadError = nil; if !silent { items = [] } }
        Task {
            do {
                var result: [RemoteItem]
                switch section {
                case .myFiles:
                    let listing = try await client.listFolder(path: path)
                    if gen == loadGeneration { currentFolder = listing.folder }
                    result = listing.children
                    // Files copied in through Finder that haven't reached the server yet.
                    if finderEnabled, let root = await FileProviderBridge.rootURL() {
                        // A file part-way through a chunked upload already exists on the server, but empty.
                        let known = Set(result.filter { $0.isFolder || $0.size > 0 }
                            .map { $0.name.precomposedStringWithCanonicalMapping })
                        let local = await Task.detached { Self.uploadingFiles(root: root.path, folder: path, known: known) }.value
                        let replaced = Set(local.map { $0.name.precomposedStringWithCanonicalMapping })
                        result.removeAll { !$0.isFolder && $0.size == 0 && replaced.contains($0.name.precomposedStringWithCanonicalMapping) }
                        result += local
                    }
                case .recent:
                    result = try await client.search("mtime:\"last 30 days\"", limit: 300).filter { !$0.isFolder }
                case .starred:
                    result = try await client.search("tag:\(AppConstants.favoriteTag)", limit: 500)
                case .offline:
                    await refreshDownloadedNow()
                    let pins = PinnedStore.all()
                    let ids = Array(pins.keys)
                    // A folder marked offline stands for everything inside it, so don't also list its files.
                    let pinnedFolders = pins.values.filter(\.isFolder).compactMap(\.path)
                        .map { $0.precomposedStringWithCanonicalMapping }
                    func insidePinnedFolder(_ path: String) -> Bool {
                        let p = path.precomposedStringWithCanonicalMapping
                        return pinnedFolders.contains { $0.isEmpty || p.hasPrefix($0 + "/") }
                    }
                    let paths = Array(onDiskTop.filter { !insidePinnedFolder($0) }.prefix(2000))
                    let found = await withTaskGroup(of: RemoteItem?.self) { group in
                        for id in ids { group.addTask { try? await client.item(id: id) } }
                        for p in paths {
                            group.addTask {
                                do {
                                    var it = try await client.stat(client.spacePathURL(p))
                                    if it.path == nil { it.path = p }
                                    // Empty on the server but not here: a chunked upload is still in progress.
                                    if !it.isFolder, it.size == 0, let root = await FileProviderBridge.rootURL(),
                                       let local = Self.uploadingFile(root: root.path, path: p), local.size > 0 {
                                        return local
                                    }
                                    return it
                                } catch DAVError.notFound {
                                    // On this Mac but not on the server yet: still uploading.
                                    guard let root = await FileProviderBridge.rootURL() else { return nil }
                                    return Self.uploadingFile(root: root.path, path: p)
                                } catch {
                                    return nil
                                }
                            }
                        }
                        var out: [RemoteItem] = []
                        for await r in group { if let r { out.append(r) } }
                        return out
                    }
                    var seen = Set<String>()
                    result = found.filter { seen.insert($0.id).inserted }
                        .filter { it in
                            // Also hide an item that is marked offline itself but sits inside an offline folder.
                            guard let path = it.path ?? pins[it.id]?.path else { return true }
                            return !insidePinnedFolder(path)
                        }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    // item(id:) lookups are id-based; recover paths from what we stored at pin time.
                    let info = PinnedStore.all()
                    let records = DownloadedStore.all()
                    for i in result.indices where result[i].path == nil {
                        result[i].path = info[result[i].id]?.path ?? records[result[i].id]?.path
                    }
                case .trash:
                    result = try await client.listTrash()
                case .search(let q):
                    let escaped = q.replacingOccurrences(of: "\"", with: "")
                    result = try await client.search("name:\"*\(escaped)*\"", limit: 300)
                }
                guard gen == loadGeneration else { return }
                if result != items { items = result }
                selection = selection.filter { id in result.contains { $0.id == id } }
                loadError = nil
            } catch {
                guard gen == loadGeneration else { return }
                if case DAVError.notFound = error, section == .myFiles, crumbs.count > 1 {
                    // Folder vanished (deleted elsewhere): go up.
                    crumbs.removeLast()
                    reload()
                    return
                }
                if !silent { loadError = error.localizedDescription }
                handle(error)
            }
            if gen == loadGeneration { isLoading = false }
        }
    }

    // MARK: Derived lists

    var visibleItems: [RemoteItem] {
        var list = items
        if let t = typeFilter { list = list.filter { FileKind.of($0) == t } }
        if let m = modifiedFilter { list = list.filter { m.matches($0.modified) } }
        if section == .recent {
            return list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        if section == .trash {
            return list.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        }
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let r: Bool
            switch sortKey {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: r = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: r = a.size < b.size
            }
            return sortAscending ? r : !r
        }
    }

    var selectedItems: [RemoteItem] { items.filter { selection.contains($0.id) } }

    func setSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = key == .name }
    }

    // MARK: Selection

    func click(_ item: RemoteItem, in list: [RemoteItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let last = lastSelected,
                  let a = list.firstIndex(where: { $0.id == last }), let b = list.firstIndex(where: { $0.id == item.id }) {
            for i in min(a, b)...max(a, b) { selection.insert(list[i].id) }
        } else {
            selection = [item.id]
        }
        // Files that are still uploading can't be acted on yet (the server doesn't know them).
        selection = selection.filter { !$0.hasPrefix(RemoteItem.localPrefix) }
        lastSelected = item.id
    }

    /// Items an action applies to: the selection if the clicked item is part of it, otherwise just that item.
    func targets(for item: RemoteItem) -> [RemoteItem] {
        if selection.contains(item.id) && selection.count > 1 { return selectedItems }
        return [item]
    }

    // MARK: Offline state

    func isPinned(_ item: RemoteItem) -> Bool { pinned[item.id] != nil }

    func refreshDownloaded() {
        Task { await refreshDownloadedNow() }
    }

    /// Walks the Finder folder and returns what is really downloaded. Placeholders ("dataless" files and folders)
    /// are never entered, so this touches only local data and never triggers a download.
    nonisolated private static func scanDisk(root: String) -> (all: Set<String>, top: [String]) {
        var all = Set<String>()
        var raw: [String: String] = [:]   // normalized -> path as stored on disk (used for server lookups)
        var budget = 300_000
        /// Returns true if everything at `rel` is on disk.
        func visit(_ full: String, _ rel: String) -> Bool {
            var st = stat()
            guard lstat(full, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
            budget -= 1
            if budget < 0 { return false }
            if st.st_mode & S_IFMT == S_IFDIR {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { return false }
                var complete = true
                for n in names where !n.hasPrefix(".") {
                    let childRel = rel.isEmpty ? n : rel + "/" + n
                    if !visit(full + "/" + n, childRel) { complete = false }
                }
                guard complete, !rel.isEmpty else { return false }
            }
            let key = rel.precomposedStringWithCanonicalMapping
            all.insert(key)
            raw[key] = rel
            return true
        }
        _ = visit(root, "")
        let top = all.filter { p in
            guard let i = p.lastIndex(of: "/") else { return true }
            return !all.contains(String(p[..<i]))
        }
        return (all, top.map { raw[$0] ?? $0 })
    }

    /// A made-up entry for a local file the server doesn't have yet (nil for folders and placeholders).
    nonisolated private static func uploadingFile(root: String, path: String) -> RemoteItem? {
        var st = stat()
        guard lstat(root + "/" + path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return .uploading(path: path, size: Int64(st.st_size),
                          modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }

    /// Local files in one folder of the Finder location whose names the server listing doesn't contain.
    nonisolated private static func uploadingFiles(root: String, folder: String, known: Set<String>) -> [RemoteItem] {
        let dir = folder.isEmpty ? root : root + "/" + folder
        var st = stat()
        // Never look inside a placeholder folder: that would make the system fetch its listing.
        guard lstat(dir, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { !$0.hasPrefix(".") && !known.contains($0.precomposedStringWithCanonicalMapping) }
            .compactMap { uploadingFile(root: root, path: folder.isEmpty ? $0 : folder + "/" + $0) }
    }

    /// Reads the real on-disk state, and unpins files the user removed with Finder's "Remove Download".
    func refreshDownloadedNow() async {
        guard finderEnabled, let root = await FileProviderBridge.rootURL() else { return }
        let scan = await Task.detached(priority: .utility) { Self.scanDisk(root: root.path) }.value
        if scan.all != onDisk {
            onDisk = scan.all
            onDiskTop = scan.top
        }
        let records = DownloadedStore.all()
        var gone: [String] = []
        var evicted: [(id: String, etag: String)] = []
        let pins = PinnedStore.all()
        for (id, rec) in records {
            guard let path = rec.path else { continue }
            var st = stat()
            let full = path.isEmpty ? root.path : root.appendingPathComponent(path).path
            if lstat(full, &st) == 0 {
                if st.st_flags & UInt32(SF_DATALESS) == 0 { continue }
                if let pin = pins[id], !pin.isFolder, let etag = rec.etag { evicted.append((id, etag)) }
            } else if errno == ENOENT {
                gone.append(id)
            }
        }
        DownloadedStore.remove(gone)
        // Pinned files that were already on disk when they were pinned have no record yet; without one a later
        // "Remove Download" could not be recognised.
        if let client {
            for (id, pin) in pins where !pin.isFolder && records[id]?.etag == nil {
                guard let path = pin.path, onDisk.contains(path.precomposedStringWithCanonicalMapping),
                      let current = try? await client.item(id: id) else { continue }
                DownloadedStore.record(id, name: pin.name, path: path, etag: current.etag)
            }
        }
        // A pinned file that went back to the cloud at the version we downloaded was removed by the user
        // (Finder's "Remove Download"): honour that by unpinning it. A different etag just means a newer
        // version is still being fetched.
        if let client {
            for (id, etag) in evicted {
                guard let current = try? await client.item(id: id), current.etag == etag else { continue }
                PinnedStore.set(id, pinned: false, info: nil)
                DownloadedStore.remove([id])
            }
            if !evicted.isEmpty { pinned = PinnedStore.all() }
        }
    }

    /// True if the item is on this Mac (a folder counts once everything in it is), or is marked to be kept offline
    /// and still downloading.
    func isOffline(_ item: RemoteItem) -> Bool {
        if pinned[item.id] != nil { return true }
        guard let p = item.path, !p.isEmpty else { return false }
        return onDisk.contains(p.precomposedStringWithCanonicalMapping)
    }

    /// True while "Remove all offline copies" is running.
    var removingOffline = false

    /// Frees up this Mac: clears every "available offline" mark and turns every downloaded file back into an
    /// online-only placeholder. Nothing is deleted from the server, and files that haven't finished uploading are
    /// left alone (the system refuses to evict those).
    func removeAllOfflineCopies() {
        guard finderEnabled, !removingOffline else { return }
        removingOffline = true
        Task {
            for id in PinnedStore.all().keys { PinnedStore.set(id, pinned: false, info: nil) }
            pinned = PinnedStore.all()
            FileProviderBridge.signalChanges()
            await refreshDownloadedNow()
            let targets = onDiskTop
            var removed = 0
            if let root = await FileProviderBridge.rootURL() {
                removed = await Task.detached(priority: .userInitiated) {
                    var n = 0
                    for path in targets {
                        if (try? FileManager.default.evictUbiquitousItem(at: root.appendingPathComponent(path))) != nil { n += 1 }
                    }
                    return n
                }.value
            }
            await refreshDownloadedNow()
            removingOffline = false
            let left = onDisk.count
            showToast(left == 0 ? "Removed all offline copies from this Mac"
                      : "Removed \(removed) offline \(removed == 1 ? "copy" : "copies"). \(left) still uploading or in use were kept.")
            if section == .offline { reload(silent: true) }
        }
    }

    /// True if the item is kept current automatically: marked "available offline" itself or inside such a folder.
    func isKept(_ item: RemoteItem) -> Bool {
        PinnedStore.covers(item.id, path: item.path, in: pinned)
    }

    func setOffline(_ targets: [RemoteItem], on: Bool) {
        guard let acc = account else { return }
        guard finderEnabled else {
            showToast("Finder integration isn't running, so files can't be kept offline yet.")
            return
        }
        Task {
            var contained: [RemoteItem] = []
            if on, let client {
                for t in targets where t.isFolder { contained += await client.files(under: t.id, path: t.path) }
            }
            await FileProviderBridge.setOffline(targets, contained: contained, on: on, rootID: acc.rootID)
            pinned = PinnedStore.all()
            let what = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) items"
            showToast(on ? "\(what) will be available offline" : "\(what) removed from this Mac (still in the cloud)")
            if section == .offline { reload(silent: true) }
            // Downloads and evictions land a little later; pick the new state up without waiting for the next poll.
            for delay in [2, 6, 15] {
                try? await Task.sleep(for: .seconds(delay))
                await refreshDownloadedNow()
                if section == .offline { reload(silent: true) }
            }
        }
    }

    // MARK: Open / reveal

    func open(_ item: RemoteItem) {
        if section == .trash { return }
        if item.isFolder {
            if let p = item.path { openFolder(path: p) }
            else if let client {
                Task { if let full = try? await client.item(id: item.id), let p = full.path { openFolder(path: p) } }
            }
            return
        }
        Task {
            let path = await resolvePath(item)
            // Preferred: open through Finder integration so edits sync back automatically.
            if finderEnabled, let path, let url = await FileProviderBridge.localURL(forPath: path) {
                let ok = await withCheckedContinuation { cont in
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                        cont.resume(returning: err == nil)
                    }
                }
                if ok { return }
            }
            // Fallback: download a temporary copy and open it (read-only workflow).
            await downloadAndOpen(item)
        }
    }

    private func resolvePath(_ item: RemoteItem) async -> String? {
        if let p = item.path { return p }
        guard let client, let full = try? await client.item(id: item.id) else { return nil }
        if let p = full.path { return p }
        // id-based lookups don't return paths; rebuild from parents.
        var parts = [full.name]
        var parent = full.parentID
        var guardCount = 0
        while let pid = parent, pid != account?.rootID, guardCount < 64 {
            guard let p = try? await client.item(id: pid) else { return nil }
            if p.id == account?.rootID || p.parentID == nil { break }
            parts.insert(p.name, at: 0)
            parent = p.parentID
            guardCount += 1
        }
        return parts.joined(separator: "/")
    }

    private func downloadAndOpen(_ item: RemoteItem) async {
        guard let client else { return }
        let dir = Self.openCopiesDir.appendingPathComponent(Self.safeFileName(item.opaqueID))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(Self.safeFileName(item.name))
        let t = Transfer(kind: .download, name: item.name)
        t.progress.totalUnitCount = max(item.size, 1)
        transfers.insert(t, at: 0)
        do {
            try await client.download(id: item.id, to: dest, progress: t.progress)
            t.state = .done
            t.resultURL = dest
            NSWorkspace.shared.open(dest)
        } catch {
            t.state = .failed(error.localizedDescription)
            handle(error)
        }
    }

    func showInFinder(_ item: RemoteItem) {
        Task {
            guard finderEnabled, let path = await resolvePath(item),
                  let url = await FileProviderBridge.localURL(forPath: path) else {
                showToast("Finder integration isn't available.")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openInFinder() {
        Task {
            if let url = await FileProviderBridge.rootURL() {
                NSWorkspace.shared.open(url)
            } else {
                showToast("Finder integration isn't available.")
            }
        }
    }

    func openWeb(_ item: RemoteItem? = nil) {
        guard let acc = account else { return }
        NSWorkspace.shared.open(item.map { acc.webURL(forFileID: $0.id) } ?? acc.serverURL)
    }

    func copyLink(_ item: RemoteItem) {
        guard let acc = account else { return }
        let link = item.privateLink ?? acc.webURL(forFileID: item.id).absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        showToast("Link copied")
    }

    // MARK: Mutations

    func showToast(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let t = Toast(message: message, actionTitle: actionTitle, action: action)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(action == nil ? 4 : 7))
            if toast?.id == t.id { toast = nil }
        }
    }

    private func afterChange() {
        reload(silent: true)
        FileProviderBridge.signalChanges()
    }

    func createFolder(named name: String) {
        guard let client else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do {
                let parentID = try await currentFolderID()
                _ = try await client.createFolder(parentID: parentID, name: n)
                afterChange()
            } catch { handle(error) }
        }
    }

    private func currentFolderID() async throws -> String {
        if section == .myFiles, let f = currentFolder, f.path == currentPath { return f.id }
        guard let client else { throw AuthError.notSignedIn }
        if section != .myFiles { return account?.rootID ?? "" }
        return try await client.stat(client.spacePathURL(currentPath)).id
    }

    func rename(_ item: RemoteItem, to newName: String) {
        guard let client, let acc = account else { return }
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != item.name, !n.contains("/") else { return }
        Task {
            do {
                let parent = item.parentID ?? acc.rootID
                _ = try await client.move(id: item.id, toParent: parent, name: n)
                afterChange()
            } catch { handle(error) }
        }
    }

    func trash(_ targets: [RemoteItem]) {
        guard let client else { return }
        let restoreInfo = targets.map { ($0.opaqueID, $0.path) }
        Task {
            do {
                for t in targets { try await client.delete(id: t.id) }
                for t in targets where pinned[t.id] != nil { PinnedStore.set(t.id, pinned: false, info: nil) }
                pinned = PinnedStore.all()
                items.removeAll { i in targets.contains { $0.id == i.id } }
                selection = []
                afterChange()
                let msg = targets.count == 1 ? "“\(targets[0].name)” moved to trash" : "\(targets.count) items moved to trash"
                showToast(msg, actionTitle: "Undo") { [weak self] in
                    guard let self else { return }
                    Task {
                        for (key, path) in restoreInfo {
                            if let path { try? await client.restore(trashKey: key, originalLocation: path) }
                        }
                        self.afterChange()
                        self.showToast("Action undone")
                    }
                }
            } catch { handle(error) }
        }
    }

    func setStarred(_ targets: [RemoteItem], _ on: Bool) {
        guard let client else { return }
        Task {
            do {
                for t in targets { try await client.setFavorite(id: t.id, on) }
                for i in items.indices where targets.contains(where: { $0.id == items[i].id }) {
                    if on { if !items[i].tags.contains(AppConstants.favoriteTag) { items[i].tags.append(AppConstants.favoriteTag) } }
                    else { items[i].tags.removeAll { $0 == AppConstants.favoriteTag } }
                }
                if section == .starred && !on { items.removeAll { i in targets.contains { $0.id == i.id } } }
                showToast(on ? "Added to Starred" : "Removed from Starred")
            } catch { handle(error) }
        }
    }

    func makeCopy(_ item: RemoteItem) {
        guard let client, let acc = account else { return }
        Task {
            do {
                let parent = item.parentID ?? acc.rootID
                let name = try await client.availableName(parentID: parent, desired: "Copy of \(item.name)")
                _ = try await client.copy(id: item.id, toParent: parent, name: name)
                afterChange()
                showToast("Created “\(name)”")
            } catch { handle(error) }
        }
    }

    func move(_ targets: [RemoteItem], to folder: RemoteItem) {
        guard let client else { return }
        Task {
            do {
                for t in targets where t.id != folder.id {
                    _ = try await client.move(id: t.id, toParent: folder.id, name: t.name)
                }
                afterChange()
                let what = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) items"
                showToast("Moved \(what) to “\(folder.path?.isEmpty == false ? folder.name : "My Files")”",
                          actionTitle: "Open folder") { [weak self] in self?.openFolder(path: folder.path ?? "") }
            } catch { handle(error) }
        }
    }

    // Trash view actions
    func restore(_ targets: [RemoteItem]) {
        guard let client else { return }
        Task {
            do {
                for t in targets {
                    if let key = t.trashKey { try await client.restore(trashKey: key, originalLocation: t.originalLocation ?? t.name) }
                }
                items.removeAll { i in targets.contains { $0.id == i.id } }
                selection = []
                afterChange()
                showToast(targets.count == 1 ? "“\(targets[0].name)” restored" : "\(targets.count) items restored")
            } catch { handle(error) }
        }
    }

    func deleteForever(_ targets: [RemoteItem]) {
        guard let client else { return }
        Task {
            do {
                for t in targets { if let key = t.trashKey { try await client.purge(trashKey: key) } }
                items.removeAll { i in targets.contains { $0.id == i.id } }
                selection = []
                refreshQuota()
            } catch { handle(error) }
        }
    }

    func emptyTrash() {
        guard let client else { return }
        Task {
            do {
                try await client.emptyTrash()
                items = []
                refreshQuota()
                showToast("Trash emptied")
            } catch { handle(error) }
        }
    }

    // MARK: Transfers

    func pickAndUpload(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func upload(_ urls: [URL], toFolderID explicitID: String? = nil) {
        guard let client else { return }
        Task {
            let parentID: String
            if let explicitID { parentID = explicitID } else {
                do { parentID = try await currentFolderID() } catch { handle(error); return }
            }
            transfersCollapsed = false
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let t = Transfer(kind: .upload, name: url.lastPathComponent, isFolder: isDir)
                    transfers.insert(t, at: 0)
                    group.addTask { @MainActor in
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            try await self.uploadEntry(url, parentID: parentID, client: client, transfer: t)
                            t.progress.completedUnitCount = t.progress.totalUnitCount
                            t.state = .done
                        } catch is CancellationError {
                            t.state = .cancelled
                        } catch let e as URLError where e.code == .cancelled {
                            t.state = .cancelled
                        } catch {
                            t.state = .failed(error.localizedDescription)
                        }
                        self.reload(silent: true)
                    }
                }
            }
            refreshQuota()
            FileProviderBridge.signalChanges()
        }
    }

    /// Uploads a file or folder. If the upload is cancelled, everything it had added so far is taken back
    /// (moved to the server's trash bin), so a cancelled upload doesn't leave half a folder behind.
    private func uploadEntry(_ url: URL, parentID: String, client: DAVClient, transfer: Transfer) async throws {
        var added: [String] = []   // ids of folders created and files uploaded by this upload, in order
        do {
            try await uploadEntry(url, parentID: parentID, client: client, transfer: transfer, added: &added)
        } catch {
            let cancelled = transfer.progress.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if cancelled {
                // Newly created folders take their contents with them; ids already gone are ignored.
                for id in added { try? await client.delete(id: id) }
                throw CancellationError()
            }
            throw error
        }
    }

    private func uploadEntry(_ url: URL, parentID: String, client: DAVClient, transfer: Transfer,
                             added: inout [String]) async throws {
        let fm = FileManager.default
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDir {
            let name = try await client.availableName(parentID: parentID, desired: url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            transfer.progress.totalUnitCount = Int64(max(size, 1))
            let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let item = try await client.upload(file: url, to: .new(parentID: parentID, name: name), modified: mtime,
                                               progress: transfer.progress)
            added.append(item.id)
            return
        }
        // Folder: count files for progress, then mirror the tree.
        var files: [URL] = []
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                 options: [.skipsHiddenFiles]) {
            for case let f as URL in e where !((try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) {
                files.append(f)
            }
        }
        let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        transfer.progress.totalUnitCount = max(sizes.reduce(0, +), 1)
        var sentBefore: Int64 = 0   // bytes of the files already finished
        let rootName = url.lastPathComponent
        var folderIDs: [String: String] = [:]
        let top: RemoteItem
        do {
            top = try await client.createFolder(parentID: parentID, name: rootName)
            added.append(top.id)
        } catch DAVError.alreadyExists {
            guard let existing = try await client.child(parentID: parentID, name: rootName) else { throw DAVError.alreadyExists }
            top = existing
        }
        folderIDs[""] = top.id

        var createdFolders: [String] = []
        func folderID(for rel: String) async throws -> String {
            if let id = folderIDs[rel] { return id }
            let parentRel = (rel as NSString).deletingLastPathComponent
            let pid = try await folderID(for: parentRel == "/" ? "" : parentRel)
            let name = (rel as NSString).lastPathComponent
            let f: RemoteItem
            do {
                f = try await client.createFolder(parentID: pid, name: name)
                createdFolders.append(f.id)
            } catch DAVError.alreadyExists {
                guard let ex = try await client.child(parentID: pid, name: name) else { throw DAVError.alreadyExists }
                f = ex
            }
            folderIDs[rel] = f.id
            return f.id
        }

        // Create empty subfolders too.
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let d as URL in e where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                let rel = String(d.path.dropFirst(url.path.count + 1))
                _ = try await folderID(for: rel)
            }
        }
        for (index, f) in files.enumerated() {
            try Task.checkCancellation()
            if transfer.progress.isCancelled { throw CancellationError() }
            let rel = String(f.path.dropFirst(url.path.count + 1))
            let dirRel = (rel as NSString).deletingLastPathComponent
            let pid = try await folderID(for: dirRel)
            let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // Never overwrite: if a file with this name already exists, keep both (like "name (1).ext").
            let name = try await client.availableName(parentID: pid, desired: f.lastPathComponent)
            added.append(contentsOf: createdFolders); createdFolders = []
            // Cancelling the transfer stops the file that is in flight, not just the ones after it.
            let fileProgress = Progress()
            transfer.progress.cancellationHandler = { fileProgress.cancel() }
            let base = sentBefore
            let overall = transfer.progress
            let watch = fileProgress.observe(\.completedUnitCount) { p, _ in
                overall.completedUnitCount = base + p.completedUnitCount
            }
            defer { watch.invalidate() }
            let item = try await client.upload(file: f, to: .new(parentID: pid, name: name), modified: mtime,
                                               progress: fileProgress)
            added.append(item.id)
            sentBefore += sizes[index]
            transfer.progress.completedUnitCount = sentBefore
        }
        added.append(contentsOf: createdFolders)
    }

    func download(_ targets: [RemoteItem]) {
        guard let client else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        transfersCollapsed = false
        for item in targets {
            let t = Transfer(kind: .download, name: item.isFolder ? item.name + ".zip" : item.name, isFolder: item.isFolder)
            t.progress.totalUnitCount = max(item.size, 1)
            transfers.insert(t, at: 0)
            Task {
                let dest = Self.uniqueURL(in: downloads, name: Self.safeFileName(t.name))
                do {
                    if item.isFolder {
                        try await client.download(url: client.archiveURL(id: item.id), to: dest, progress: t.progress)
                    } else {
                        try await client.download(id: item.id, to: dest, progress: t.progress)
                    }
                    t.state = .done
                    t.resultURL = dest
                } catch {
                    t.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    static var openCopiesDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.github.crispy-09.skyfolder-open", isDirectory: true)
    }

    /// Makes a server-provided name safe to use as a single local path component.
    static func safeFileName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() } // no "..", no hidden files
        return n.isEmpty ? "download" : String(n.prefix(255))
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: Login item

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { showToast(error.localizedDescription) }
        }
    }
}
