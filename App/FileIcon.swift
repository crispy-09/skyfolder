import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum FileKind: String, CaseIterable, Identifiable {
    case folder, document, spreadsheet, presentation, pdf, image, video, audio, archive, code, text, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: return "Folders"
        case .document: return "Documents"
        case .spreadsheet: return "Spreadsheets"
        case .presentation: return "Presentations"
        case .pdf: return "PDFs"
        case .image: return "Photos & images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .archive: return "Archives (zip)"
        case .code: return "Code"
        case .text: return "Text"
        case .other: return "Other"
        }
    }

    var typeName: String {
        switch self {
        case .folder: return "Folder"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .presentation: return "Presentation"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .code: return "Code"
        case .text: return "Text"
        case .other: return "File"
        }
    }

    static func of(_ item: RemoteItem) -> FileKind {
        if item.isFolder { return .folder }
        let ext = item.fileExtension
        let t = item.utType
        if t.conforms(to: .pdf) { return .pdf }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(ext) { return .document }
        if ["xls", "xlsx", "ods", "csv", "numbers", "tsv"].contains(ext) { return .spreadsheet }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return .presentation }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .archive) || ["zip", "tar", "gz", "7z", "rar", "tgz", "bz2", "xz", "dmg", "iso"].contains(ext) { return .archive }
        if t.conforms(to: .sourceCode) || ["json", "yml", "yaml", "xml", "html", "css", "js", "ts", "sh", "py", "swift", "go", "rs"].contains(ext) { return .code }
        if t.conforms(to: .text) || ["md", "txt", "log"].contains(ext) { return .text }
        return .other
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .document: return "text.alignleft"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .archive: return "doc.zipper"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .folder: return Color(hex: 0x5F6368)
        case .document, .text: return Color(hex: 0x4285F4)
        case .spreadsheet: return Color(hex: 0x0F9D58)
        case .presentation: return Color(hex: 0xF4B400)
        case .pdf, .image, .video: return Color(hex: 0xEA4335)
        case .audio: return Color(hex: 0x9334E6)
        case .archive, .code, .other: return Color(hex: 0x5F6368)
        }
    }
}

/// Small colored type badge in the style of Drive's file icons.
struct FileIconView: View {
    let item: RemoteItem
    var size: CGFloat = 20

    var body: some View {
        let kind = FileKind.of(item)
        if kind == .folder {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.95))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(kind.color)
                .frame(width: size * 0.82, height: size * 0.82)
                .overlay(
                    Image(systemName: kind.symbol)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
        }
    }
}

/// Lazily loaded thumbnails: server previews when available, otherwise small images are fetched and downsampled.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.crispy-09.skyfolder/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    static func canThumbnail(_ item: RemoteItem) -> Bool {
        if item.hasPreview { return true }
        return FileKind.of(item) == .image && item.size > 0 && item.size < 15_000_000
            && !["svg", "psd", "ai", "eps"].contains(item.fileExtension)
    }

    func thumbnail(for item: RemoteItem, client: DAVClient) async -> NSImage? {
        let key = DriveModel.safeFileName("\(item.opaqueID)-\(item.etag)")
        if let img = memory.object(forKey: key as NSString) { return img }
        if let t = inflight[key] { return await t.value }
        let disk = diskDir.appendingPathComponent(key + ".png")
        let task = Task<NSImage?, Never> { [disk] in
            if let img = NSImage(contentsOf: disk) { return img }
            var data: Data?
            if item.hasPreview { data = await client.thumbnail(id: item.id, size: 512) }
            if data == nil, FileKind.of(item) == .image {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                if (try? await client.download(id: item.id, to: tmp)) != nil {
                    data = Self.downsample(url: tmp, maxPixel: 512)
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            guard let data, let img = NSImage(data: data) else { return nil }
            try? data.write(to: disk)
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }

    nonisolated static func downsample(url: URL, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
