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
    let progress = Progress(totalUnitCount: 1)
    private var observation: NSKeyValueObservation?

    init(kind: Kind, name: String, isFolder: Bool = false) {
        self.kind = kind
        self.name = name
        self.isFolder = isFolder
        observation = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { self?.fraction = f }
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
    /// Files whose contents are currently on this Mac (downloaded on demand or kept offline).
    var downloaded: Set<String> = []
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
            await FileProviderBridge.unregister()
            await TokenProvider.shared.clear()
            AccountConfig.clear()
            PinnedStore.clearAll()
            ThumbnailLoader.shared.clearAll()
            try? FileManager.default.removeItem(at: Self.openCopiesDir)
            pinned = [:]
            downloaded = []
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
                case .recent:
                    result = try await client.search("mtime:\"last 30 days\"", limit: 300).filter { !$0.isFolder }
                case .starred:
                    result = try await client.search("tag:\(AppConstants.favoriteTag)", limit: 500)
                case .offline:
                    await refreshDownloadedNow()
                    let ids = Array(Set(PinnedStore.all().keys).union(downloaded))
                    result = await withTaskGroup(of: RemoteItem?.self) { group in
                        for id in ids { group.addTask { try? await client.item(id: id) } }
                        var out: [RemoteItem] = []
                        for await r in group { if let r { out.append(r) } }
                        return out
                    }
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

    /// Checks each recorded download against the real file: present and not "dataless" (a cloud placeholder).
    func refreshDownloadedNow() async {
        guard finderEnabled, let root = await FileProviderBridge.rootURL() else { return }
        let records = DownloadedStore.all()
        var present = Set<String>()
        var gone: [String] = []
        for (id, rec) in records {
            guard let path = rec.path else { continue }
            var st = stat()
            let full = path.isEmpty ? root.path : root.appendingPathComponent(path).path
            if lstat(full, &st) == 0 {
                if st.st_flags & UInt32(SF_DATALESS) == 0 { present.insert(id) }
            } else if errno == ENOENT {
                gone.append(id)
            }
        }
        DownloadedStore.remove(gone)
        if present != downloaded { downloaded = present }
    }

    /// True if the item, or a folder containing it, is available offline.
    func isOffline(_ item: RemoteItem) -> Bool {
        if pinned[item.id] != nil || downloaded.contains(item.id) { return true }
        guard let p = item.path else { return false }
        return pinned.values.contains { info in
            guard info.isFolder, let fp = info.path else { return false }
            return fp.isEmpty || p.hasPrefix(fp + "/")
        }
    }

    func setOffline(_ targets: [RemoteItem], on: Bool) {
        guard let acc = account else { return }
        guard finderEnabled else {
            showToast("Finder integration isn't running, so files can't be kept offline yet.")
            return
        }
        Task {
            await FileProviderBridge.setOffline(targets, on: on, rootID: acc.rootID)
            pinned = PinnedStore.all()
            let what = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) items"
            showToast(on ? "\(what) will be available offline" : "\(what) removed from this Mac (still in the cloud)")
            if section == .offline { reload(silent: true) }
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

    private func uploadEntry(_ url: URL, parentID: String, client: DAVClient, transfer: Transfer) async throws {
        let fm = FileManager.default
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDir {
            let name = try await client.availableName(parentID: parentID, desired: url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            transfer.progress.totalUnitCount = Int64(max(size, 1))
            let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            _ = try await client.upload(file: url, to: .new(parentID: parentID, name: name), modified: mtime,
                                        progress: transfer.progress)
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
        transfer.progress.totalUnitCount = Int64(max(files.count, 1))
        let rootName = url.lastPathComponent
        var folderIDs: [String: String] = [:]
        let top: RemoteItem
        do { top = try await client.createFolder(parentID: parentID, name: rootName) }
        catch DAVError.alreadyExists {
            guard let existing = try await client.child(parentID: parentID, name: rootName) else { throw DAVError.alreadyExists }
            top = existing
        }
        folderIDs[""] = top.id

        func folderID(for rel: String) async throws -> String {
            if let id = folderIDs[rel] { return id }
            let parentRel = (rel as NSString).deletingLastPathComponent
            let pid = try await folderID(for: parentRel == "/" ? "" : parentRel)
            let name = (rel as NSString).lastPathComponent
            let f: RemoteItem
            do { f = try await client.createFolder(parentID: pid, name: name) }
            catch DAVError.alreadyExists {
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
        for f in files {
            try Task.checkCancellation()
            let rel = String(f.path.dropFirst(url.path.count + 1))
            let dirRel = (rel as NSString).deletingLastPathComponent
            let pid = try await folderID(for: dirRel)
            let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // Never overwrite: if a file with this name already exists, keep both (like "name (1).ext").
            let name = try await client.availableName(parentID: pid, desired: f.lastPathComponent)
            _ = try await client.upload(file: f, to: .new(parentID: pid, name: name), modified: mtime)
            transfer.progress.completedUnitCount += 1
        }
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
