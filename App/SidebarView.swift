import SwiftUI

struct SidebarView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NewButton()
                .padding(.leading, 8)
                .padding(.bottom, 16)

            VStack(spacing: 1) {
                NavRow(title: "My Files", icon: "externaldrive", selectedIcon: "externaldrive.fill",
                       selected: model.section == .myFiles) { model.go(.myFiles) }
                NavRow(title: "Recent", icon: "clock", selectedIcon: "clock.fill",
                       selected: model.section == .recent) { model.go(.recent) }
                NavRow(title: "Starred", icon: "star", selectedIcon: "star.fill",
                       selected: model.section == .starred) { model.go(.starred) }
                NavRow(title: "Available offline", icon: "checkmark.circle", selectedIcon: "checkmark.circle.fill",
                       selected: model.section == .offline) { model.go(.offline) }
                    .help("Files and folders kept downloaded on this Mac")
                NavRow(title: "Trash", icon: "trash", selectedIcon: "trash.fill",
                       selected: model.section == .trash) { model.go(.trash) }
            }

            Divider().overlay(Theme.divider).padding(.vertical, 12).padding(.trailing, 8)

            if model.finderEnabled {
                NavRow(title: "Open in Finder", icon: "macwindow", selectedIcon: "macwindow", selected: false) {
                    model.openInFinder()
                }
            } else if let err = model.finderError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Finder integration off", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                    Text(err).font(.system(size: 11)).lineLimit(4)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 24)
            }

            StorageView()
                .padding(.leading, 24)
                .padding(.trailing, 16)
                .padding(.top, 12)

            Spacer()
        }
        .padding(.top, 4)
    }
}

struct NewButton: View {
    @Environment(DriveModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Menu {
            Button { model.dialog = PendingDialog(kind: .newFolder) } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Button { model.pickAndUpload(folders: false) } label: {
                Label("File upload", systemImage: "doc.badge.arrow.up")
            }
            Button { model.pickAndUpload(folders: true) } label: {
                Label("Folder upload", systemImage: "folder.badge.gearshape")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                Text("New")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hovering ? Theme.itemHover : Theme.newButton)
                    .shadow(color: .black.opacity(0.18), radius: hovering ? 3 : 1.5, y: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(model.section == .trash)
    }
}

struct NavRow: View {
    let title: String
    let icon: String
    let selectedIcon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
            .hoverBackground(selected: selected, cornerRadius: 17, selectedColor: Theme.navSelected,
                             hoverColor: Theme.navHover)
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }
}

struct StorageView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if let q = model.quota {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud").foregroundStyle(Theme.textSecondary)
                    Text("Storage").font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                }
                if let total = q.total {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.progressTrack)
                            Capsule().fill(Theme.accent)
                                .frame(width: max(4, geo.size.width * min(1, Double(q.used) / Double(total))))
                        }
                    }
                    .frame(height: 4)
                    Text("\(q.used.formattedBytes) of \(total.formattedBytes) used")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(q.used.formattedBytes) used")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
