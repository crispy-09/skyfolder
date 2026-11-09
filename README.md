# Skyfolder

A Google-Drive-style desktop client for [OpenCloud](https://opencloud.eu) servers, for macOS, Windows and Linux.

> Independent project. Not affiliated with OpenCloud GmbH or Google.

- **App window**: Drive-like browser with My Files, Recent, Starred, Available offline and Trash. It has grid and list views, Type/Modified filters, drag-and-drop upload, folder upload, download (folders download as .zip), rename, move, copy, star, copy link, a details panel, trash with undo/restore and an upload/download progress panel.
- **Finder**: a File Provider extension puts "Skyfolder" in Finder's sidebar (`~/Library/CloudStorage/Skyfolder-Skyfolder`).
  Files are **online-only by default** and download when opened. Edits sync back automatically.
  Use **Make Available Offline** (Finder right-click or the app) to keep a file or folder downloaded. **Remove Offline Copy** frees the space again.
- Runs in the menu bar after the window closes. "Open at login" is in Settings.

## Platforms

| | App | File manager integration | Status |
|---|---|---|---|
| macOS | SwiftUI (repo root) | Finder, File Provider extension | Tested |
| Linux | Tauri (`desktop/`) | `~/Skyfolder`, FUSE mount | Tested on Ubuntu 26.04 (arm64) |
| Windows | Tauri (`desktop/`) | `%USERPROFILE%\Skyfolder`, Cloud Files (like OneDrive) | Tested on Windows (x64) |

The Windows and Linux app has the same window as the Mac app: the same views, filters, uploads and
downloads, trash and offline handling.

## Build & install (macOS)

```sh
brew install xcodegen      # once
./scripts/install.sh       # builds Release, installs to /Applications, launches
```

Requirements: macOS 15 or later, Xcode 16 or later, and an Apple ID added in Xcode → Settings → Accounts
(a free account works).

**Building it yourself:** set `DEVELOPMENT_TEAM` in `project.yml` to your own team ID. Change the
`io.github.crispy-09` prefix in `project.yml`, both `.entitlements` files and `Shared/AppConstants.swift`
(the app group must start with your team ID). With a free Apple ID, the provisioning profile expires after
7 days. When it does, re-run `./scripts/install.sh`.

## Windows & Linux

Download installers from [Releases](https://github.com/crispy-09/skyfolder/releases) (`desktop-v*`). They're built by GitHub Actions
([`desktop.yml`](.github/workflows/desktop.yml)). They are unsigned, so Windows SmartScreen will warn on first run.

To build it yourself, install Rust (rustup) and Node.js 20 or later. On Linux, also install the Tauri
dependencies and FUSE 3:

```sh
# Debian/Ubuntu
sudo apt install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
  libssl-dev libdbus-1-dev fuse3

cd desktop
npm ci
npx tauri build        # installers land in desktop/target/release/bundle/
npx tauri dev          # or run it straight from source
```

**Linux:** your drive is mounted at `~/Skyfolder` while the app runs (it keeps running in the tray when the
window is closed). Files download when opened and are cached (5 GB by default, oldest evicted first;
set `SKYFOLDER_CACHE_LIMIT_MB` to change it). Saving a file uploads it. "Make available offline" keeps
files in the cache permanently.

**Windows:** Skyfolder registers a cloud-files folder at `%USERPROFILE%\Skyfolder`. It shows in
Explorer's navigation pane with the usual cloud and check-mark icons, and Explorer's "Always keep on this
device" and "Free up space" work. Editor temp files (`~$…`, `*.tmp`) are never uploaded. Signing out
removes the folder. If it still holds changes that never reached the server, it is renamed to
`Skyfolder (unsynced files)` instead.

`desktop/crates/cli` is a small command-line client used for testing (`skyfolder-cli selftest`,
`ls`, `cat`, `mount`).

## Server notes (OpenCloud 8.x)

- Sign-in: OIDC code + PKCE through the browser, client `OpenCloudDesktop`, loopback redirect `http://127.0.0.1:<port>`.
  Tokens are stored in the Keychain on macOS (shared with the extension through the app group), Windows
  Credential Manager on Windows, and the Secret Service keyring on Linux. Without a keyring, Linux falls back
  to a file only your user can read.
- "Starred" is stored as the server tag `favorite`, because the favorites capability is off on stock OpenCloud.
  Starred items also show the tag in the web UI.
- Recent = KQL search `mtime:"last 30 days"`. Search = `name:"*term*"`.
- Deleting (in the app or the file manager) moves items to the OpenCloud trash bin.
- Conflicts: if a file changed on the server while you edited it locally, your version is uploaded as
  `name (conflicted copy <date>).ext` and the server version is kept.

## Layout

- `Shared/`: account config, Keychain token store and refresh, WebDAV/Graph client, XML parser, pinned-items store
- `FileProvider/`: `NSFileProviderReplicatedExtension`, enumerators and the etag-based change scanner
- `App/`: SwiftUI app (model, views, sign-in flow, File Provider bridge)
- `desktop/`: Windows/Linux app
  - `src/`: Svelte UI
  - `src-tauri/`: Tauri shell and commands
  - `crates/core`: WebDAV/Graph client, sign-in, token storage
  - `crates/fuse`: Linux FUSE file system
  - `crates/winsync`: Windows Cloud Files engine
  - `crates/cli`: test CLI

## License

Copyright (C) 2026 crispy-09

Skyfolder is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License v3.0](LICENSE) as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY.
