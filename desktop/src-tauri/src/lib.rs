//! Skyfolder desktop (Windows/Linux) backend: Tauri commands over skyfolder-core, plus the platform
//! file-manager integration (FUSE on Linux, Cloud Files on Windows).

mod sync;

use base64::Engine as _;
use serde::Serialize;
use skyfolder_core::store::{PinInfo, PinnedStore};
use skyfolder_core::{auth, paths, Account, DavClient, DavError, RemoteItem, TokenProvider, UploadTarget};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_opener::OpenerExt;
use tokio::sync::RwLock;

struct Session {
    client: Arc<DavClient>,
    sync: Option<sync::Sync>,
    sync_error: Option<String>,
}

#[derive(Default)]
struct AppState {
    session: RwLock<Option<Session>>,
}

type CmdResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Errors that mean "sign in again" are prefixed so the UI can react.
fn dav_err(e: DavError) -> String {
    if e.is_auth() {
        format!("AUTH:{e}")
    } else {
        e.to_string()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionInfo {
    account: Account,
    sync_root: Option<String>,
    sync_error: Option<String>,
    platform: &'static str,
}

fn info(s: &Session) -> SessionInfo {
    SessionInfo {
        account: s.client.account.clone(),
        sync_root: s.sync.as_ref().map(|_| paths::drive_root().to_string_lossy().to_string()),
        sync_error: s.sync_error.clone(),
        platform: std::env::consts::OS,
    }
}

async fn client(state: &State<'_, AppState>) -> CmdResult<Arc<DavClient>> {
    state.session.read().await.as_ref().map(|s| s.client.clone()).ok_or_else(|| "AUTH:You're not signed in.".to_string())
}

async fn start_session(account: Account) -> Session {
    let tokens = TokenProvider::new(&account);
    let client = Arc::new(DavClient::new(account, tokens));
    let (sync, sync_error) = match sync::Sync::start(client.clone()).await {
        Ok(s) => (Some(s), None),
        Err(e) => {
            tracing::error!("file manager integration unavailable: {e:#}");
            (None, Some(format!("{e:#}")))
        }
    };
    Session { client, sync, sync_error }
}

// ---------------- session ----------------

#[tauri::command]
async fn get_session(state: State<'_, AppState>) -> CmdResult<Option<SessionInfo>> {
    {
        let s = state.session.read().await;
        if let Some(s) = s.as_ref() {
            return Ok(Some(info(s)));
        }
    }
    let Some(account) = Account::load() else { return Ok(None) };
    if auth::store::load().is_none() {
        return Ok(None);
    }
    let s = start_session(account).await;
    let i = info(&s);
    *state.session.write().await = Some(s);
    Ok(Some(i))
}

#[tauri::command]
async fn sign_in(app: AppHandle, state: State<'_, AppState>, server: String) -> CmdResult<SessionInfo> {
    let opener = app.clone();
    let (account, tokens) = auth::sign_in(&server, move |url| {
        let _ = opener.opener().open_url(url, None::<&str>);
    })
    .await
    .map_err(err)?;
    let mut account = account;
    auth::store::save(&tokens);
    // Confirm the root id via WebDAV (authoritative).
    let probe = DavClient::new(account.clone(), TokenProvider::new(&account));
    if let Ok(root) = probe.item_by_path("").await {
        account.root_id = root.id;
    }
    account.save().map_err(err)?;
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
    let s = start_session(account).await;
    let i = info(&s);
    *state.session.write().await = Some(s);
    Ok(i)
}

#[tauri::command]
async fn sign_out(app: AppHandle, state: State<'_, AppState>) -> CmdResult<()> {
    if let Some(s) = state.session.write().await.take() {
        if let Some(sync) = s.sync {
            sync.shutdown(true).await;
        }
    }
    auth::store::clear();
    Account::clear();
    PinnedStore::clear();
    let _ = std::fs::remove_dir_all(paths::cache_dir());
    let _ = std::fs::remove_dir_all(open_copies_dir());
    let _ = app.emit("signed-out", ());
    Ok(())
}

// ---------------- listing ----------------

#[derive(Serialize)]
struct Listing {
    folder: Option<RemoteItem>,
    items: Vec<RemoteItem>,
}

#[tauri::command]
async fn list(state: State<'_, AppState>, path: String) -> CmdResult<Listing> {
    let c = client(&state).await?;
    let (folder, items) = c.list_path(&path).await.map_err(dav_err)?;
    Ok(Listing { folder, items })
}

#[tauri::command]
async fn recent(state: State<'_, AppState>) -> CmdResult<Vec<RemoteItem>> {
    let c = client(&state).await?;
    Ok(c.search("mtime:\"last 30 days\"", 300).await.map_err(dav_err)?.into_iter().filter(|i| !i.is_folder).collect())
}

#[tauri::command]
async fn starred(state: State<'_, AppState>) -> CmdResult<Vec<RemoteItem>> {
    let c = client(&state).await?;
    c.search(&format!("tag:{}", skyfolder_core::FAVORITE_TAG), 500).await.map_err(dav_err)
}

#[tauri::command]
async fn search(state: State<'_, AppState>, query: String) -> CmdResult<Vec<RemoteItem>> {
    let c = client(&state).await?;
    let q = query.replace('"', "");
    c.search(&format!("name:\"*{q}*\""), 300).await.map_err(dav_err)
}

#[tauri::command]
async fn trash(state: State<'_, AppState>) -> CmdResult<Vec<RemoteItem>> {
    client(&state).await?.list_trash().await.map_err(dav_err)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OfflineState {
    pinned: Vec<String>,
    pinned_folders: Vec<String>, // paths
    downloaded: Vec<String>,
}

#[tauri::command]
async fn offline_state(state: State<'_, AppState>) -> CmdResult<OfflineState> {
    let pins = PinnedStore::all();
    let downloaded = state.session.read().await.as_ref().and_then(|s| s.sync.as_ref().map(|y| y.cached_ids())).unwrap_or_default();
    Ok(OfflineState {
        pinned: pins.keys().cloned().collect(),
        pinned_folders: pins.values().filter(|p| p.is_folder).filter_map(|p| p.path.clone()).collect(),
        downloaded,
    })
}

/// Items kept offline or currently downloaded.
#[tauri::command]
async fn offline_items(state: State<'_, AppState>) -> CmdResult<Vec<RemoteItem>> {
    let c = client(&state).await?;
    let pins = PinnedStore::all();
    let mut ids: Vec<String> = pins.keys().cloned().collect();
    if let Some(s) = state.session.read().await.as_ref().and_then(|s| s.sync.as_ref()) {
        for id in s.cached_ids() {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    let mut out = Vec::new();
    for id in ids {
        if let Ok(mut it) = c.item_by_id(&id).await {
            if it.path.is_none() {
                it.path = pins.get(&id).and_then(|p| p.path.clone());
            }
            out.push(it);
        }
    }
    Ok(out)
}

#[tauri::command]
async fn quota(state: State<'_, AppState>) -> CmdResult<skyfolder_core::Quota> {
    client(&state).await?.quota().await.map_err(dav_err)
}

// ---------------- mutations ----------------

#[tauri::command]
async fn create_folder(state: State<'_, AppState>, parent_id: String, name: String) -> CmdResult<RemoteItem> {
    let name = name.trim().to_string();
    if name.is_empty() || name.contains('/') {
        return Err("Enter a valid folder name.".into());
    }
    client(&state).await?.create_folder(&parent_id, &name).await.map_err(dav_err)
}

#[tauri::command]
async fn rename_item(state: State<'_, AppState>, id: String, parent_id: String, name: String) -> CmdResult<RemoteItem> {
    let name = name.trim().to_string();
    if name.is_empty() || name.contains('/') {
        return Err("Enter a valid name.".into());
    }
    client(&state).await?.move_item(&id, &parent_id, &name, false).await.map_err(dav_err)
}

#[tauri::command]
async fn move_items(state: State<'_, AppState>, items: Vec<RemoteItem>, dest_id: String) -> CmdResult<()> {
    let c = client(&state).await?;
    for it in items.iter().filter(|i| i.id != dest_id) {
        c.move_item(&it.id, &dest_id, &it.name, false).await.map_err(dav_err)?;
    }
    Ok(())
}

#[tauri::command]
async fn copy_item(state: State<'_, AppState>, item: RemoteItem) -> CmdResult<RemoteItem> {
    let c = client(&state).await?;
    let parent = item.parent_id.clone().unwrap_or_else(|| c.account.root_id.clone());
    let name = c.available_name(&parent, &format!("Copy of {}", item.name)).await.map_err(dav_err)?;
    c.copy_item(&item.id, &parent, &name).await.map_err(dav_err)
}

#[tauri::command]
async fn trash_items(state: State<'_, AppState>, items: Vec<RemoteItem>) -> CmdResult<()> {
    let c = client(&state).await?;
    for it in &items {
        c.delete(&it.id).await.map_err(dav_err)?;
        PinnedStore::set(&it.id, false, None);
    }
    Ok(())
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestoreRef {
    key: String,
    location: String,
}

#[tauri::command]
async fn restore_items(state: State<'_, AppState>, items: Vec<RestoreRef>) -> CmdResult<()> {
    let c = client(&state).await?;
    for r in items {
        c.restore(&r.key, &r.location).await.map_err(dav_err)?;
    }
    Ok(())
}

#[tauri::command]
async fn delete_forever(state: State<'_, AppState>, keys: Vec<String>) -> CmdResult<()> {
    let c = client(&state).await?;
    for k in keys {
        c.purge(&k).await.map_err(dav_err)?;
    }
    Ok(())
}

#[tauri::command]
async fn empty_trash(state: State<'_, AppState>) -> CmdResult<()> {
    client(&state).await?.empty_trash().await.map_err(dav_err)
}

#[tauri::command]
async fn set_starred(state: State<'_, AppState>, ids: Vec<String>, on: bool) -> CmdResult<()> {
    let c = client(&state).await?;
    for id in ids {
        c.set_favorite(&id, on).await.map_err(dav_err)?;
    }
    Ok(())
}

#[tauri::command]
async fn set_offline(state: State<'_, AppState>, items: Vec<RemoteItem>, on: bool) -> CmdResult<()> {
    let guard = state.session.read().await;
    let s = guard.as_ref().ok_or("AUTH:You're not signed in.")?;
    let Some(sync) = s.sync.as_ref() else {
        return Err("The file manager integration isn't running, so files can't be kept offline.".into());
    };
    for it in &items {
        PinnedStore::set(&it.id, on, Some(PinInfo { name: it.name.clone(), is_folder: it.is_folder, path: it.path.clone() }));
    }
    sync.set_offline(&items, on).await;
    Ok(())
}

// ---------------- open / reveal ----------------

fn open_copies_dir() -> PathBuf {
    std::env::temp_dir().join("skyfolder-open")
}

fn local_path(item_path: &str) -> PathBuf {
    let mut p = paths::drive_root();
    for comp in item_path.split('/').filter(|c| !c.is_empty()) {
        p.push(comp);
    }
    p
}

#[tauri::command]
async fn open_item(app: AppHandle, state: State<'_, AppState>, item: RemoteItem) -> CmdResult<()> {
    let (c, has_sync) = {
        let g = state.session.read().await;
        let s = g.as_ref().ok_or("AUTH:You're not signed in.")?;
        (s.client.clone(), s.sync.is_some())
    };
    // Preferred: open through the synced folder so edits are uploaded automatically.
    if has_sync {
        if let Some(p) = item.path.as_deref() {
            let lp = local_path(p);
            if app.opener().open_path(lp.to_string_lossy(), None::<&str>).is_ok() {
                return Ok(());
            }
        }
    }
    // Fallback: download a temporary copy.
    let dir = open_copies_dir().join(skyfolder_core::safe_file_name(item.opaque_id()));
    std::fs::create_dir_all(&dir).map_err(err)?;
    let dest = dir.join(skyfolder_core::safe_file_name(&item.name));
    c.download(&item.id, &dest, None).await.map_err(dav_err)?;
    app.opener().open_path(dest.to_string_lossy(), None::<&str>).map_err(err)
}

#[tauri::command]
async fn reveal_item(app: AppHandle, item: RemoteItem) -> CmdResult<()> {
    let p = item.path.as_deref().ok_or("This item's location is unknown.")?;
    app.opener().reveal_item_in_dir(local_path(p)).map_err(err)
}

#[tauri::command]
async fn open_drive_folder(app: AppHandle) -> CmdResult<()> {
    app.opener().open_path(paths::drive_root().to_string_lossy(), None::<&str>).map_err(err)
}

#[tauri::command]
async fn open_web(app: AppHandle, state: State<'_, AppState>, id: Option<String>) -> CmdResult<()> {
    let c = client(&state).await?;
    let url = id.map(|i| c.account.web_url(&i)).unwrap_or_else(|| c.account.server_url.clone());
    app.opener().open_url(url, None::<&str>).map_err(err)
}

// ---------------- transfers ----------------

static NEXT_TRANSFER: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TransferEvent {
    id: u64,
    kind: &'static str,
    name: String,
    is_folder: bool,
    done: u64,
    total: u64,
    state: &'static str, // running | done | failed
    error: Option<String>,
    result_path: Option<String>,
}

fn emit(app: &AppHandle, ev: &TransferEvent) {
    let _ = app.emit("transfer", ev.clone());
}

#[tauri::command]
async fn upload_paths(app: AppHandle, state: State<'_, AppState>, paths: Vec<String>, parent_id: String) -> CmdResult<()> {
    let c = client(&state).await?;
    for p in paths {
        let c = c.clone();
        let app = app.clone();
        let parent_id = parent_id.clone();
        tokio::spawn(async move {
            let path = PathBuf::from(&p);
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            let mut ev = TransferEvent {
                id: NEXT_TRANSFER.fetch_add(1, Ordering::SeqCst),
                kind: "upload",
                name: name.clone(),
                is_folder: path.is_dir(),
                done: 0,
                total: 1,
                state: "running",
                error: None,
                result_path: None,
            };
            emit(&app, &ev);
            let res = upload_entry(&app, &c, &path, &parent_id, &mut ev).await;
            match res {
                Ok(()) => {
                    ev.state = "done";
                    ev.done = ev.total;
                }
                Err(e) => {
                    ev.state = "failed";
                    ev.error = Some(e);
                }
            }
            emit(&app, &ev);
            let _ = app.emit("changed", ());
        });
    }
    Ok(())
}

async fn upload_entry(app: &AppHandle, c: &DavClient, path: &Path, parent_id: &str, ev: &mut TransferEvent) -> Result<(), String> {
    let mtime = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64);
    if path.is_file() {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let target = c.available_name(parent_id, &name).await.map_err(dav_err)?;
        ev.total = std::fs::metadata(path).map(|m| m.len()).unwrap_or(1).max(1);
        let app2 = app.clone();
        let base = ev.clone();
        let progress: Arc<dyn Fn(u64, u64) + Send + Sync> = Arc::new(move |done, total| {
            let mut e = base.clone();
            e.done = done;
            e.total = total.max(1);
            emit(&app2, &e);
        });
        c.upload(path, UploadTarget::New { parent_id, name: &target }, mtime(path), Some(progress)).await.map_err(dav_err)?;
        return Ok(());
    }
    // Folder: mirror the tree; never overwrite existing files (keep both).
    let mut files = Vec::new();
    let mut dirs = Vec::new();
    collect(path, path, &mut files, &mut dirs);
    ev.total = files.len().max(1) as u64;
    let root_name = path.file_name().unwrap().to_string_lossy().to_string();
    let top = match c.create_folder(parent_id, &root_name).await {
        Ok(f) => f,
        Err(DavError::AlreadyExists) => c.child(parent_id, &root_name).await.map_err(dav_err)?.ok_or("folder vanished")?,
        Err(e) => return Err(dav_err(e)),
    };
    let mut ids: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    ids.insert(String::new(), top.id);
    dirs.sort();
    for rel in dirs {
        let (parent_rel, name) = match rel.rfind('/') {
            Some(i) => (rel[..i].to_string(), rel[i + 1..].to_string()),
            None => (String::new(), rel.clone()),
        };
        let pid = ids.get(&parent_rel).cloned().ok_or("missing parent")?;
        let f = match c.create_folder(&pid, &name).await {
            Ok(f) => f,
            Err(DavError::AlreadyExists) => c.child(&pid, &name).await.map_err(dav_err)?.ok_or("folder vanished")?,
            Err(e) => return Err(dav_err(e)),
        };
        ids.insert(rel, f.id);
    }
    for (rel, abs) in files {
        let (parent_rel, name) = match rel.rfind('/') {
            Some(i) => (rel[..i].to_string(), rel[i + 1..].to_string()),
            None => (String::new(), rel.clone()),
        };
        if skyfolder_core::is_excluded_name(&name) {
            ev.done += 1;
            continue;
        }
        let pid = ids.get(&parent_rel).cloned().ok_or("missing parent")?;
        let target = c.available_name(&pid, &name).await.map_err(dav_err)?;
        c.upload(&abs, UploadTarget::New { parent_id: &pid, name: &target }, mtime(&abs), None).await.map_err(dav_err)?;
        ev.done += 1;
        emit(app, ev);
    }
    Ok(())
}

fn collect(base: &Path, dir: &Path, files: &mut Vec<(String, PathBuf)>, dirs: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let rel = p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/");
        if p.is_dir() {
            dirs.push(rel);
            collect(base, &p, files, dirs);
        } else if p.is_file() {
            files.push((rel, p));
        }
    }
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let mut p = dir.join(name);
    let (base, ext) = skyfolder_core::dav::split_ext(name);
    let mut i = 1;
    while p.exists() {
        p = dir.join(if ext.is_empty() { format!("{base} ({i})") } else { format!("{base} ({i}).{ext}") });
        i += 1;
    }
    p
}

#[tauri::command]
async fn download_items(app: AppHandle, state: State<'_, AppState>, items: Vec<RemoteItem>) -> CmdResult<()> {
    let c = client(&state).await?;
    let downloads = paths::downloads_dir();
    for it in items {
        let c = c.clone();
        let app = app.clone();
        let downloads = downloads.clone();
        tokio::spawn(async move {
            let name = skyfolder_core::safe_file_name(&if it.is_folder { format!("{}.zip", it.name) } else { it.name.clone() });
            let dest = unique_path(&downloads, &name);
            let mut ev = TransferEvent {
                id: NEXT_TRANSFER.fetch_add(1, Ordering::SeqCst),
                kind: "download",
                name: name.clone(),
                is_folder: it.is_folder,
                done: 0,
                total: it.size.max(1),
                state: "running",
                error: None,
                result_path: None,
            };
            emit(&app, &ev);
            let app2 = app.clone();
            let base = ev.clone();
            let progress = move |done: u64, total: u64| {
                let mut e = base.clone();
                e.done = done;
                if total > 0 {
                    e.total = total;
                }
                emit(&app2, &e);
            };
            let url = if it.is_folder { c.archive_url(&it.id) } else { c.id_url(&it.id) };
            match c.download_url(&url, &dest, Some(&progress), None).await {
                Ok(()) => {
                    ev.state = "done";
                    ev.done = ev.total;
                    ev.result_path = Some(dest.to_string_lossy().to_string());
                }
                Err(e) => {
                    ev.state = "failed";
                    ev.error = Some(dav_err(e));
                }
            }
            emit(&app, &ev);
        });
    }
    Ok(())
}

#[tauri::command]
async fn reveal_path(app: AppHandle, path: String) -> CmdResult<()> {
    app.opener().reveal_item_in_dir(path).map_err(err)
}

// ---------------- thumbnails ----------------

#[tauri::command]
async fn thumbnail(state: State<'_, AppState>, item: RemoteItem) -> CmdResult<Option<String>> {
    let c = client(&state).await?;
    let dir = paths::cache_dir().join("thumbs");
    let _ = std::fs::create_dir_all(&dir);
    let key = skyfolder_core::safe_file_name(&format!("{}-{}", item.opaque_id(), item.etag));
    let cached = dir.join(&key);
    let mime = |n: &str| match n.rsplit('.').next().map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("svg") => "image/svg+xml",
        Some("bmp") => "image/bmp",
        _ => "image/jpeg",
    };
    let data = if let Ok(d) = std::fs::read(&cached) {
        d
    } else if let Some(d) = if item.has_preview { c.thumbnail(&item.id, 512).await } else { None } {
        let _ = std::fs::write(&cached, &d);
        d
    } else {
        // Server previews off: fetch small images directly (the webview scales them).
        if item.size == 0 || item.size > 8_000_000 {
            return Ok(None);
        }
        let tmp = dir.join(format!("{key}.part"));
        if c.download(&item.id, &tmp, None).await.is_err() {
            return Ok(None);
        }
        let _ = std::fs::rename(&tmp, &cached);
        std::fs::read(&cached).map_err(err)?
    };
    Ok(Some(format!("data:{};base64,{}", if item.has_preview { "image/png" } else { mime(&item.name) }, base64::engine::general_purpose::STANDARD.encode(data))))
}

// ---------------- app ----------------

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

pub fn run() {
    tracing_subscriber::fmt().with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into())).init();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| show_main(app)))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--background"])))
        .manage(AppState::default())
        .setup(|app| {
            let open = MenuItem::with_id(app, "open", "Open Skyfolder", true, None::<&str>)?;
            let folder = MenuItem::with_id(app, "folder", "Open Skyfolder folder", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Skyfolder", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &folder, &PredefinedMenuItem::separator(app)?, &quit])?;
            TrayIconBuilder::with_id("tray")
                .icon(app.default_window_icon().cloned().expect("icon"))
                .tooltip("Skyfolder")
                .menu(&menu)
                .on_menu_event(|app, ev| match ev.id().as_ref() {
                    "open" => show_main(app),
                    "folder" => {
                        let _ = app.opener().open_path(paths::drive_root().to_string_lossy(), None::<&str>);
                    }
                    "quit" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Some(s) = app.state::<AppState>().session.write().await.take() {
                                if let Some(sync) = s.sync {
                                    sync.shutdown(false).await;
                                }
                            }
                            app.exit(0);
                        });
                    }
                    _ => {}
                })
                .build(app)?;
            if std::env::args().any(|a| a == "--background") {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Keep running in the tray when the window is closed, like other sync clients.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_session,
            sign_in,
            sign_out,
            list,
            recent,
            starred,
            search,
            trash,
            offline_state,
            offline_items,
            quota,
            create_folder,
            rename_item,
            move_items,
            copy_item,
            trash_items,
            restore_items,
            delete_forever,
            empty_trash,
            set_starred,
            set_offline,
            open_item,
            reveal_item,
            open_drive_folder,
            open_web,
            upload_paths,
            download_items,
            reveal_path,
            thumbnail,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Skyfolder");
}
