import SwiftUI

// MARK: Context menu

struct ItemMenuItems: View {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem
    var inHeader = false

    var body: some View {
        let targets = inHeader ? [item] : model.targets(for: item)
        let single = targets.count == 1
        if model.section == .trash {
            Button { model.restore(targets) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { model.dialog = PendingDialog(kind: .deleteForever(targets)) } label: {
                Label("Delete forever", systemImage: "trash.slash")
            }
        } else {
            if single && !inHeader {
                Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            }
            if single {
                Button { model.showInFinder(item) } label: { Label("Show in Finder", systemImage: "macwindow") }
                    .disabled(!model.finderEnabled)
                Button { model.openWeb(item) } label: { Label("Open in web browser", systemImage: "globe") }
            }
            Divider()
            Button { model.download(targets) } label: { Label("Download", systemImage: "arrow.down.to.line") }
            if single {
                Button { model.dialog = PendingDialog(kind: .rename(item)) } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(!item.canRename)
                if !item.isFolder {
                    Button { model.makeCopy(item) } label: { Label("Make a copy", systemImage: "plus.square.on.square") }
                }
            }
            Divider()
            if single {
                Button { model.copyLink(item) } label: { Label("Copy link", systemImage: "link") }
            }
            Button { model.moveTargets = targets } label: { Label("Move to…", systemImage: "folder") }
            let starred = targets.allSatisfy(\.isFavorite)
            Button { model.setStarred(targets, !starred) } label: {
                Label(starred ? "Remove from Starred" : "Add to Starred", systemImage: starred ? "star.slash" : "star")
            }
            let offline = targets.allSatisfy { model.isPinned($0) }
            Button { model.setOffline(targets, on: !offline) } label: {
                Label(offline ? "Remove offline copy" : "Make available offline",
                      systemImage: offline ? "icloud" : "checkmark.circle")
            }
            if single {
                Button {
                    model.selection = [item.id]
                    model.showDetails = true
                } label: { Label("File information", systemImage: "info.circle") }
            }
            Divider()
            Button(role: .destructive) { model.trash(targets) } label: { Label("Move to trash", systemImage: "trash") }
                .disabled(!targets.allSatisfy(\.canDelete))
        }
    }
}

struct MoreButton: View {
    let item: RemoteItem

    var body: some View {
        Menu {
            ItemMenuItems(item: item)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .hoverBackground(selected: false, cornerRadius: 15, hoverColor: Theme.itemHover.opacity(0.8))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

struct ItemBadges: View {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem

    var body: some View {
        HStack(spacing: 4) {
            if item.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .help("Starred")
            }
            if model.section != .trash && model.isOffline(item) {
                let kept = model.isPinned(item) || !model.downloaded.contains(item.id)
                Image(systemName: kept ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .help(kept ? "Always kept on this Mac" : "Downloaded to this Mac")
            }
        }
    }
}

/// Click / double-click / context-menu behavior shared by tiles and rows.
struct ItemInteraction: ViewModifier {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem
    let list: [RemoteItem]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { model.open(item) })
            .simultaneousGesture(TapGesture().onEnded { model.click(item, in: list) })
            .contextMenu { ItemMenuItems(item: item) }
    }
}

extension View {
    func itemInteraction(_ item: RemoteItem, list: [RemoteItem]) -> some View {
        modifier(ItemInteraction(item: item, list: list))
    }
}

// MARK: Grid

struct GridContent: View {
    @Environment(DriveModel.self) private var model
    let items: [RemoteItem]
    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 16)]

    var body: some View {
        let folders = items.filter(\.isFolder)
        let files = items.filter { !$0.isFolder }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !folders.isEmpty {
                    sectionHeader("Folders")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(folders) { f in
                            FolderTile(item: f).itemInteraction(f, list: items)
                        }
                    }
                }
                if !files.isEmpty {
                    sectionHeader("Files").padding(.top, folders.isEmpty ? 0 : 10)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(files) { f in
                            FileCard(item: f).itemInteraction(f, list: items)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 80)
            .padding(.top, 6)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = [] })
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
    }
}

struct FolderTile: View {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem
    @State private var dropTarget = false

    var body: some View {
        let selected = model.selection.contains(item.id)
        HStack(spacing: 12) {
            FileIconView(item: item, size: 22)
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            ItemBadges(item: item)
            Spacer(minLength: 0)
            MoreButton(item: item)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 50)
        .hoverBackground(selected: selected || dropTarget, cornerRadius: 12, baseColor: Theme.tile)
        .help(item.name)
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls, toFolderID: item.id)
            return true
        } isTargeted: { dropTarget = $0 }
    }
}

struct FileCard: View {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem
    @State private var thumb: NSImage?

    var body: some View {
        let selected = model.selection.contains(item.id)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FileIconView(item: item, size: 20)
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                MoreButton(item: item)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 46)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    FileIconView(item: item, size: 64).opacity(0.9)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                ItemBadges(item: item)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
        .hoverBackground(selected: selected, cornerRadius: 12, baseColor: Theme.tile)
        .help(item.name)
        .task(id: item.etag) {
            guard ThumbnailLoader.canThumbnail(item), let client = model.client else { return }
            thumb = await ThumbnailLoader.shared.thumbnail(for: item, client: client)
        }
    }

    private var subtitle: String {
        if model.section == .recent || model.section == .starred, let d = item.modified {
            return "Modified " + DateText.short(d)
        }
        if let d = item.modified { return "You modified · " + DateText.short(d) }
        return item.size.formattedBytes
    }
}

// MARK: List

struct ListContent: View {
    @Environment(DriveModel.self) private var model
    let items: [RemoteItem]

    var body: some View {
        VStack(spacing: 0) {
            ListHeader()
                .padding(.horizontal, 20)
            Divider().overlay(Theme.divider).padding(.horizontal, 20)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.section == .recent {
                        ForEach(groupedByRecency(items), id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                            ForEach(group.1) { it in row(it) }
                        }
                    } else {
                        ForEach(items) { it in row(it) }
                    }
                }
                .padding(.bottom, 80)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = [] })
        }
    }

    private func row(_ it: RemoteItem) -> some View {
        VStack(spacing: 0) {
            ListRow(item: it).itemInteraction(it, list: items)
            Divider().overlay(Theme.divider)
        }
        .padding(.horizontal, 20)
    }

    private func groupedByRecency(_ items: [RemoteItem]) -> [(String, [RemoteItem])] {
        let cal = Calendar.current
        var groups: [(String, [RemoteItem])] = []
        func add(_ key: String, _ it: RemoteItem) {
            if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1.append(it) } else { groups.append((key, [it])) }
        }
        for it in items {
            guard let d = it.modified else { add("Older", it); continue }
            if cal.isDateInToday(d) { add("Today", it) }
            else if cal.isDateInYesterday(d) { add("Yesterday", it) }
            else if d > Date().addingTimeInterval(-7 * 86400) { add("Earlier this week", it) }
            else { add("Earlier this month", it) }
        }
        return groups
    }
}

struct ListColumns {
    static let owner: CGFloat = 140
    static let modified: CGFloat = 170
    static let size: CGFloat = 110
    static let actions: CGFloat = 150
}

struct ListHeader: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            sortButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            if model.section == .trash {
                Text("Original location").frame(width: ListColumns.owner + 60, alignment: .leading)
                Text("Date deleted").frame(width: ListColumns.modified, alignment: .leading)
            } else {
                Text(model.section == .myFiles ? "Owner" : "Location").frame(width: ListColumns.owner, alignment: .leading)
                sortButton(model.section == .recent ? "Last modified" : "Last modified", .modified)
                    .frame(width: ListColumns.modified, alignment: .leading)
            }
            sortButton("File size", .size).frame(width: ListColumns.size, alignment: .leading)
            Color.clear.frame(width: ListColumns.actions)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .frame(height: 44)
    }

    @ViewBuilder
    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        let sortable = model.section != .recent && model.section != .trash
        if sortable {
            Button { model.setSort(key) } label: {
                HStack(spacing: 4) {
                    Text(title)
                    if model.sortKey == key {
                        Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down").font(.system(size: 11, weight: .bold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(title)
        }
    }
}

struct ListRow: View {
    @Environment(DriveModel.self) private var model
    let item: RemoteItem
    @State private var hovering = false

    var body: some View {
        let selected = model.selection.contains(item.id)
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                FileIconView(item: item, size: 22)
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ItemBadges(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)

            if model.section == .trash {
                Text(locationText(item.originalLocation.map { ($0 as NSString).deletingLastPathComponent }))
                    .frame(width: ListColumns.owner + 60, alignment: .leading)
                Text(item.deletedAt.map(DateText.short) ?? "—")
                    .frame(width: ListColumns.modified, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    if model.section == .myFiles {
                        Avatar(name: model.account?.displayName ?? "", size: 22)
                        Text("me")
                    } else {
                        Image(systemName: "folder").font(.system(size: 12))
                        Text(locationText(item.parentPath))
                    }
                }
                .lineLimit(1)
                .frame(width: ListColumns.owner, alignment: .leading)
                Text(item.modified.map(DateText.short) ?? "—")
                    .frame(width: ListColumns.modified, alignment: .leading)
            }
            Text(item.isFolder ? "—" : item.size.formattedBytes)
                .frame(width: ListColumns.size, alignment: .leading)

            HStack(spacing: 0) {
                if hovering && model.section != .trash {
                    quick("arrow.down.to.line", "Download") { model.download([item]) }
                    quick("pencil", "Rename") { model.dialog = PendingDialog(kind: .rename(item)) }
                    quick(item.isFavorite ? "star.fill" : "star", item.isFavorite ? "Remove from Starred" : "Add to Starred") {
                        model.setStarred([item], !item.isFavorite)
                    }
                } else if hovering {
                    quick("arrow.uturn.backward", "Restore") { model.restore([item]) }
                }
                MoreButton(item: item)
            }
            .frame(width: ListColumns.actions, alignment: .trailing)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 48)
        .hoverBackground(selected: selected, cornerRadius: 0, hoverColor: Theme.tile)
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard item.isFolder else { return false }
            model.upload(urls, toFolderID: item.id)
            return true
        }
    }

    private func locationText(_ path: String?) -> String {
        guard let path else { return "—" }
        return path.isEmpty ? "My Files" : (path as NSString).lastPathComponent
    }

    private func quick(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

enum DateText {
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.month(.abbreviated).day())
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
