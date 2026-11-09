import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep running in the menu bar after the window closes, like Drive for desktop.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SkyfolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DriveModel()

    var body: some Scene {
        Window("Skyfolder", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…") { model.dialog = PendingDialog(kind: .newFolder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.account == nil)
                Button("Upload Files…") { model.pickAndUpload(folders: false) }
                    .keyboardShortcut("u", modifiers: [.command])
                    .disabled(model.account == nil)
                Button("Upload Folder…") { model.pickAndUpload(folders: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.account == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.reload() }.keyboardShortcut("r", modifiers: .command)
                Button(model.viewMode == .grid ? "Show as List" : "Show as Grid") {
                    model.viewMode = model.viewMode == .grid ? .list : .grid
                }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button(model.showDetails ? "Hide Details" : "Show Details") { model.showDetails.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.transfers.contains { $0.state == .running } ? "icloud.and.arrow.up" : "cloud")
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct MenuBarContent: View {
    @Environment(DriveModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let acc = model.account {
            Text("\(acc.displayName) — \(acc.serverURL.host ?? "")")
            if model.sessionExpired { Text("Sign-in required") }
            else if let q = model.quota { Text("\(q.used.formattedBytes) used") }
            Divider()
            Button("Open Skyfolder") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Open in Finder") { model.openInFinder() }.disabled(!model.finderEnabled)
            Button("Open Web Version") { model.openWeb() }
        } else {
            Button("Sign In…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Skyfolder") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct RootView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Group {
            if model.account == nil {
                LoginView()
            } else {
                DriveView()
            }
        }
        .background(Theme.background)
    }
}

struct SettingsView: View {
    @Environment(DriveModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var model = model
        Form {
            if let acc = model.account {
                Section("Account") {
                    LabeledContent("Name", value: acc.displayName)
                    LabeledContent("User", value: acc.username)
                    LabeledContent("Server", value: acc.serverURL.absoluteString)
                    if let q = model.quota {
                        LabeledContent("Storage", value: q.total.map { "\(q.used.formattedBytes) of \($0.formattedBytes)" }
                                       ?? "\(q.used.formattedBytes) used")
                    }
                }
                Section("Finder") {
                    LabeledContent("Status", value: model.finderEnabled ? "Skyfolder is in Finder's sidebar" :
                                    (model.finderError ?? "Not available"))
                    Text("Files are online-only by default and download when you open them. Right-click any file or folder and choose “Make Available Offline” to keep it on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open in Finder") { model.openInFinder() }.disabled(!model.finderEnabled)
                }
                Section {
                    Toggle("Open at login", isOn: $model.openAtLogin)
                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                }
            } else {
                Text("Not signed in.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .confirmationDialog("Sign out of OpenCloud?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        } message: {
            Text("Skyfolder will be removed from Finder and offline copies on this Mac are deleted. Your files stay on the server.")
        }
    }
}
