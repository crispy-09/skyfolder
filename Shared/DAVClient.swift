import Foundation
import CryptoKit

enum DAVError: LocalizedError {
    case http(Int, String?)
    case notFound
    case preconditionFailed      // If-Match mismatch (someone else changed the file)
    case alreadyExists
    case insufficientStorage
    case unauthorized
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return msg.map { "Server error \(code): \($0)" } ?? "Server error \(code)."
        case .notFound: return "The item no longer exists on the server."
        case .preconditionFailed: return "The item was changed on the server."
        case .alreadyExists: return "An item with that name already exists."
        case .insufficientStorage: return "Not enough storage space on the server."
        case .unauthorized: return "You're not signed in."
        case .invalidResponse: return "The server sent an unexpected response."
        }
    }
}

struct Quota {
    var used: Int64
    var total: Int64?
}

/// Talks to OpenCloud's WebDAV (spaces) and LibreGraph APIs.
final class DAVClient: @unchecked Sendable {
    let account: AccountConfig
    let session: URLSession
    /// For uploads and downloads. Many transfers sharing a slow link can each sit idle far longer than a metadata
    /// request ever should, so they get a much longer idle timeout.
    let transferSession: URLSession
    private let tokens: TokenProvider

    init(account: AccountConfig, tokens: TokenProvider = .shared) {
        self.account = account
        self.tokens = tokens
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
        let tcfg = URLSessionConfiguration.default
        tcfg.timeoutIntervalForRequest = 60 * 10
        tcfg.timeoutIntervalForResource = 60 * 60 * 24
        tcfg.httpMaximumConnectionsPerHost = 6
        tcfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.transferSession = URLSession(configuration: tcfg)
    }

    // MARK: URLs

    private var serverRoot: String {
        var s = account.serverURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static let idAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~$!")
        return c
    }()

    private static let nameAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~")
        return c
    }()

    static func encodeName(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? s
    }

    static func encodePath(_ p: String) -> String {
        p.split(separator: "/", omittingEmptySubsequences: true).map { encodeName(String($0)) }.joined(separator: "/")
    }

    /// /dav/spaces/<resource>[/<relativePath>] where resource is a space id or a file id.
    func davURL(resource: String, path: String? = nil) -> URL {
        var s = serverRoot + "/dav/spaces/" + (resource.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? resource)
        if let path, !path.isEmpty { s += "/" + Self.encodePath(path) }
        return URL(string: s)!
    }

    func spacePathURL(_ path: String) -> URL { davURL(resource: account.spaceID, path: path) }
    func idURL(_ id: String) -> URL { davURL(resource: id) }
    func childURL(parentID: String, name: String) -> URL { davURL(resource: parentID, path: name) }
    var trashURL: URL { davURL(resource: "trash-bin/" + account.spaceID) }

    private func trashItemURL(_ key: String) -> URL {
        URL(string: trashURL.absoluteString + "/" + Self.encodeName(key))!
    }

    private func graphURL(_ path: String) -> URL { URL(string: serverRoot + "/graph/v1.0/" + path)! }

    // MARK: Core request

    @discardableResult
    func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
              expect: Set<Int>? = nil) async throws -> (Data, HTTPURLResponse) {
        var rejected: String?
        for attempt in 0..<2 {
            let token = try await tokens.accessToken(rejected: rejected)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw DAVError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 { rejected = token; continue }
            try Self.check(http, data: data, expect: expect)
            return (data, http)
        }
        throw DAVError.unauthorized
    }

    static func check(_ http: HTTPURLResponse, data: Data?, expect: Set<Int>?) throws {
        let code = http.statusCode
        if let expect, expect.contains(code) { return }
        if expect == nil, (200..<300).contains(code) || code == 207 { return }
        switch code {
        case 401: throw DAVError.unauthorized
        case 404: throw DAVError.notFound
        case 412: throw DAVError.preconditionFailed
        case 507: throw DAVError.insufficientStorage
        default:
            var msg: String?
            if let data, let s = String(data: data, encoding: .utf8),
               let r = s.range(of: "<s:message>"), let e = s.range(of: "</s:message>"), r.upperBound <= e.lowerBound {
                msg = String(s[r.upperBound..<e.lowerBound])
            }
            throw DAVError.http(code, msg)
        }
    }

    // MARK: Parsing

    private static let propfindBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <d:getlastmodified/><d:getetag/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
        <oc:fileid/><oc:file-parent/><oc:name/><oc:permissions/><oc:size/><oc:tags/>
        <oc:privatelink/><oc:has-preview/><oc:owner-display-name/>
      </d:prop>
    </d:propfind>
    """.data(using: .utf8)!

    private static let trashBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <oc:trashbin-original-filename/><oc:trashbin-original-location/><oc:trashbin-delete-datetime/>
        <d:getcontentlength/><oc:size/><d:resourcetype/><d:getcontenttype/>
      </d:prop>
    </d:propfind>
    """.data(using: .utf8)!

    /// Converts an href into a path relative to the personal space root, if it is path-based.
    private func relativePath(fromHref href: String) -> String? {
        let decoded = href.removingPercentEncoding ?? href
        var trimmed = decoded
        if let r = trimmed.range(of: "://") { // absolute href
            trimmed = String(trimmed[r.upperBound...])
            if let slash = trimmed.firstIndex(of: "/") { trimmed = String(trimmed[slash...]) }
        }
        let prefix = "/dav/spaces/" + account.spaceID
        guard trimmed.hasPrefix(prefix) else { return nil }
        var rest = String(trimmed.dropFirst(prefix.count))
        if !rest.isEmpty && !rest.hasPrefix("/") { return nil } // e.g. "...!opaque" id-based
        while rest.hasPrefix("/") { rest.removeFirst() }
        while rest.hasSuffix("/") { rest.removeLast() }
        return rest
    }

    func item(from r: DAVResponse) -> RemoteItem? {
        let p = r.props
        guard let id = p["fileid"], !id.isEmpty else { return nil }
        let path = relativePath(fromHref: r.href)
        var name = p["name"] ?? ""
        if name.isEmpty {
            let comp = (r.href.removingPercentEncoding ?? r.href).split(separator: "/").last.map(String.init) ?? ""
            name = comp
        }
        if let path, !path.isEmpty { name = (path as NSString).lastPathComponent }
        let isFolder = r.isCollection || p["getcontenttype"] == "httpd/unix-directory"
        let size = Int64(p["getcontentlength"] ?? "") ?? Int64(p["size"] ?? "") ?? 0
        let tags = (p["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return RemoteItem(
            id: id,
            parentID: p["file-parent"].flatMap { $0.isEmpty ? nil : $0 },
            name: name,
            path: path,
            isFolder: isFolder,
            size: size,
            modified: HTTPDate.parse(p["getlastmodified"]),
            etag: (p["getetag"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            contentType: p["getcontenttype"],
            permissions: p["permissions"] ?? "",
            tags: tags,
            privateLink: p["privatelink"],
            hasPreview: p["has-preview"] == "1",
            ownerName: p["owner-display-name"])
    }

    // MARK: Reading

    /// Lists a folder. Returns the folder itself plus its direct children.
    func list(_ url: URL) async throws -> (folder: RemoteItem?, children: [RemoteItem]) {
        let (data, _) = try await send("PROPFIND", url, headers: ["Depth": "1", "Content-Type": "application/xml"],
                                       body: Self.propfindBody)
        let responses = DAVParser.parse(data)
        guard let first = responses.first else { throw DAVError.invalidResponse }
        let folder = item(from: first)
        var children = responses.dropFirst().compactMap { item(from: $0) }
        if let folder {
            for i in children.indices where children[i].parentID == nil { children[i].parentID = folder.id }
            if let fp = folder.path {
                for i in children.indices where children[i].path == nil {
                    children[i].path = fp.isEmpty ? children[i].name : fp + "/" + children[i].name
                }
            }
        }
        return (folder, children)
    }

    func listFolder(id: String) async throws -> (folder: RemoteItem?, children: [RemoteItem]) {
        try await list(idURL(id))
    }

    func listFolder(path: String) async throws -> (folder: RemoteItem?, children: [RemoteItem]) {
        try await list(spacePathURL(path))
    }

    func stat(_ url: URL) async throws -> RemoteItem {
        let (data, _) = try await send("PROPFIND", url, headers: ["Depth": "0", "Content-Type": "application/xml"],
                                       body: Self.propfindBody)
        guard let r = DAVParser.parse(data).first, let it = item(from: r) else { throw DAVError.notFound }
        return it
    }

    func item(id: String) async throws -> RemoteItem { try await stat(idURL(id)) }

    /// Returns the child with the given name, or nil if there is none.
    func child(parentID: String, name: String) async throws -> RemoteItem? {
        do { return try await stat(childURL(parentID: parentID, name: name)) } catch DAVError.notFound { return nil }
    }

    /// KQL search within the personal space (e.g. `name:"*foo*"`, `mtime:"last 30 days"`, `tag:favorite`).
    func search(_ pattern: String, limit: Int = 200) async throws -> [RemoteItem] {
        let escaped = pattern
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <oc:search-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop>
            <d:getlastmodified/><d:getetag/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
            <oc:fileid/><oc:file-parent/><oc:name/><oc:permissions/><oc:size/><oc:tags/><oc:privatelink/><oc:has-preview/>
          </d:prop>
          <oc:search><oc:pattern>\(escaped)</oc:pattern><oc:limit>\(limit)</oc:limit></oc:search>
        </oc:search-files>
        """
        let (data, _) = try await send("REPORT", spacePathURL(""), headers: ["Content-Type": "application/xml"],
                                       body: body.data(using: .utf8))
        return DAVParser.parse(data).compactMap { item(from: $0) }.filter { $0.id != account.rootID && $0.path != "" }
    }

    // MARK: Transfers

    func download(id: String, to destination: URL, progress: Progress? = nil) async throws {
        try await download(url: idURL(id), to: destination, progress: progress)
    }

    func download(url: URL, to destination: URL, progress: Progress? = nil) async throws {
        var rejected: String?
        for attempt in 0..<2 {
            let token = try await tokens.accessToken(rejected: rejected)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let http: HTTPURLResponse = try await withCheckedThrowingContinuation { cont in
                var observation: NSKeyValueObservation?
                let task = transferSession.downloadTask(with: req) { tmp, resp, error in
                    observation?.invalidate()
                    if let error { cont.resume(throwing: error); return }
                    guard let http = resp as? HTTPURLResponse else { cont.resume(throwing: DAVError.invalidResponse); return }
                    if (200..<300).contains(http.statusCode), let tmp {
                        do {
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.moveItem(at: tmp, to: destination)
                        } catch { cont.resume(throwing: error); return }
                    }
                    cont.resume(returning: http)
                }
                if let progress {
                    observation = task.progress.observe(\.completedUnitCount) { p, _ in
                        if p.totalUnitCount > 0 { progress.totalUnitCount = p.totalUnitCount }
                        progress.completedUnitCount = p.completedUnitCount
                    }
                    progress.cancellationHandler = { [weak task] in task?.cancel() }
                }
                task.resume()
            }
            if http.statusCode == 401 && attempt == 0 { rejected = token; continue }
            try Self.check(http, data: nil, expect: nil)
            return
        }
        throw DAVError.unauthorized
    }

    /// Uploads (PUT) a local file and returns the resulting item.
    /// - Parameters:
    ///   - target: either `.new(parentID:name:)` or `.existing(id:ifMatch:)`
    /// - Parameter existingLocation: for `.existing` targets, the file's current parent and name. Large files go
    ///   through resumable chunked (TUS) uploads, which address the file by parent + name.
    func upload(file: URL, to target: UploadTarget, modified: Date? = nil, progress: Progress? = nil,
                existingLocation: (parentID: String, name: String)? = nil) async throws -> RemoteItem {
        // A big batch (Finder copies in thousands of files at once) would otherwise open as many uploads as the
        // system asks for, saturate the uplink and starve listings, sign-in refreshes and everything else.
        await Self.uploadGate.acquire()
        defer { Task { await Self.uploadGate.release() } }
        try Task.checkCancellation()
        do {
            return try await uploadNow(file: file, to: target, modified: modified, progress: progress, existingLocation: existingLocation)
        } catch {
            // A cancelled upload of a new file leaves an empty file behind on the server. Remove it, so it doesn't
            // show up as a real (empty) file later. Failures are left alone: those are retried and fill it in.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                || progress?.isCancelled == true
            if cancelled, case .new(let parentID, let name) = target {
                Task.detached { [self] in await removeEmptyLeftover(parentID: parentID, name: name) }
            }
            throw error
        }
    }

    /// Deletes `name` in `parentID` if it is an empty file, and clears it out of the server's trash too.
    private func removeEmptyLeftover(parentID: String, name: String) async {
        guard let it = try? await child(parentID: parentID, name: name), !it.isFolder, it.size == 0 else { return }
        try? await delete(id: it.id)
        try? await purge(trashKey: it.opaqueID)
    }

    static let uploadGate = TransferGate(limit: 3)

    private func uploadNow(file: URL, to target: UploadTarget, modified: Date?, progress: Progress?,
                           existingLocation: (parentID: String, name: String)?) async throws -> RemoteItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.tusThreshold {
            var tusTarget: (parentID: String, name: String, ifMatch: String?)?
            switch target {
            case .new(let parentID, let name): tusTarget = (parentID, name, nil)
            case .existing(let id, let ifMatch):
                // Only if the file still has that name; otherwise a TUS "overwrite" would create a duplicate.
                if let loc = existingLocation, let current = try? await item(id: id), current.name == loc.name,
                   current.parentID == nil || current.parentID == loc.parentID {
                    tusTarget = (loc.parentID, loc.name, ifMatch)
                }
            }
            if let t = tusTarget {
                if let fid = try await tusUpload(file: file, size: size, parentID: t.parentID, name: t.name, ifMatch: t.ifMatch,
                                                 modified: modified, progress: progress) {
                    return try await item(id: fid)
                }
                // Server doesn't offer resumable uploads; fall through to a single PUT.
            }
        }
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        switch target {
        case .new(let parentID, let name):
            url = childURL(parentID: parentID, name: name)
        case .existing(let id, let ifMatch):
            url = idURL(id)
            if let ifMatch, !ifMatch.isEmpty { headers["If-Match"] = "\"\(ifMatch)\"" }
        }
        if let modified { headers["X-OC-Mtime"] = String(Int64(modified.timeIntervalSince1970)) }
        headers["OC-Total-Length"] = String(size)

        var rejected: String?
        for attempt in 0..<2 {
            let token = try await tokens.accessToken(rejected: rejected)
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let delegate = TransferDelegate(progress: progress)
            let (data, resp) = try await transferSession.upload(for: req, fromFile: file, delegate: delegate)
            guard let http = resp as? HTTPURLResponse else { throw DAVError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 { rejected = token; continue }
            try Self.check(http, data: data, expect: nil)
            if let fid = http.value(forHTTPHeaderField: "OC-FileId"), !fid.isEmpty {
                return try await item(id: fid)
            }
            switch target {
            case .new(let parentID, let name): return try await stat(childURL(parentID: parentID, name: name))
            case .existing(let id, _): return try await item(id: id)
            }
        }
        throw DAVError.unauthorized
    }

    // MARK: Chunked (TUS) uploads

    /// Files above this size are uploaded in chunks. A single huge PUT trips proxy limits (e.g. Cloudflare's 100 MB
    /// request cap and ~100 s response timeout) and can't resume after a dropped connection.
    static let tusThreshold: Int64 = 20_000_000
    /// Must stay at or below the server's advertised `max_chunk_size` (10 MB on OpenCloud).
    static let tusChunkSize = 8_000_000

    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Uploads `file` with the TUS protocol. Returns the new file's id, or nil when the server doesn't support TUS
    /// (the caller then falls back to PUT). Network hiccups are retried and resumed from the server's offset.
    private func tusUpload(file: URL, size: Int64, parentID: String, name: String, ifMatch: String?,
                           modified: Date?, progress: Progress?) async throws -> String? {
        var meta = ["filename \(Self.b64(name))"]
        if let modified { meta.append("mtime \(Self.b64(String(Int64(modified.timeIntervalSince1970))))") }
        var headers = ["Tus-Resumable": "1.0.0", "Upload-Length": String(size), "Upload-Metadata": meta.joined(separator: ",")]
        if let ifMatch, !ifMatch.isEmpty { headers["If-Match"] = "\"\(ifMatch)\"" }

        let created: HTTPURLResponse
        do {
            (_, created) = try await send("POST", davURL(resource: parentID), headers: headers, expect: [201])
        } catch DAVError.http(let code, _) where [400, 404, 405, 501].contains(code) {
            return nil
        } catch DAVError.notFound {
            return nil
        }
        guard let loc = created.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: loc, relativeTo: davURL(resource: parentID))?.absoluteURL
        else { return nil }

        progress?.totalUnitCount = size
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var fileID: String?
        var failures = 0
        /// After a failed chunk: resume from the server's offset. If the upload session is gone and the file is
        /// there at full size, the last chunk did land and only its response was lost.
        func recover(lastChunk: Bool) async -> String? {
            do {
                offset = try await tusOffset(uploadURL)
            } catch DAVError.notFound where lastChunk {
                if let done = try? await stat(childURL(parentID: parentID, name: name)), done.size == size { return done.id }
            } catch DAVError.http(410, _) where lastChunk {
                if let done = try? await stat(childURL(parentID: parentID, name: name)), done.size == size { return done.id }
            } catch {}
            return nil
        }
        while offset < size {
            try Task.checkCancellation()
            if progress?.isCancelled == true { throw CancellationError() }
            try handle.seek(toOffset: UInt64(offset))
            let want = Int(min(Int64(Self.tusChunkSize), size - offset))
            guard let chunk = try handle.read(upToCount: want), chunk.count == want else {
                throw DAVError.http(0, "The file changed while it was being uploaded.")
            }
            do {
                let http = try await tusPatch(uploadURL, chunk: chunk, offset: offset, base: offset, total: size, progress: progress)
                offset += Int64(chunk.count)
                failures = 0
                if let fid = http.value(forHTTPHeaderField: "OC-FileId"), !fid.isEmpty { fileID = fid }
            } catch let error as URLError where error.code != .cancelled {
                failures += 1
                if failures > 6 { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(failures, 5)) * 2_000_000_000)
                // The chunk may or may not have landed: ask the server where we are.
                if let done = await recover(lastChunk: offset + Int64(want) >= size) { return done }
            } catch DAVError.http(let code, _) where (500...599).contains(code) && failures < 6 {
                failures += 1
                try await Task.sleep(nanoseconds: UInt64(min(failures, 5)) * 2_000_000_000)
                if let done = await recover(lastChunk: offset + Int64(want) >= size) { return done }
            }
        }
        if let fileID { return fileID }
        // Zero-length edge or missing header: look the file up by name.
        return try await stat(childURL(parentID: parentID, name: name)).id
    }

    private func tusOffset(_ url: URL) async throws -> Int64 {
        let (_, http) = try await send("HEAD", url, headers: ["Tus-Resumable": "1.0.0"])
        guard let v = http.value(forHTTPHeaderField: "Upload-Offset"), let n = Int64(v) else { throw DAVError.invalidResponse }
        return n
    }

    private func tusPatch(_ url: URL, chunk: Data, offset: Int64, base: Int64, total: Int64, progress: Progress?) async throws -> HTTPURLResponse {
        var rejected: String?
        for attempt in 0..<2 {
            let token = try await tokens.accessToken(rejected: rejected)
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let delegate = TransferDelegate(progress: progress, base: base, total: total)
            let (data, resp) = try await transferSession.upload(for: req, from: chunk, delegate: delegate)
            guard let http = resp as? HTTPURLResponse else { throw DAVError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 { rejected = token; continue }
            try Self.check(http, data: data, expect: nil)
            return http
        }
        throw DAVError.unauthorized
    }

    /// The server's SHA-1 of a file's contents (lowercase hex), if it reports one.
    func sha1(id: String) async -> String? {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:checksums/></d:prop></d:propfind>
        """
        guard let (data, _) = try? await send("PROPFIND", idURL(id), headers: ["Depth": "0", "Content-Type": "application/xml"],
                                              body: body.data(using: .utf8)),
              let text = String(data: data, encoding: .utf8),
              let r = text.range(of: "SHA1:") else { return nil }
        let hex = text[r.upperBound...].prefix { $0.isHexDigit }
        return hex.count == 40 ? hex.lowercased() : nil
    }

    /// SHA-1 of a local file, read in pieces so large files don't have to fit in memory.
    static func sha1(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every file below a folder (capped so a huge tree can't run forever). Paths are filled in from `path`.
    func files(under folderID: String, path: String?) async -> [RemoteItem] {
        var out: [RemoteItem] = []
        var stack: [(id: String, path: String?)] = [(folderID, path)]
        var visited = 0
        while let next = stack.popLast(), visited < 2_000, out.count < 20_000 {
            visited += 1
            guard let (_, kids) = try? await listFolder(id: next.id) else { continue }
            for var k in kids {
                if k.path == nil, let base = next.path { k.path = base.isEmpty ? k.name : base + "/" + k.name }
                if k.isFolder { stack.append((k.id, k.path)) } else { out.append(k) }
            }
        }
        return out
    }

    enum UploadTarget {
        case new(parentID: String, name: String)
        case existing(id: String, ifMatch: String?)
    }

    // MARK: Mutations

    func createFolder(parentID: String, name: String) async throws -> RemoteItem {
        let url = childURL(parentID: parentID, name: name)
        let (_, http) = try await send("MKCOL", url, expect: [201, 405])
        if http.statusCode == 405 { throw DAVError.alreadyExists }
        return try await stat(url)
    }

    /// Moves and/or renames an item. Returns the updated item.
    func move(id: String, toParent parentID: String, name: String, overwrite: Bool = false) async throws -> RemoteItem {
        let dest = childURL(parentID: parentID, name: name)
        let (_, http) = try await send("MOVE", idURL(id), headers: ["Destination": dest.absoluteString,
                                                                     "Overwrite": overwrite ? "T" : "F"],
                                       expect: [201, 204, 412])
        if http.statusCode == 412 { throw DAVError.alreadyExists }
        return try await item(id: id)
    }

    func copy(id: String, toParent parentID: String, name: String) async throws -> RemoteItem {
        let dest = childURL(parentID: parentID, name: name)
        let (_, http) = try await send("COPY", idURL(id), headers: ["Destination": dest.absoluteString, "Overwrite": "F"],
                                       expect: [201, 204, 412])
        if http.statusCode == 412 { throw DAVError.alreadyExists }
        return try await stat(dest)
    }

    /// Moves the item to the server trash bin.
    func delete(id: String) async throws {
        do { try await send("DELETE", idURL(id), expect: [204, 200]) } catch DAVError.notFound { }
    }

    /// Picks a name that doesn't exist yet in the parent ("name (1).ext", "name (2).ext", ...).
    func availableName(parentID: String, desired: String) async throws -> String {
        if try await child(parentID: parentID, name: desired) == nil { return desired }
        let ext = (desired as NSString).pathExtension
        let base = (desired as NSString).deletingPathExtension
        for i in 1..<1000 {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if try await child(parentID: parentID, name: candidate) == nil { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    }

    // MARK: Trash

    func listTrash() async throws -> [RemoteItem] {
        let (data, _) = try await send("PROPFIND", trashURL, headers: ["Depth": "1", "Content-Type": "application/xml"],
                                       body: Self.trashBody)
        return DAVParser.parse(data).dropFirst().compactMap { r in
            let key = (r.href.removingPercentEncoding ?? r.href).split(separator: "/").last.map(String.init) ?? ""
            guard !key.isEmpty else { return nil }
            let p = r.props
            return RemoteItem(
                id: account.spaceID + "!" + key, parentID: nil,
                name: p["trashbin-original-filename"] ?? key, path: nil,
                isFolder: r.isCollection,
                size: Int64(p["getcontentlength"] ?? "") ?? Int64(p["size"] ?? "") ?? 0,
                modified: HTTPDate.parse(p["trashbin-delete-datetime"]), etag: "",
                contentType: p["getcontenttype"], permissions: "", tags: [], privateLink: nil,
                hasPreview: false, ownerName: nil,
                trashKey: key, originalLocation: p["trashbin-original-location"],
                deletedAt: HTTPDate.parse(p["trashbin-delete-datetime"]))
        }
    }

    func restore(trashKey: String, originalLocation: String) async throws {
        var location = originalLocation
        for attempt in 0..<20 {
            let dest = spacePathURL(location)
            let (_, http) = try await send("MOVE", trashItemURL(trashKey),
                                           headers: ["Destination": dest.absoluteString, "Overwrite": "F"],
                                           expect: [201, 204, 409, 412])
            if http.statusCode == 201 || http.statusCode == 204 { return }
            if http.statusCode == 409 { // parent folder gone: restore to root
                location = (originalLocation as NSString).lastPathComponent
                continue
            }
            // name taken: add a suffix
            let ext = (originalLocation as NSString).pathExtension
            let base = ((originalLocation as NSString).lastPathComponent as NSString).deletingPathExtension
            let dir = (location as NSString).deletingLastPathComponent
            let name = ext.isEmpty ? "\(base) (restored \(attempt + 1))" : "\(base) (restored \(attempt + 1)).\(ext)"
            location = dir.isEmpty || dir == "/" ? name : dir + "/" + name
        }
        throw DAVError.alreadyExists
    }

    func purge(trashKey: String) async throws {
        try await send("DELETE", trashItemURL(trashKey), expect: [204, 200, 404])
    }

    func emptyTrash() async throws {
        try await send("DELETE", trashURL, expect: [204, 200])
    }

    // MARK: Graph

    func setFavorite(id: String, _ on: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["resourceId": id, "tags": [AppConstants.favoriteTag]])
        try await send(on ? "PUT" : "DELETE", graphURL("extensions/org.libregraph/tags"),
                       headers: ["Content-Type": "application/json"], body: body)
    }

    func quota() async throws -> Quota {
        let (data, _) = try await send("GET", graphURL("drives/" + account.spaceID))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let q = json?["quota"] as? [String: Any]
        let used = (q?["used"] as? NSNumber)?.int64Value ?? 0
        let total = (q?["total"] as? NSNumber)?.int64Value
        return Quota(used: used, total: (total ?? 0) > 0 ? total : nil)
    }

    /// Download URL for a folder as a .zip via OpenCloud's archiver service.
    func archiveURL(id: String) -> URL {
        var c = URLComponents(string: serverRoot + "/archiver")!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url!
    }

    func thumbnail(id: String, size: Int) async -> Data? {
        var c = URLComponents(url: idURL(id), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "preview", value: "1"), .init(name: "x", value: "\(size)"),
                        .init(name: "y", value: "\(size)"), .init(name: "a", value: "1")]
        guard let url = c.url, let (data, http) = try? await send("GET", url) else { return nil }
        return http.statusCode == 200 ? data : nil
    }
}

/// Bridges URLSession per-task upload callbacks to a Progress. For chunked uploads, `base` is the number of
/// bytes already sent in earlier chunks and `total` the whole file's size.
final class TransferDelegate: NSObject, URLSessionTaskDelegate {
    let progress: Progress?
    let base: Int64
    let total: Int64?
    init(progress: Progress?, base: Int64 = 0, total: Int64? = nil) {
        self.progress = progress
        self.base = base
        self.total = total
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let progress else { return }
        if let total { progress.totalUnitCount = total }
        else if totalBytesExpectedToSend > 0 { progress.totalUnitCount = totalBytesExpectedToSend }
        progress.completedUnitCount = base + totalBytesSent
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        progress?.cancellationHandler = { [weak task] in task?.cancel() }
    }
}

/// Lets only a few transfers run at once; the rest wait their turn in order.
actor TransferGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
