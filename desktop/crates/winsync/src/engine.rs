//! Windows sync engine: a Cloud Files (cfapi) sync root at %USERPROFILE%\Skyfolder.
//!
//! STATUS: compiles for Windows but has NOT been run on a real Windows machine yet.
//! The design follows the cloud-filter crate's SFTP example, adapted to OpenCloud:
//!
//! - Every placeholder carries a blob `{id, etag}`; remote operations go by file id, so
//!   local renames/moves/deletes map directly to MOVE/DELETE on that id.
//! - Directories are populated on demand (`fetch_placeholders`); file contents are
//!   hydrated on demand (`fetch_data`) with a ranged GET whose ETag must match the blob.
//! - Local edits (file closed / directory watcher) go through one worker thread that
//!   uploads with If-Match. A 412 keeps both versions (conflicted copy), like Linux/macOS.
//! - Remote changes are found by walking folder etags of the directories that exist
//!   locally (every 30 s), the same approach as the macOS app.
//! - Deletes go to the OpenCloud trash, so they can be undone from the app.
//! - Office-style "safe saves" (rename original to a temp name, write a new file, delete
//!   the temp) keep the original file id instead of replacing the file.

use anyhow::{anyhow, bail, Context, Result};
use cloud_filter::{
    error::{CResult, CloudErrorKind},
    ext::FileExt,
    filter::{info, ticket, Request, StateWatchEvent, SyncFilter},
    metadata::Metadata,
    placeholder::{ConvertOptions, PinOptions, PinState, Placeholder, PlaceholderInfo, UpdateOptions},
    placeholder_create_info::PlaceholderCreateInfo,
    root::{
        active_roots, HydrationPolicy, HydrationType, PopulationType, ProtectionMode, SecurityId, Session, SyncRootId,
        SyncRootIdBuilder, SyncRootInfo,
    },
    utility::{FileTime, WriteAt},
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use skyfolder_core::{is_excluded_name, paths, DavClient, DavError, RemoteItem, UploadTarget};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf, Prefix};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::runtime::Handle;

const PROVIDER: &str = "Skyfolder";
const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Transfer unit for hydration; CF requires 4 KiB-aligned writes except at EOF.
const CHUNK: usize = 1 << 20;
const POLL_EVERY: Duration = Duration::from_secs(30);
/// How long our own local changes are ignored by the callbacks they trigger.
const SUPPRESS_FOR: Duration = Duration::from_secs(15);
/// Office safe-save window: a file renamed to a temp name and replaced within this time keeps its id.
const SAFE_SAVE_WINDOW: Duration = Duration::from_secs(60);
const HYDRATED_FILE: &str = "winsync-hydrated.json";

const FILE_SHARE_READ: u32 = 0x1;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
const ERROR_SHARING_VIOLATION: i32 = 32;

// ---------------------------------------------------------------------------
// Public API (used by src-tauri/src/sync.rs)
// ---------------------------------------------------------------------------

pub struct SyncRoot {
    shared: Arc<Shared>,
    account_key: String,
    conn: Option<(mpsc::Sender<()>, JoinHandle<()>)>,
    worker: Option<JoinHandle<()>>,
}

impl SyncRoot {
    pub async fn start(client: Arc<DavClient>, dir: &Path) -> Result<SyncRoot> {
        let rt = Handle::current();
        let dir = dir.to_path_buf();
        tokio::task::spawn_blocking(move || SyncRoot::start_blocking(client, rt, dir)).await?
    }

    fn start_blocking(client: Arc<DavClient>, rt: Handle, dir: PathBuf) -> Result<SyncRoot> {
        if !cloud_filter::root::is_supported().unwrap_or(false) {
            bail!("this version of Windows doesn't support cloud files");
        }
        let account_key = account_key(&client);
        fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
        let root = canonical_path(&dir)?;
        register(&root, &account_key)?;

        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            root_id: client.account.root_id.clone(),
            client,
            rt,
            root: root.clone(),
            suppress: Mutex::default(),
            hydrated: Mutex::new(paths::read_json(HYDRATED_FILE).unwrap_or_default()),
            hydrated_dirty: Mutex::new(false),
            dir_etags: Mutex::default(),
            safe_saves: Mutex::default(),
            reattached: Mutex::default(),
            tx: Mutex::new(Some(tx)),
        });

        // Connect on a dedicated thread that owns the Connection until shutdown.
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<std::result::Result<(), String>>();
        let filter = Filter { s: shared.clone(), deleting_dirs: Mutex::default() };
        let conn_root = root.clone();
        let conn_thread = thread::Builder::new().name("skyfolder-cf".into()).spawn(move || {
            match Session::new().connect(&conn_root, filter) {
                Ok(conn) => {
                    let _ = ready_tx.send(Ok(()));
                    let _ = stop_rx.recv();
                    drop(conn);
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e.to_string()));
                }
            }
        })?;
        match ready_rx.recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                let _ = conn_thread.join();
                bail!("couldn't connect the sync root: {e}");
            }
            Err(_) => bail!("sync root connection thread exited"),
        }

        let ws = shared.clone();
        let worker = thread::Builder::new().name("skyfolder-sync".into()).spawn(move || ws.run(rx))?;
        tracing::info!("Windows sync root connected at {}", root.display());
        Ok(SyncRoot { shared, account_key, conn: Some((stop_tx, conn_thread)), worker: Some(worker) })
    }

    /// Remote ids of files whose contents are on this computer.
    pub fn cached_ids(&self) -> Vec<String> {
        self.shared.hydrated.lock().keys().cloned().collect()
    }

    /// Pins (keeps downloaded) or unpins (frees up space) items by their drive path.
    pub async fn set_offline(&self, items: &[RemoteItem], on: bool) {
        let s = self.shared.clone();
        let items = items.to_vec();
        let _ = tokio::task::spawn_blocking(move || {
            for it in items {
                let Some(rel) = it.path.as_deref() else { continue };
                let local = s.local_path(rel);
                if let Err(e) = s.set_pin(&local, on, it.is_folder) {
                    tracing::warn!("couldn't change offline state of {}: {e:#}", local.display());
                }
            }
        })
        .await;
    }

    /// Disconnects. `forget` (sign-out) also unregisters the sync root and removes the
    /// local folder, unless it holds changes that never reached the server; then the
    /// folder is kept, renamed, so nothing is lost.
    pub async fn shutdown(mut self, forget: bool) {
        let worker = self.worker.take();
        let conn = self.conn.take();
        let shared = self.shared.clone();
        let key = self.account_key.clone();
        let _ = tokio::task::spawn_blocking(move || {
            if let Some(tx) = shared.tx.lock().take() {
                let _ = tx.send(Work::Stop);
            }
            if let Some(w) = worker {
                let _ = w.join();
            }
            shared.save_hydrated();
            if let Some((stop, th)) = conn {
                let _ = stop.send(());
                let _ = th.join();
            }
            if forget {
                let root = shared.root.clone();
                let unsynced = has_unsynced(&root);
                if let Ok(id) = sync_root_id(&key) {
                    if let Err(e) = id.unregister() {
                        tracing::warn!("unregister sync root: {e}");
                    }
                }
                paths::remove(HYDRATED_FILE);
                if unsynced {
                    let aside = unique_sibling(&root, "Skyfolder (unsynced files)");
                    tracing::warn!("local changes never reached the server; keeping them in {}", aside.display());
                    let _ = fs::rename(&root, &aside);
                } else if let Err(e) = fs::remove_dir_all(&root) {
                    tracing::warn!("remove {}: {e}", root.display());
                }
            }
        })
        .await;
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Stable per-account key (FNV-1a of server + user id); part of the sync root id.
fn account_key(client: &DavClient) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in format!("{}\n{}", client.account.server_url, client.account.user_id).bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

fn sync_root_id(key: &str) -> Result<SyncRootId> {
    Ok(SyncRootIdBuilder::new(PROVIDER).user_security_id(SecurityId::current_user()?).account_name(key).build())
}

fn register(root: &Path, key: &str) -> Result<()> {
    let id = sync_root_id(key)?;
    // Another Skyfolder registration (e.g. a different account) at the same folder must go first.
    if let Ok(roots) = active_roots() {
        for info in roots {
            let other = info.id();
            if other.to_os_string() == id.to_os_string() {
                continue;
            }
            let ours = other.to_components().0.to_string_lossy() == PROVIDER;
            if ours && canonical_path(&info.path()).map(|p| same_path(&p, root)).unwrap_or(false) {
                tracing::info!("removing stale Skyfolder registration at {}", root.display());
                let _ = other.unregister();
            }
        }
    }
    if id.is_registered()? {
        let info = id.info()?;
        if canonical_path(&info.path()).map(|p| same_path(&p, root)).unwrap_or(false) {
            return Ok(()); // resume the existing registration; placeholders stay as they are
        }
        id.unregister()?;
    }
    // A new registration starts from an empty folder; keep anything already there.
    if fs::read_dir(root)?.next().is_some() {
        let aside = unique_sibling(root, "Skyfolder (old)");
        tracing::warn!("{} isn't empty; moving its contents to {}", root.display(), aside.display());
        fs::rename(root, &aside)?;
        fs::create_dir_all(root)?;
    }
    let icon = std::env::current_exe().map(|p| format!("{},0", p.display())).unwrap_or_else(|_| "%SystemRoot%\\system32\\imageres.dll,-1043".into());
    let info = SyncRootInfo::default()
        .with_display_name("Skyfolder")
        .with_hydration_type(HydrationType::Full)
        .with_hydration_policy(HydrationPolicy::AutoDehydrationAllowed)
        .with_population_type(PopulationType::Full)
        .with_protection_mode(ProtectionMode::Personal)
        .with_allow_pinning(true)
        .with_icon(icon)
        .with_version(VERSION)
        .with_blob(key.as_bytes())
        .with_path(root)?;
    id.register(info)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Shared state + worker
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Blob {
    id: String,
    etag: String,
}

fn blob_of(it: &RemoteItem) -> Vec<u8> {
    serde_json::to_vec(&Blob { id: it.id.clone(), etag: it.etag.clone() }).unwrap_or_default()
}

fn parse_blob(b: &[u8]) -> Option<Blob> {
    serde_json::from_slice(b).ok()
}

#[derive(Debug)]
enum Work {
    /// Upload/create whatever is at this path, if it differs from the server.
    Sync(PathBuf),
    DeleteFile { id: String, path: PathBuf },
    DeleteDir { id: String, path: PathBuf, since: Instant },
    Rename { id: String, target: PathBuf },
    Poll,
    Stop,
}

impl Work {
    fn touches(&self, p: &Path) -> bool {
        match self {
            Work::DeleteFile { path, .. } | Work::DeleteDir { path, .. } => p.starts_with(path),
            Work::Rename { target, .. } => p.starts_with(target),
            _ => false,
        }
    }
}

struct Shared {
    client: Arc<DavClient>,
    rt: Handle,
    root: PathBuf,
    root_id: String,
    /// Paths we are changing ourselves; callbacks for them (and descendants) are ignored.
    suppress: Mutex<HashMap<PathBuf, Instant>>,
    /// remote id -> local path of fully downloaded files.
    hydrated: Mutex<HashMap<String, PathBuf>>,
    hydrated_dirty: Mutex<bool>,
    /// Last seen etag of each remote folder we reconciled.
    dir_etags: Mutex<HashMap<String, String>>,
    /// original path -> (id, temp path, when): files renamed to a temp name (safe-save).
    safe_saves: Mutex<HashMap<PathBuf, (String, PathBuf, Instant)>>,
    /// ids moved onto a replacement file by a safe-save; their temp file's delete is not remote.
    reattached: Mutex<HashSet<String>>,
    tx: Mutex<Option<mpsc::Sender<Work>>>,
}

impl Shared {
    fn block<F: std::future::Future>(&self, f: F) -> F::Output {
        self.rt.block_on(f)
    }

    fn send(&self, w: Work) {
        if let Some(tx) = self.tx.lock().as_ref() {
            let _ = tx.send(w);
        }
    }

    fn local_path(&self, rel: &str) -> PathBuf {
        let mut p = self.root.clone();
        for part in rel.split('/').filter(|s| !s.is_empty()) {
            p.push(part);
        }
        p
    }

    fn suppress(&self, p: &Path) {
        self.suppress.lock().insert(p.to_path_buf(), Instant::now());
    }

    fn suppressed(&self, p: &Path) -> bool {
        let mut s = self.suppress.lock();
        s.retain(|_, t| t.elapsed() < SUPPRESS_FOR);
        s.keys().any(|k| p.starts_with(k))
    }

    fn in_root(&self, p: &Path) -> bool {
        p != self.root && p.strip_prefix(&self.root).is_ok_and(|r| r.components().all(|c| matches!(c, Component::Normal(_))))
    }

    fn set_hydrated(&self, id: &str, path: Option<&Path>) {
        let mut h = self.hydrated.lock();
        let changed = match path {
            Some(p) => h.insert(id.to_string(), p.to_path_buf()).as_deref() != Some(p),
            None => h.remove(id).is_some(),
        };
        if changed {
            *self.hydrated_dirty.lock() = true;
        }
    }

    fn save_hydrated(&self) {
        let mut dirty = self.hydrated_dirty.lock();
        if *dirty {
            let _ = paths::write_json(HYDRATED_FILE, &*self.hydrated.lock());
            *dirty = false;
        }
    }

    // ----- worker loop -----

    fn run(self: Arc<Self>, rx: mpsc::Receiver<Work>) {
        self.validate_hydrated();
        self.startup_scan();
        let mut changes: VecDeque<(Work, u32)> = VecDeque::new();
        let mut pending: HashMap<PathBuf, (Instant, u32)> = HashMap::new(); // path -> (not before, failures)
        let mut next_poll = Instant::now();
        let mut change_retry_at = Instant::now();
        loop {
            let wait = Duration::from_millis(300);
            let mut batch = Vec::new();
            match rx.recv_timeout(wait) {
                Ok(w) => batch.push(w),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
            batch.extend(rx.try_iter().take(4096));
            for w in batch {
                match w {
                    Work::Stop => return,
                    Work::Poll => next_poll = Instant::now(),
                    Work::Sync(p) => {
                        pending.entry(p).or_insert((Instant::now(), 0));
                    }
                    other => changes.push_back((other, 0)),
                }
            }

            // Name changes first, in order; a failing one is retried later and blocks the rest.
            if Instant::now() >= change_retry_at {
                while let Some((w, tries)) = changes.front_mut() {
                    match self.apply_change(w) {
                        Ok(true) => {
                            changes.pop_front();
                        }
                        Ok(false) => {
                            change_retry_at = Instant::now() + Duration::from_secs(1);
                            break;
                        }
                        Err(e) => {
                            *tries += 1;
                            tracing::warn!("{w:?} failed ({tries}x): {e:#}");
                            if *tries >= 8 || !retryable(&e) {
                                changes.pop_front();
                            } else {
                                change_retry_at = Instant::now() + backoff(*tries);
                                break;
                            }
                        }
                    }
                }
            }

            // Uploads, after any rename/delete that touches the path.
            let now = Instant::now();
            let due: Vec<PathBuf> = pending.iter().filter(|(_, (t, _))| *t <= now).map(|(p, _)| p.clone()).collect();
            for p in due {
                if changes.iter().any(|(w, _)| w.touches(&p)) {
                    continue;
                }
                let tries = pending.get(&p).map(|x| x.1).unwrap_or(0);
                match self.sync_path(&p) {
                    Ok(true) => {
                        pending.remove(&p);
                    }
                    Ok(false) => {
                        pending.insert(p, (Instant::now() + Duration::from_secs(2), tries));
                    }
                    Err(e) => {
                        let tries = tries + 1;
                        tracing::warn!("sync {} failed ({tries}x): {e:#}", p.display());
                        if tries >= 8 || !retryable(&e) {
                            pending.remove(&p);
                        } else {
                            pending.insert(p, (Instant::now() + backoff(tries), tries));
                        }
                    }
                }
            }

            self.expire_safe_saves();

            if Instant::now() >= next_poll {
                if let Err(e) = self.poll() {
                    tracing::warn!("remote change check failed: {e:#}");
                }
                next_poll = Instant::now() + POLL_EVERY;
                self.save_hydrated();
            }
        }
    }

    /// Drops hydrated-file records that no longer match the disk.
    fn validate_hydrated(&self) {
        let entries: Vec<(String, PathBuf)> = self.hydrated.lock().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for (id, path) in entries {
            let ok = open_placeholder(&path)
                .ok()
                .and_then(|ph| ph.info().ok().flatten())
                .is_some_and(|i| i.on_disk_data_size() > 0 && parse_blob(i.blob()).is_some_and(|b| b.id == id));
            if !ok {
                self.set_hydrated(&id, None);
            }
        }
    }

    /// Finds edits made while Skyfolder wasn't running. Only walks into directories that
    /// are already populated, so it never lists the server.
    fn startup_scan(&self) {
        let mut stack = vec![self.root.clone()];
        while let Some(dir) = stack.pop() {
            let Ok(rd) = fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                let Ok(md) = fs::symlink_metadata(&p) else { continue };
                if md.file_type().is_symlink() {
                    continue;
                }
                let info = open_placeholder(&p).ok().and_then(|ph| ph.info().ok().flatten());
                if md.is_dir() {
                    match &info {
                        None => self.send(Work::Sync(p.clone())), // new local folder (children follow)
                        Some(i) if !i.is_in_sync() => self.send(Work::Sync(p.clone())),
                        _ => {}
                    }
                    if !is_partial(&p) {
                        stack.push(p);
                    }
                } else if info.as_ref().is_none_or(|i| !i.is_in_sync() || i.modified_data_size() > 0) {
                    self.send(Work::Sync(p));
                }
            }
        }
    }

    // ----- uploads -----

    /// Returns Ok(false) to retry later without counting a failure (e.g. file still open).
    fn sync_path(&self, path: &Path) -> Result<bool> {
        if !self.in_root(path) || self.suppressed(path) {
            return Ok(true);
        }
        let name = file_name(path)?;
        if is_temp_name(&name) {
            return Ok(true);
        }
        let md = match fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(e) => return Err(e.into()),
        };
        if md.file_type().is_symlink() {
            return Ok(true);
        }
        if md.is_dir() {
            let fresh = open_placeholder(path)?.info()?.is_none();
            self.ensure_remote_dir(path)?;
            if fresh {
                // A folder created (or moved in) locally: its children are local too.
                for e in fs::read_dir(path)?.flatten() {
                    self.send(Work::Sync(e.path()));
                }
            }
            return Ok(true);
        }
        if !md.is_file() {
            return Ok(true);
        }
        let done = self.upload(path, &name)?;
        if done {
            self.apply_pin_state(path)?;
        }
        Ok(done)
    }

    /// The remote id of a local directory, creating it on the server if it's new.
    fn ensure_remote_dir(&self, dir: &Path) -> Result<String> {
        if same_path(dir, &self.root) {
            return Ok(self.root_id.clone());
        }
        if !self.in_root(dir) {
            bail!("{} is outside the Skyfolder folder", dir.display());
        }
        let mut ph = open_placeholder(dir)?;
        if let Some(info) = ph.info()? {
            if let Some(b) = parse_blob(info.blob()) {
                if !info.is_in_sync() {
                    ph.mark_in_sync(true, None)?;
                }
                return Ok(b.id);
            }
        }
        drop(ph);
        let parent_id = self.ensure_remote_dir(dir.parent().context("no parent")?)?;
        let name = file_name(dir)?;
        let (item, existed) = match self.block(self.client.create_folder(&parent_id, &name)) {
            Ok(it) => (it, false),
            Err(DavError::AlreadyExists) => {
                // Same-named folder appeared on the server: merge into it.
                let it = self.block(self.client.child(&parent_id, &name))?.ok_or_else(|| anyhow!("folder {name} vanished"))?;
                (it, true)
            }
            Err(e) => return Err(e.into()),
        };
        let mut opts = ConvertOptions::default().blob(blob_of(&item)).mark_in_sync();
        if existed {
            opts = opts.has_children(); // fetch the server's children on next access
        }
        open_placeholder(dir)?.convert_to_placeholder(opts, None)?;
        tracing::info!("created folder {}", item.path.as_deref().unwrap_or(&name));
        Ok(item.id)
    }

    fn upload(&self, path: &Path, name: &str) -> Result<bool> {
        let clean = |i: &PlaceholderInfo| i.is_in_sync() && i.modified_data_size() == 0;
        if open_placeholder(path)?.info()?.as_ref().is_some_and(clean) {
            return Ok(true);
        }
        // Deny other writers while we read and publish; an active writer means "later".
        let source = match fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ).open(path) {
            Ok(f) => f,
            Err(e) if e.raw_os_error() == Some(ERROR_SHARING_VIOLATION) => return Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(e) => return Err(e.into()),
        };
        let mut ph = open_placeholder(path)?;
        let info = ph.info()?;
        if info.as_ref().is_some_and(clean) {
            return Ok(true);
        }
        let usn = source.usn()?;
        let parent_id = self.ensure_remote_dir(path.parent().context("no parent")?)?;
        let mtime = source.metadata()?.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64);
        let blob = info.as_ref().and_then(|i| parse_blob(i.blob()));
        let safe_save = if blob.is_none() { self.safe_saves.lock().remove(path).map(|(id, _, _)| id) } else { None };

        // Pick the target, then upload.
        let mut final_name = name.to_string();
        let result = if let Some(b) = &blob {
            match self.block(self.client.upload(path, UploadTarget::Existing { id: &b.id, if_match: Some(&b.etag) }, mtime, None)) {
                Err(DavError::PreconditionFailed) => {
                    // Changed here and on the server: keep both.
                    final_name = skyfolder_core::conflict_name(name);
                    tracing::warn!("conflict on {name}: saving local changes as {final_name}");
                    self.send(Work::Poll); // bring the server's version back next to it
                    self.block(self.client.upload(path, UploadTarget::New { parent_id: &parent_id, name: &final_name }, mtime, None))
                }
                Err(DavError::NotFound) => {
                    // Deleted on the server meanwhile: upload as a new file.
                    final_name = self.block(self.client.available_name(&parent_id, name))?;
                    self.block(self.client.upload(path, UploadTarget::New { parent_id: &parent_id, name: &final_name }, mtime, None))
                }
                r => r,
            }
        } else if let Some(id) = &safe_save {
            // Replacement after a safe-save: new contents for the original file id.
            let r = self.block(self.client.upload(path, UploadTarget::Existing { id, if_match: None }, mtime, None));
            if r.is_ok() {
                self.reattached.lock().insert(id.clone());
                if let Ok(it) = &r {
                    if it.name != name || it.parent_id.as_deref() != Some(parent_id.as_str()) {
                        let _ = self.block(self.client.move_item(id, &parent_id, name, false));
                    }
                }
            }
            r
        } else {
            final_name = self.block(self.client.available_name(&parent_id, name))?;
            self.block(self.client.upload(path, UploadTarget::New { parent_id: &parent_id, name: &final_name }, mtime, None))
        };
        let item = result?;

        if source.usn()? != usn {
            return Ok(false); // changed while uploading: upload again
        }
        let bytes = blob_of(&item);
        if info.is_some() {
            ph.update(UpdateOptions::default().blob(&bytes).mark_in_sync(), None)?;
        } else {
            ph.convert_to_placeholder(ConvertOptions::default().blob(bytes).mark_in_sync(), None)?;
        }
        drop(ph);
        drop(source);
        let mut local = path.to_path_buf();
        if final_name != name {
            let target = path.with_file_name(&final_name);
            self.suppress(path);
            self.suppress(&target);
            match fs::rename(path, &target) {
                Ok(()) => local = target,
                Err(e) => tracing::warn!("couldn't rename {} to {final_name}: {e}", path.display()),
            }
        }
        self.set_hydrated(&item.id, Some(&local));
        tracing::info!("uploaded {}", item.path.as_deref().unwrap_or(&final_name));
        Ok(true)
    }

    // ----- deletes / renames -----

    fn apply_change(&self, w: &Work) -> Result<bool> {
        match w {
            Work::DeleteFile { id, path } => {
                if self.reattached.lock().remove(id) {
                    return Ok(true); // a safe-save moved this id onto the replacement file
                }
                if path.exists() {
                    return Ok(true); // undeleted / replaced
                }
                self.trash(id)?;
                self.set_hydrated(id, None);
                tracing::info!("moved {} to trash", path.display());
            }
            Work::DeleteDir { id, path, since } => {
                // Directories have no close callback and a delete can be undone while a
                // handle is open: wait until the folder is really gone.
                if path.exists() {
                    return Ok(since.elapsed() > Duration::from_secs(30));
                }
                self.trash(id)?;
                tracing::info!("moved folder {} to trash", path.display());
            }
            Work::Rename { id, target } => {
                if !target.exists() {
                    return Ok(true); // moved again or deleted; later events cover it
                }
                let parent_id = self.ensure_remote_dir(target.parent().context("no parent")?)?;
                let name = file_name(target)?;
                let current = match self.block(self.client.item_by_id(id)) {
                    Ok(it) => it,
                    Err(DavError::NotFound) => {
                        self.send(Work::Sync(target.clone()));
                        return Ok(true);
                    }
                    Err(e) => return Err(e.into()),
                };
                if current.name == name && current.parent_id.as_deref() == Some(parent_id.as_str()) {
                    return Ok(true);
                }
                match self.block(self.client.move_item(id, &parent_id, &name, false)) {
                    Ok(_) => {}
                    Err(DavError::AlreadyExists) => {
                        // Name taken on the server: keep both, renaming ours locally to match.
                        let alt = self.block(self.client.available_name(&parent_id, &name))?;
                        self.block(self.client.move_item(id, &parent_id, &alt, false))?;
                        let alt_path = target.with_file_name(&alt);
                        self.suppress(target);
                        self.suppress(&alt_path);
                        let _ = fs::rename(target, &alt_path);
                    }
                    Err(e) => return Err(e.into()),
                }
                tracing::info!("renamed/moved {} on the server", target.display());
            }
            Work::Sync(_) | Work::Poll | Work::Stop => {}
        }
        Ok(true)
    }

    fn trash(&self, id: &str) -> Result<()> {
        match self.block(self.client.delete(id)) {
            Ok(()) | Err(DavError::NotFound) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Safe-save entries that were never replaced become ordinary renames.
    fn expire_safe_saves(&self) {
        let expired: Vec<(PathBuf, String, PathBuf)> = {
            let mut s = self.safe_saves.lock();
            let old: Vec<PathBuf> = s.iter().filter(|(_, (_, _, t))| t.elapsed() > SAFE_SAVE_WINDOW).map(|(k, _)| k.clone()).collect();
            old.into_iter().filter_map(|k| s.remove(&k).map(|(id, tmp, _)| (k, id, tmp))).collect()
        };
        for (_orig, id, tmp) in expired {
            if tmp.exists() {
                self.send(Work::Rename { id, target: tmp });
            }
        }
    }

    // ----- offline (pinning) -----

    fn set_pin(self: &Arc<Self>, local: &Path, on: bool, is_dir: bool) -> Result<()> {
        fs::metadata(local).with_context(|| format!("{} isn't available", local.display()))?; // populates parents
        let mut opts = PinOptions::default();
        if is_dir {
            opts.recurse();
        }
        open_placeholder(local)?.mark_pin(if on { PinState::Pinned } else { PinState::Unpinned }, opts)?;
        let s = self.clone();
        let local = local.to_path_buf();
        // Hydration can take a while; keep the worker free.
        thread::spawn(move || {
            let r = if on { s.hydrate_tree(&local) } else { s.dehydrate_tree(&local) };
            if let Err(e) = r {
                tracing::warn!("offline {}: {e:#}", local.display());
            }
            if !on {
                // Back to normal: opening it later downloads it again without re-freeing it.
                let mut opts = PinOptions::default();
                opts.recurse();
                if let Ok(mut ph) = open_placeholder(&local) {
                    let _ = ph.mark_pin(PinState::Unspecified, opts);
                }
            }
        });
        Ok(())
    }

    fn hydrate_tree(&self, p: &Path) -> Result<()> {
        if fs::metadata(p)?.is_dir() {
            for e in fs::read_dir(p)?.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if !is_temp_name(&name) {
                    self.hydrate_tree(&e.path())?;
                }
            }
            return Ok(());
        }
        let mut ph = open_placeholder(p)?;
        if let Some(info) = ph.info()? {
            if (info.on_disk_data_size() as u64) < fs::metadata(p)?.len() {
                ph.hydrate(..)?;
            }
            if let Some(b) = parse_blob(info.blob()) {
                self.set_hydrated(&b.id, Some(p));
            }
        }
        Ok(())
    }

    fn dehydrate_tree(&self, p: &Path) -> Result<()> {
        if fs::metadata(p)?.is_dir() {
            if is_partial(p) {
                return Ok(()); // never listed, so nothing below it is downloaded
            }
            for e in fs::read_dir(p)?.flatten() {
                self.dehydrate_tree(&e.path())?;
            }
            return Ok(());
        }
        self.dehydrate_file(p)
    }

    /// Frees a file's local contents if it matches the server.
    fn dehydrate_file(&self, p: &Path) -> Result<()> {
        let Some(info) = open_placeholder(p)?.info()? else { return Ok(()) };
        if !info.is_in_sync() || info.modified_data_size() != 0 || info.on_disk_data_size() == 0 {
            return Ok(());
        }
        let f = match fs::OpenOptions::new().access_mode(0).share_mode(0).open(p) {
            Ok(f) => f,
            Err(e) if e.raw_os_error() == Some(ERROR_SHARING_VIOLATION) => return Ok(()), // in use
            Err(e) => return Err(e.into()),
        };
        f.dehydrate(..)?;
        if let Some(b) = parse_blob(info.blob()) {
            self.set_hydrated(&b.id, None);
        }
        Ok(())
    }

    /// Explorer's "Always keep on this device" / "Free up space".
    fn apply_pin_state(&self, p: &Path) -> Result<()> {
        let Some(info) = open_placeholder(p)?.info()? else { return Ok(()) };
        match info.pin_state() {
            PinState::Pinned if (info.on_disk_data_size() as u64) < fs::metadata(p)?.len() => self.hydrate_tree(p),
            PinState::Unpinned => self.dehydrate_file(p),
            _ => Ok(()),
        }
    }

    // ----- remote changes -----

    fn poll(&self) -> Result<()> {
        let root = self.block(self.client.item_by_id(&self.root_id))?;
        if self.dir_etags.lock().get(&self.root_id) == Some(&root.etag) {
            return Ok(());
        }
        if self.reconcile_dir(&self.root, &self.root_id)? {
            self.dir_etags.lock().insert(self.root_id.clone(), root.etag);
        }
        Ok(())
    }

    /// Brings one populated local directory in line with the server. Returns false if
    /// something couldn't be applied yet (the folder is checked again next time).
    fn reconcile_dir(&self, dir: &Path, id: &str) -> Result<bool> {
        let (_, remote) = self.block(self.client.list_id(id))?;
        let mut complete = true;

        struct Local {
            path: PathBuf,
            info: PlaceholderInfo,
            blob: Blob,
            is_dir: bool,
        }
        let mut local: HashMap<String, Local> = HashMap::new();
        let mut names: HashSet<String> = HashSet::new();
        for e in fs::read_dir(dir)?.flatten() {
            let p = e.path();
            names.insert(e.file_name().to_string_lossy().to_lowercase());
            let Some(info) = open_placeholder(&p).ok().and_then(|ph| ph.info().ok().flatten()) else { continue };
            let Some(blob) = parse_blob(info.blob()) else { continue };
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            local.insert(blob.id.clone(), Local { path: p, info, blob, is_dir });
        }

        let mut seen = HashSet::new();
        for it in &remote {
            if !windows_name_ok(&it.name) || is_excluded_name(&it.name) {
                continue;
            }
            seen.insert(it.id.clone());
            match local.get(&it.id) {
                Some(l) => {
                    let mut path = l.path.clone();
                    // Renamed on the server.
                    if file_name(&path).ok().as_deref() != Some(it.name.as_str()) {
                        let target = dir.join(&it.name);
                        let case_only = path.file_name().map(|n| n.to_string_lossy().to_lowercase()) == Some(it.name.to_lowercase());
                        if case_only || !names.contains(&it.name.to_lowercase()) {
                            self.suppress(&path);
                            self.suppress(&target);
                            match fs::rename(&path, &target) {
                                Ok(()) => path = target,
                                Err(e) => {
                                    tracing::warn!("rename {} -> {}: {e}", path.display(), it.name);
                                    complete = false;
                                }
                            }
                        }
                    }
                    if it.is_folder {
                        let known = self.dir_etags.lock().get(&it.id).cloned();
                        if known.as_deref() != Some(it.etag.as_str()) && l.is_dir && !is_partial(&path) {
                            match self.reconcile_dir(&path, &it.id) {
                                Ok(true) => {
                                    self.dir_etags.lock().insert(it.id.clone(), it.etag.clone());
                                }
                                Ok(false) => complete = false,
                                Err(e) => {
                                    tracing::warn!("check {}: {e:#}", path.display());
                                    complete = false;
                                }
                            }
                        }
                    } else if l.blob.etag != it.etag {
                        if l.info.is_in_sync() && l.info.modified_data_size() == 0 {
                            if let Err(e) = self.refresh_file(&path, it, l.info.pin_state()) {
                                tracing::debug!("refresh {}: {e:#}", path.display());
                                complete = false;
                            }
                        }
                        // Otherwise local edits are pending; their upload resolves the conflict.
                    }
                }
                None => {
                    if names.contains(&it.name.to_lowercase()) {
                        continue; // something local already has this name; leave it alone
                    }
                    match placeholder_for(it).create(dir) {
                        Ok(_) => tracing::debug!("added {}", it.name),
                        Err(e) => {
                            tracing::warn!("add {}: {e}", it.name);
                            complete = false;
                        }
                    }
                }
            }
        }

        // Gone from this folder on the server (deleted or moved elsewhere).
        for (rid, l) in &local {
            if seen.contains(rid) {
                continue;
            }
            let clean = if l.is_dir { tree_in_sync(&l.path) } else { l.info.is_in_sync() && l.info.modified_data_size() == 0 };
            if !clean {
                continue; // local changes: keep them; uploading re-creates the item
            }
            self.suppress(&l.path);
            let r = if l.is_dir { fs::remove_dir_all(&l.path) } else { fs::remove_file(&l.path) };
            match r {
                Ok(()) => self.set_hydrated(rid, None),
                Err(e) => {
                    tracing::debug!("remove {}: {e}", l.path.display());
                    complete = false;
                }
            }
        }
        Ok(complete)
    }

    /// Server has a newer version of an unmodified local file: update its metadata and drop
    /// the old contents (downloaded again on next open, or right away if pinned).
    fn refresh_file(&self, path: &Path, it: &RemoteItem, pin: PinState) -> Result<()> {
        let f = fs::OpenOptions::new().access_mode(0).share_mode(0).custom_flags(FILE_FLAG_BACKUP_SEMANTICS).open(path)?;
        let mut ph = Placeholder::from(f);
        let bytes = blob_of(it);
        ph.update(UpdateOptions::default().metadata(metadata_for(it)).blob(&bytes).dehydrate().mark_in_sync(), None)?;
        drop(ph);
        self.set_hydrated(&it.id, None);
        if pin == PinState::Pinned {
            let mut ph = open_placeholder(path)?;
            ph.hydrate(..)?;
            self.set_hydrated(&it.id, Some(path));
        }
        tracing::info!("updated {} from the server", path.display());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Cloud Filter callbacks
// ---------------------------------------------------------------------------

struct Filter {
    s: Arc<Shared>,
    deleting_dirs: Mutex<HashSet<i64>>,
}

fn dav_cloud(e: DavError) -> CloudErrorKind {
    tracing::warn!("server: {e}");
    if e.is_auth() {
        CloudErrorKind::AuthenticationFailed
    } else if matches!(e, DavError::Network(_)) {
        CloudErrorKind::NetworkUnavailable
    } else {
        CloudErrorKind::Unsuccessful
    }
}

fn cf_err(e: impl std::fmt::Display) -> CloudErrorKind {
    tracing::warn!("cloud files: {e}");
    CloudErrorKind::Unsuccessful
}

fn unquote(s: &str) -> &str {
    s.trim().trim_start_matches("W/").trim_matches('"')
}

impl SyncFilter for Filter {
    fn fetch_data(&self, request: Request, ticket: ticket::FetchData, info: info::FetchData) -> CResult<()> {
        let s = &self.s;
        let b = parse_blob(request.file_blob()).ok_or(CloudErrorKind::InvalidRequest)?;
        let size = request.file_size();
        let range = info.required_file_range();
        let end = range.end.min(size);
        if range.start >= end {
            return Ok(());
        }
        let (mut resp, partial) = s.block(s.client.range_response(&b.id, range.start, end - range.start)).map_err(dav_cloud)?;
        // The server ignores If-Match on GET; compare the version instead.
        let tag = resp.headers().get("etag").and_then(|v| v.to_str().ok()).map(|t| unquote(t).to_string());
        let total = resp
            .headers()
            .get("content-range")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit('/').next())
            .and_then(|t| t.parse::<u64>().ok());
        if tag.as_deref().is_some_and(|t| t != unquote(&b.etag)) || total.is_some_and(|t| t != size) {
            tracing::info!("{} changed on the server; refreshing", request.path().display());
            s.send(Work::Poll);
            return Err(CloudErrorKind::NotInSync);
        }
        let mut skip = if partial { 0 } else { range.start };
        let mut pos = range.start;
        let mut buf: Vec<u8> = Vec::with_capacity(CHUNK);
        loop {
            let chunk = s.block(resp.chunk()).map_err(cf_err)?;
            let Some(chunk) = chunk else { break };
            let mut data: &[u8] = &chunk;
            if skip > 0 {
                let n = (skip as usize).min(data.len());
                data = &data[n..];
                skip -= n as u64;
            }
            buf.extend_from_slice(data);
            while buf.len() >= CHUNK && pos + (CHUNK as u64) <= end {
                ticket.write_at(&buf[..CHUNK], pos).map_err(cf_err)?;
                pos += CHUNK as u64;
                buf.drain(..CHUNK);
                let _ = ticket.report_progress(end - range.start, pos - range.start);
            }
            if pos + buf.len() as u64 >= end {
                break;
            }
        }
        let rest = ((end - pos) as usize).min(buf.len());
        if rest > 0 {
            ticket.write_at(&buf[..rest], pos).map_err(cf_err)?;
            pos += rest as u64;
        }
        if pos < end {
            tracing::warn!("short download of {}", request.path().display());
            return Err(CloudErrorKind::Unsuccessful);
        }
        let _ = ticket.report_progress(end - range.start, end - range.start);
        if end >= size {
            s.set_hydrated(&b.id, Some(&request.path()));
        }
        Ok(())
    }

    fn fetch_placeholders(&self, request: Request, ticket: ticket::FetchPlaceholders, _info: info::FetchPlaceholders) -> CResult<()> {
        let s = &self.s;
        let dir = request.path();
        if s.suppressed(&dir) {
            return Ok(()); // we're deleting it
        }
        let id = if same_path(&dir, &s.root) {
            s.root_id.clone()
        } else {
            parse_blob(request.file_blob()).ok_or(CloudErrorKind::InvalidRequest)?.id
        };
        let (folder, children) = s.block(s.client.list_id(&id)).map_err(dav_cloud)?;
        let mut infos = Vec::new();
        for it in &children {
            if !windows_name_ok(&it.name) || is_excluded_name(&it.name) {
                continue;
            }
            if dir.join(&it.name).try_exists().unwrap_or(true) {
                continue; // never replace a local entry
            }
            infos.push(placeholder_for(it));
        }
        ticket.pass_with_placeholders(&mut infos).map_err(cf_err)?;
        for p in &infos {
            if let Err(e) = p.result() {
                tracing::warn!("placeholder in {}: {e}", dir.display());
            }
        }
        if let Some(f) = folder {
            s.dir_etags.lock().insert(f.id, f.etag);
        }
        Ok(())
    }

    fn delete(&self, request: Request, ticket: ticket::Delete, info: info::Delete) -> CResult<()> {
        if info.is_directory() {
            let mut d = self.deleting_dirs.lock();
            if info.is_undelete() {
                d.remove(&request.file_id());
            } else {
                d.insert(request.file_id());
            }
        }
        ticket.pass().map_err(cf_err)
    }

    fn deleted(&self, request: Request, _info: info::Deleted) {
        // Files are handled in `closed`; this is for directories.
        if !self.deleting_dirs.lock().remove(&request.file_id()) {
            return;
        }
        let path = request.path();
        if self.s.suppressed(&path) {
            return;
        }
        if let Some(b) = parse_blob(request.file_blob()) {
            self.s.send(Work::DeleteDir { id: b.id, path, since: Instant::now() });
        }
    }

    fn closed(&self, request: Request, info: info::Closed) {
        let path = request.path();
        if self.s.suppressed(&path) {
            return;
        }
        if info.deleted() {
            if let Some(b) = parse_blob(request.file_blob()) {
                self.s.send(Work::DeleteFile { id: b.id, path });
            }
        } else {
            self.s.send(Work::Sync(path));
        }
    }

    fn rename(&self, _request: Request, ticket: ticket::Rename, _info: info::Rename) -> CResult<()> {
        ticket.pass().map_err(cf_err)
    }

    fn renamed(&self, request: Request, info: info::Renamed) {
        let s = &self.s;
        let target = request.path();
        let source = info.source_path();
        if s.suppressed(&target) || s.suppressed(&source) {
            return;
        }
        let Some(b) = parse_blob(request.file_blob()) else {
            s.send(Work::Sync(target)); // a local-only file: just upload it where it is now
            return;
        };
        if !s.in_root(&target) {
            // Moved out of the Skyfolder folder: same as deleting it from the drive.
            let is_dir = fs::metadata(&target).map(|m| m.is_dir()).unwrap_or(false);
            s.send(if is_dir {
                Work::DeleteDir { id: b.id, path: source, since: Instant::now() - Duration::from_secs(60) }
            } else {
                Work::DeleteFile { id: b.id, path: source }
            });
            return;
        }
        let tname = target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let sname = source.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if is_temp_name(&tname) && !is_temp_name(&sname) {
            // Probably a safe-save: wait to see whether a replacement shows up.
            s.safe_saves.lock().insert(source, (b.id, target, Instant::now()));
            return;
        }
        if is_temp_name(&sname) {
            let mut ss = s.safe_saves.lock();
            if ss.get(&target).is_some_and(|(id, _, _)| *id == b.id) {
                ss.remove(&target); // renamed back: nothing changed on the server
                drop(ss);
                s.send(Work::Sync(target));
                return;
            }
        }
        s.send(Work::Rename { id: b.id, target });
    }

    fn dehydrate(&self, _request: Request, ticket: ticket::Dehydrate, _info: info::Dehydrate) -> CResult<()> {
        ticket.pass().map_err(cf_err)
    }

    fn dehydrated(&self, request: Request, _info: info::Dehydrated) {
        if let Some(b) = parse_blob(request.file_blob()) {
            self.s.set_hydrated(&b.id, None);
        }
    }

    fn state_changed(&self, event: StateWatchEvent) {
        match event {
            StateWatchEvent::Changed(paths) => {
                for p in paths {
                    if self.s.suppressed(&p) || !self.s.in_root(&p) {
                        continue;
                    }
                    // sync_path walks into new local folders itself; placeholder folders
                    // are never walked here (that would list the whole server).
                    self.s.send(Work::Sync(p));
                }
            }
            StateWatchEvent::Stopped(e) => {
                tracing::error!("Skyfolder folder watcher stopped: {e}; local changes are picked up when files close or after a restart");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn file_time(secs: Option<i64>) -> FileTime {
    secs.and_then(|s| FileTime::from_unix_time(s, 0).ok()).unwrap_or_else(|| {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        FileTime::from_unix_time(now, 0).unwrap_or_default()
    })
}

fn metadata_for(it: &RemoteItem) -> Metadata {
    let t = file_time(it.modified);
    let m = if it.is_folder { Metadata::directory() } else { Metadata::file().size(it.size) };
    m.created(t).written(t).changed(t).accessed(t)
}

fn placeholder_for(it: &RemoteItem) -> PlaceholderCreateInfo {
    PlaceholderCreateInfo::new(&it.name).metadata(metadata_for(it)).mark_in_sync().blob(blob_of(it))
}

fn open_placeholder(p: &Path) -> std::io::Result<Placeholder> {
    fs::OpenOptions::new().access_mode(0).custom_flags(FILE_FLAG_BACKUP_SEMANTICS).open(p).map(Placeholder::from)
}

/// A directory whose children haven't been fetched from the server yet.
fn is_partial(dir: &Path) -> bool {
    open_placeholder(dir).ok().and_then(|ph| ph.state().ok().flatten()).is_some_and(|s| s.partial())
}

/// True if nothing under `dir` differs from the server (only walks populated folders).
fn tree_in_sync(dir: &Path) -> bool {
    if is_partial(dir) {
        return true;
    }
    let Ok(rd) = fs::read_dir(dir) else { return false };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if is_temp_name(&name) {
            continue;
        }
        let Some(info) = open_placeholder(&p).ok().and_then(|ph| ph.info().ok().flatten()) else { return false };
        let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            if !tree_in_sync(&p) {
                return false;
            }
        } else if !info.is_in_sync() || info.modified_data_size() != 0 {
            return false;
        }
    }
    true
}

/// Anything under the root that never reached the server (checked before sign-out).
fn has_unsynced(root: &Path) -> bool {
    let Ok(rd) = fs::read_dir(root) else { return false };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if is_temp_name(&name) {
            continue;
        }
        let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let info = open_placeholder(&p).ok().and_then(|ph| ph.info().ok().flatten());
        match info {
            None => return true,
            Some(i) if is_dir => {
                if !i.is_in_sync() || (!is_partial(&p) && has_unsynced(&p)) {
                    return true;
                }
            }
            Some(i) => {
                if !i.is_in_sync() || i.modified_data_size() != 0 {
                    return true;
                }
            }
        }
    }
    false
}

/// Excluded names plus editor temp files (Office "~$x", "~WRL0001.tmp", "*.tmp"): never uploaded.
fn is_temp_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    is_excluded_name(name) || lower.starts_with('~') || lower.ends_with(".tmp")
}

fn windows_name_ok(n: &str) -> bool {
    if n.is_empty() || n.ends_with('.') || n.ends_with(' ') {
        return false;
    }
    if n.chars().any(|c| matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || (c as u32) < 32) {
        return false;
    }
    let stem = n.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((stem.starts_with("COM") || stem.starts_with("LPT")) && stem.len() == 4 && stem.as_bytes()[3].is_ascii_digit());
    !reserved
}

fn file_name(p: &Path) -> Result<String> {
    p.file_name().map(|n| n.to_string_lossy().to_string()).ok_or_else(|| anyhow!("no file name in {}", p.display()))
}

fn same_path(a: &Path, b: &Path) -> bool {
    a.as_os_str().to_string_lossy().to_lowercase() == b.as_os_str().to_string_lossy().to_lowercase()
}

fn unique_sibling(p: &Path, base: &str) -> PathBuf {
    let parent = p.parent().unwrap_or(p);
    let mut candidate = parent.join(base);
    let mut n = 2;
    while candidate.exists() {
        candidate = parent.join(format!("{base} {n}"));
        n += 1;
    }
    candidate
}

/// Canonical DOS-style path (callbacks report `C:\...`, not `\\?\C:\...`).
fn canonical_path(path: &Path) -> std::io::Result<PathBuf> {
    let path = fs::canonicalize(path)?;
    let Some(Component::Prefix(prefix)) = path.components().next() else { return Ok(path) };
    let mut out = match prefix.kind() {
        Prefix::VerbatimDisk(d) => PathBuf::from(format!("{}:\\", char::from(d))),
        Prefix::VerbatimUNC(server, share) => PathBuf::from(r"\\").join(server).join(share),
        _ => return Ok(path),
    };
    out.extend(path.components().skip(2));
    Ok(out)
}

fn retryable(e: &anyhow::Error) -> bool {
    match e.downcast_ref::<DavError>() {
        Some(DavError::Network(_)) | Some(DavError::Auth(_)) | Some(DavError::InsufficientStorage) => true,
        Some(DavError::Http(code, _)) => *code >= 500 || *code == 429 || *code == 423,
        Some(_) => false,
        None => true, // local I/O (e.g. file busy)
    }
}

fn backoff(tries: u32) -> Duration {
    Duration::from_secs((2u64 << tries.min(6)).min(300))
}

#[allow(dead_code)]
fn _assert_send_sync() {
    fn is<T: Send + Sync>() {}
    is::<SyncRoot>();
    is::<Filter>();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_names() {
        assert!(windows_name_ok("Report 2026.docx"));
        assert!(!windows_name_ok("a:b"));
        assert!(!windows_name_ok("trailing."));
        assert!(!windows_name_ok("CON"));
        assert!(!windows_name_ok("com1.txt"));
        assert!(windows_name_ok("COM10"));
        assert!(windows_name_ok("console.log"));
    }

    #[test]
    fn temp_names() {
        assert!(is_temp_name("~WRL0001.tmp"));
        assert!(is_temp_name("~$report.docx"));
        assert!(is_temp_name("desktop.ini"));
        assert!(!is_temp_name("report.docx"));
    }

    #[test]
    fn blob_roundtrip() {
        let b = serde_json::to_vec(&Blob { id: "s$p!o".into(), etag: "abc".into() }).unwrap();
        let p = parse_blob(&b).unwrap();
        assert_eq!((p.id.as_str(), p.etag.as_str()), ("s$p!o", "abc"));
        assert!(parse_blob(b"not json").is_none());
        assert_eq!(unquote("W/\"abc\""), "abc");
    }
}
