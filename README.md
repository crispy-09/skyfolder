# Skyfolder

A Google-Drive-style macOS desktop client for [OpenCloud](https://opencloud.eu) servers.

> Independent project. Not affiliated with OpenCloud GmbH or Google.

- **App window**: Drive-like browser with My Files, Recent, Starred, Available offline and Trash. It has grid and list views, Type/Modified filters, drag-and-drop upload, folder upload, download (folders download as .zip), rename, move, copy, star, copy link, a details panel, trash with undo/restore and an upload/download progress panel.
- **Finder**: a File Provider extension puts "Skyfolder" in Finder's sidebar (`~/Library/CloudStorage/Skyfolder-Skyfolder`).
  Files are **online-only by default** and download when opened. Edits sync back automatically.
  Use **Make Available Offline** (Finder right-click or the app) to keep a file or folder downloaded. **Remove Offline Copy** frees the space again.
- Runs in the menu bar after the window closes. "Open at login" is in Settings.

## Build & install

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

## Server notes (OpenCloud 8.x)

- Sign-in: OIDC code + PKCE through the browser, client `OpenCloudDesktop`, loopback redirect `http://127.0.0.1:<port>`.
  Tokens are stored in the Keychain and shared with the extension through the app group.
- "Starred" is stored as the server tag `favorite`, because the favorites capability is off on stock OpenCloud.
  Starred items also show the tag in the web UI.
- Recent = KQL search `mtime:"last 30 days"`. Search = `name:"*term*"`.
- Deleting (app or Finder) moves items to the OpenCloud trash bin.
- Conflicts: if a file changed on the server while you edited it locally, your version is uploaded as
  `name (conflicted copy <date>).ext` and the server version is kept.

## Layout

- `Shared/`: account config, Keychain token store and refresh, WebDAV/Graph client, XML parser, pinned-items store
- `FileProvider/`: `NSFileProviderReplicatedExtension`, enumerators and the etag-based change scanner
- `App/`: SwiftUI app (model, views, sign-in flow, File Provider bridge)

## License

Copyright (C) 2026 crispy-09

Skyfolder is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License v3.0](LICENSE) as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY.
