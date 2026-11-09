//! Linux on-demand filesystem. Folders list from the server (cached briefly), files download into a local
//! cache on first open and upload when the last writer closes them. Pinned ("available offline") items are
//! prefetched and never evicted.

use fuser::{
    FileAttr, FileType, Filesystem, KernelConfig, MountOption, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen,
    ReplyStatfs, ReplyWrite, Request, TimeOrNow,
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use skyfolder_core::store::PinnedStore;
use skyfolder_core::{is_excluded_name, DavClient, DavError, RemoteItem, UploadTarget};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::runtime::Handle as Rt;

const ROOT_INO: u64 = 1;
const ATTR_TTL: Duration = Duration::from_secs(2);
const LIST_TTL: Duration = Duration::from_secs(10);
const DEFAULT_CACHE_LIMIT: u64 = 5 * 1024 * 1024 * 1024;

#[derive(Clone)]
struct Node {
    id: String,
    parent: u64,
    name: String,
    item: RemoteItem,
    children: Option<(Vec<u64>, Instant)>,
    /// Exists only locally: new file not uploaded yet, or an excluded (lock/temp) file.
    local_only: bool,
    open_count: u32,
    dirty: bool,
}

struct OpenFile {
    ino: u64,
    file: File,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct CacheEntry {
    etag: String,
    size: u64,
    last_access: u64,
    name: String,
    path: Option<String>,
}

struct Inner {
    nodes: HashMap<u64, Node>,
    by_id: HashMap<String, u64>,
    next_ino: u64,
    files: HashMap<u64, OpenFile>,
    next_fh: u64,
    next_local: u64,
    cache: HashMap<String, CacheEntry>,
    quota: Option<(u64, Option<u64>)>,
}

/// Shared engine state; also used by the app (pin/unpin, cached-item listing).
pub struct Engine {
    client: Arc<DavClient>,
    rt: Rt,
    inner: Mutex<Inner>,
    cache_dir: PathBuf,
    uid: u32,
    gid: u32,
    cache_limit: u64,
}

pub struct MountHandle {
    pub engine: Arc<Engine>,
    _session: fuser::BackgroundSession,
    stop: Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for MountHandle {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn errno(e: &DavError) -> i32 {
    match e {
        DavError::NotFound => libc::ENOENT,
        DavError::AlreadyExists => libc::EEXIST,
        DavError::InsufficientStorage => libc::ENOSPC,
        DavError::PreconditionFailed => libc::EAGAIN,
        e if e.is_auth() => libc::EACCES,
        DavError::Io(_) => libc::EIO,
        _ => libc::EIO,
    }
}

/// Mounts the drive at `dir` (created if missing). Unmounts when the handle is dropped.
pub fn mount(client: Arc<DavClient>, dir: &Path) -> anyhow::Result<MountHandle> {
    std::fs::create_dir_all(dir)?;
    // Clean up a stale mount from a crashed run.
    let _ = std::process::Command::new("fusermount3").arg("-uz").arg(dir).output();

    let rt = Rt::current();
    let root_id = client.account.root_id.clone();
    let root_item = RemoteItem {
        id: root_id.clone(),
        parent_id: None,
        name: String::new(),
        path: Some(String::new()),
        is_folder: true,
        size: 0,
        modified: None,
        etag: String::new(),
        content_type: None,
        permissions: String::new(),
        tags: vec![],
        private_link: None,
        has_preview: false,
        trash_key: None,
        original_location: None,
        deleted_at: None,
    };
    let mut nodes = HashMap::new();
    nodes.insert(
        ROOT_INO,
        Node { id: root_id.clone(), parent: ROOT_INO, name: String::new(), item: root_item, children: None, local_only: false, open_count: 0, dirty: false },
    );
    let mut by_id = HashMap::new();
    by_id.insert(root_id, ROOT_INO);

    let cache_dir = skyfolder_core::paths::cache_dir().join("files");
    std::fs::create_dir_all(&cache_dir)?;
    let cache: HashMap<String, CacheEntry> = std::fs::read(cache_dir.join("index.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();

    let engine = Arc::new(Engine {
        client,
        rt,
        inner: Mutex::new(Inner { nodes, by_id, next_ino: 2, files: HashMap::new(), next_fh: 1, next_local: 1, cache, quota: None }),
        cache_dir,
        uid: unsafe { libc::getuid() },
        gid: unsafe { libc::getgid() },
        cache_limit: std::env::var("SKYFOLDER_CACHE_LIMIT_MB").ok().and_then(|s| s.parse::<u64>().ok()).map(|m| m * 1024 * 1024).unwrap_or(DEFAULT_CACHE_LIMIT),
    });

    let fs = Fs { e: engine.clone() };
    let opts = [MountOption::FSName("skyfolder".into()), MountOption::Subtype("skyfolder".into()), MountOption::NoAtime, MountOption::NoDev, MountOption::NoSuid];
    let session = fuser::spawn_mount2(fs, dir, &opts)?;

    // Background maintenance: refresh quota, keep pinned items current, trim the cache.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let e = engine.clone();
        let stop = stop.clone();
        engine.rt.spawn(async move {
            loop {
                if let Ok(q) = e.client.quota().await {
                    e.inner.lock().quota = Some((q.used, q.total));
                }
                e.sync_pinned().await;
                e.trim_cache();
                for _ in 0..60 {
                    if stop.load(std::sync::atomic::Ordering::SeqCst) {
                        return;
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        });
    }
    Ok(MountHandle { engine, _session: session, stop })
}

impl Engine {
    fn cache_path(&self, id: &str) -> PathBuf {
        let safe: String = id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
        self.cache_dir.join(safe)
    }

    fn save_index(&self, inner: &Inner) {
        if let Ok(d) = serde_json::to_vec(&inner.cache) {
            let tmp = self.cache_dir.join("index.json.tmp");
            if std::fs::write(&tmp, d).is_ok() {
                let _ = std::fs::rename(tmp, self.cache_dir.join("index.json"));
            }
        }
    }

    fn attr(&self, ino: u64, n: &Node) -> FileAttr {
        let size = if n.item.is_folder { 4096 } else { n.item.size };
        let t = n.item.modified_time();
        let writable = if n.item.is_folder { n.item.can_add_children() } else { n.item.can_write() };
        FileAttr {
            ino,
            size,
            blocks: size.div_ceil(512),
            atime: t,
            mtime: t,
            ctime: t,
            crtime: t,
            kind: if n.item.is_folder { FileType::Directory } else { FileType::RegularFile },
            perm: match (n.item.is_folder, writable) {
                (true, true) => 0o755,
                (true, false) => 0o555,
                (false, true) => 0o644,
                (false, false) => 0o444,
            },
            nlink: if n.item.is_folder { 2 } else { 1 },
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 4096,
            flags: 0,
        }
    }

    fn child_path(parent_path: Option<&str>, name: &str) -> Option<String> {
        parent_path.map(|p| if p.is_empty() { name.to_string() } else { format!("{p}/{name}") })
    }

    /// Inserts/updates a node for a server item under `parent`, returning its inode.
    fn upsert(inner: &mut Inner, parent: u64, mut item: RemoteItem) -> u64 {
        let parent_path = inner.nodes.get(&parent).and_then(|p| p.item.path.clone());
        if item.path.is_none() {
            item.path = Self::child_path(parent_path.as_deref(), &item.name);
        }
        if let Some(&ino) = inner.by_id.get(&item.id) {
            if let Some(n) = inner.nodes.get_mut(&ino) {
                let keep_size = n.dirty || n.open_count > 0;
                let old_size = n.item.size;
                n.parent = parent;
                n.name = item.name.clone();
                n.item = item;
                if keep_size {
                    n.item.size = old_size;
                }
            }
            return ino;
        }
        let ino = inner.next_ino;
        inner.next_ino += 1;
        inner.by_id.insert(item.id.clone(), ino);
        inner.nodes.insert(ino, Node { id: item.id.clone(), parent, name: item.name.clone(), item, children: None, local_only: false, open_count: 0, dirty: false });
        ino
    }

    fn find_child(inner: &Inner, parent: u64, name: &str) -> Option<u64> {
        let (kids, _) = inner.nodes.get(&parent)?.children.as_ref()?;
        kids.iter().copied().find(|k| inner.nodes.get(k).map(|n| n.name == name).unwrap_or(false))
    }

    fn children_fresh(inner: &Inner, ino: u64) -> bool {
        inner.nodes.get(&ino).and_then(|n| n.children.as_ref()).map(|(_, t)| t.elapsed() < LIST_TTL).unwrap_or(false)
    }

    /// Re-lists a folder from the server, keeping local-only children.
    async fn refresh_children(&self, ino: u64) -> Result<(), DavError> {
        let id = self.inner.lock().nodes.get(&ino).map(|n| n.id.clone()).ok_or(DavError::NotFound)?;
        let (folder, children) = self.client.list_id(&id).await?;
        let mut inner = self.inner.lock();
        if let Some(f) = folder {
            if let Some(n) = inner.nodes.get_mut(&ino) {
                n.item.etag = f.etag;
                n.item.modified = f.modified;
                n.item.permissions = f.permissions;
            }
        }
        let mut kids: Vec<u64> = children.into_iter().map(|c| Self::upsert(&mut inner, ino, c)).collect();
        // Keep local-only nodes (pending uploads / lock files) visible.
        if let Some((old, _)) = inner.nodes.get(&ino).and_then(|n| n.children.clone()) {
            for k in old {
                if inner.nodes.get(&k).map(|n| n.local_only || n.dirty).unwrap_or(false) && !kids.contains(&k) {
                    kids.push(k);
                }
            }
        }
        if let Some(n) = inner.nodes.get_mut(&ino) {
            n.children = Some((kids, Instant::now()));
        }
        Ok(())
    }

    async fn ensure_children(&self, ino: u64) -> Result<(), DavError> {
        if Self::children_fresh(&self.inner.lock(), ino) {
            return Ok(());
        }
        self.refresh_children(ino).await
    }

    /// Makes sure the file's current server version is in the cache. Returns the cache path.
    async fn ensure_cached(&self, ino: u64) -> Result<PathBuf, DavError> {
        let (id, etag, local_only, dirty, name, path) = {
            let inner = self.inner.lock();
            let n = inner.nodes.get(&ino).ok_or(DavError::NotFound)?;
            (n.id.clone(), n.item.etag.clone(), n.local_only, n.dirty, n.name.clone(), n.item.path.clone())
        };
        let cp = self.cache_path(&id);
        if local_only || dirty {
            if !cp.exists() {
                File::create(&cp)?;
            }
            return Ok(cp);
        }
        let cached = self.inner.lock().cache.get(&id).cloned();
        if let Some(c) = &cached {
            if c.etag == etag && cp.exists() {
                let mut inner = self.inner.lock();
                if let Some(e) = inner.cache.get_mut(&id) {
                    e.last_access = now_secs();
                }
                return Ok(cp);
            }
        }
        // Fresh metadata first so we store the etag of what we download.
        let item = self.client.item_by_id(&id).await?;
        self.client.download(&id, &cp, None).await?;
        let mut inner = self.inner.lock();
        if let Some(n) = inner.nodes.get_mut(&ino) {
            if !n.dirty {
                n.item.etag = item.etag.clone();
                n.item.size = item.size;
                n.item.modified = item.modified;
            }
        }
        inner.cache.insert(id, CacheEntry { etag: item.etag, size: item.size, last_access: now_secs(), name, path: path.or(item.path) });
        self.save_index(&inner);
        Ok(cp)
    }

    /// Uploads a dirty file once no handles remain open.
    async fn upload_node(self: &Arc<Self>, ino: u64) {
        let (id, parent, name, local_only, base_etag, mtime) = {
            let inner = self.inner.lock();
            let Some(n) = inner.nodes.get(&ino) else { return };
            if !n.dirty || n.open_count > 0 || is_excluded_name(&n.name) {
                return;
            }
            let parent_id = inner.nodes.get(&n.parent).map(|p| p.id.clone()).unwrap_or_default();
            let base = inner.cache.get(&n.id).map(|c| c.etag.clone());
            (n.id.clone(), parent_id, n.name.clone(), n.local_only, base, n.item.modified)
        };
        let cp = self.cache_path(&id);
        let result = if local_only {
            // New file: never overwrite something that appeared on the server meanwhile.
            match self.client.available_name(&parent, &name).await {
                Ok(target) => self.client.upload(&cp, UploadTarget::New { parent_id: &parent, name: &target }, mtime, None).await,
                Err(e) => Err(e),
            }
        } else {
            match self.client.upload(&cp, UploadTarget::Existing { id: &id, if_match: base_etag.as_deref() }, mtime, None).await {
                Err(DavError::PreconditionFailed) => {
                    // Changed here and on the server: keep both.
                    let cname = skyfolder_core::conflict_name(&name);
                    let r = self.client.upload(&cp, UploadTarget::New { parent_id: &parent, name: &cname }, mtime, None).await;
                    if r.is_ok() {
                        // Our copy now lives in the conflict file; drop the stale cache so the server version is fetched.
                        let mut inner = self.inner.lock();
                        inner.cache.remove(&id);
                        if let Some(n) = inner.nodes.get_mut(&ino) {
                            n.dirty = false;
                        }
                        let pino = n_parent(&inner, ino);
                        if let Some(p) = inner.nodes.get_mut(&pino) {
                            p.children = None;
                        }
                        let _ = std::fs::remove_file(&cp);
                        tracing::warn!("conflict on {name}: saved local changes as {cname}");
                        return;
                    }
                    r
                }
                other => other,
            }
        };
        match result {
            Ok(item) => {
                let mut inner = self.inner.lock();
                let new_cp = self.cache_path(&item.id);
                if item.id != id {
                    let _ = std::fs::rename(&cp, &new_cp);
                    inner.by_id.remove(&id);
                    inner.by_id.insert(item.id.clone(), ino);
                    inner.cache.remove(&id);
                }
                inner.cache.insert(
                    item.id.clone(),
                    CacheEntry { etag: item.etag.clone(), size: item.size, last_access: now_secs(), name: item.name.clone(), path: item.path.clone() },
                );
                if let Some(n) = inner.nodes.get_mut(&ino) {
                    n.id = item.id.clone();
                    n.name = item.name.clone();
                    let path = n.item.path.clone();
                    n.item = item;
                    if n.item.path.is_none() {
                        n.item.path = path;
                    }
                    n.local_only = false;
                    n.dirty = false;
                }
                self.save_index(&inner);
            }
            Err(e) => tracing::error!("upload of {name} failed: {e}"),
        }
    }

    // ---------- offline / cache API used by the app ----------

    /// Remote ids whose contents are currently cached on this computer.
    pub fn cached_ids(&self) -> Vec<String> {
        self.inner.lock().cache.keys().cloned().collect()
    }

    /// Pins or unpins items. Pinned items are downloaded now and kept current; unpinned ones are evicted.
    pub async fn set_offline(self: &Arc<Self>, items: &[RemoteItem], on: bool) {
        for it in items {
            PinnedStore::set(&it.id, on, Some(skyfolder_core::store::PinInfo { name: it.name.clone(), is_folder: it.is_folder, path: it.path.clone() }));
        }
        if on {
            self.sync_pinned().await;
        } else {
            for it in items {
                self.evict_tree(it).await;
            }
        }
    }

    async fn evict_tree(&self, it: &RemoteItem) {
        let pins = PinnedStore::all();
        let mut inner = self.inner.lock();
        let prefix = it.path.clone().map(|p| format!("{p}/"));
        let victims: Vec<String> = inner
            .cache
            .iter()
            .filter(|(id, c)| {
                **id == it.id || (it.is_folder && prefix.as_ref().zip(c.path.as_ref()).map(|(pre, p)| p.starts_with(pre.as_str())).unwrap_or(false))
            })
            .filter(|(id, c)| !PinnedStore::covers(&pins, id, c.path.as_deref()))
            .map(|(id, _)| id.clone())
            .collect();
        for id in victims {
            let busy = inner.by_id.get(&id).and_then(|i| inner.nodes.get(i)).map(|n| n.open_count > 0 || n.dirty).unwrap_or(false);
            if !busy {
                inner.cache.remove(&id);
                let _ = std::fs::remove_file(self.cache_path(&id));
            }
        }
        self.save_index(&inner);
    }

    /// Downloads every pinned file (recursively for folders) whose cached copy is missing or stale.
    async fn sync_pinned(&self) {
        let pins = PinnedStore::all();
        for (id, info) in pins {
            if info.is_folder {
                let mut stack = vec![id.clone()];
                let mut seen = 0;
                while let Some(fid) = stack.pop() {
                    seen += 1;
                    if seen > 10_000 {
                        break;
                    }
                    let Ok((_, kids)) = self.client.list_id(&fid).await else { continue };
                    for k in kids {
                        if k.is_folder {
                            stack.push(k.id.clone());
                        } else {
                            self.prefetch(&k).await;
                        }
                    }
                }
            } else if let Ok(item) = self.client.item_by_id(&id).await {
                self.prefetch(&item).await;
            }
        }
    }

    async fn prefetch(&self, item: &RemoteItem) {
        let up_to_date = self.inner.lock().cache.get(&item.id).map(|c| c.etag == item.etag).unwrap_or(false);
        let busy = {
            let inner = self.inner.lock();
            inner.by_id.get(&item.id).and_then(|i| inner.nodes.get(i)).map(|n| n.dirty || n.open_count > 0).unwrap_or(false)
        };
        if up_to_date || busy {
            return;
        }
        let cp = self.cache_path(&item.id);
        if self.client.download(&item.id, &cp, None).await.is_ok() {
            let mut inner = self.inner.lock();
            inner.cache.insert(
                item.id.clone(),
                CacheEntry { etag: item.etag.clone(), size: item.size, last_access: now_secs(), name: item.name.clone(), path: item.path.clone() },
            );
            if let Some(&ino) = inner.by_id.get(&item.id) {
                if let Some(n) = inner.nodes.get_mut(&ino) {
                    n.item.etag = item.etag.clone();
                    n.item.size = item.size;
                }
            }
            self.save_index(&inner);
        }
    }

    /// Evicts least-recently-used, unpinned, idle files until the cache fits the limit.
    fn trim_cache(&self) {
        let pins = PinnedStore::all();
        let mut inner = self.inner.lock();
        let mut total: u64 = inner.cache.values().map(|c| c.size).sum();
        if total <= self.cache_limit {
            return;
        }
        let mut entries: Vec<(String, CacheEntry)> = inner.cache.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        entries.sort_by_key(|(_, c)| c.last_access);
        for (id, c) in entries {
            if total <= self.cache_limit {
                break;
            }
            if PinnedStore::covers(&pins, &id, c.path.as_deref()) {
                continue;
            }
            let busy = inner.by_id.get(&id).and_then(|i| inner.nodes.get(i)).map(|n| n.open_count > 0 || n.dirty).unwrap_or(false);
            if busy {
                continue;
            }
            inner.cache.remove(&id);
            let _ = std::fs::remove_file(self.cache_path(&id));
            total = total.saturating_sub(c.size);
        }
        self.save_index(&inner);
    }

    /// Forgets all cached contents (sign-out).
    pub fn clear_cache(&self) {
        let mut inner = self.inner.lock();
        inner.cache.clear();
        let _ = std::fs::remove_dir_all(&self.cache_dir);
        let _ = std::fs::create_dir_all(&self.cache_dir);
    }
}

fn n_parent(inner: &Inner, ino: u64) -> u64 {
    inner.nodes.get(&ino).map(|n| n.parent).unwrap_or(ROOT_INO)
}

struct Fs {
    e: Arc<Engine>,
}

impl Fs {
    fn name(n: &OsStr) -> Option<String> {
        n.to_str().map(String::from)
    }
}

impl Filesystem for Fs {
    fn init(&mut self, _req: &Request<'_>, _config: &mut KernelConfig) -> Result<(), libc::c_int> {
        Ok(())
    }

    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let Some(name) = Self::name(name) else { return reply.error(libc::ENOENT) };
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            if let Err(err) = e.ensure_children(parent).await {
                return reply.error(errno(&err));
            }
            let inner = e.inner.lock();
            match Engine::find_child(&inner, parent, &name) {
                Some(ino) => {
                    let n = &inner.nodes[&ino];
                    reply.entry(&ATTR_TTL, &e.attr(ino, n), 0)
                }
                None => reply.error(libc::ENOENT),
            }
        });
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
        let inner = self.e.inner.lock();
        match inner.nodes.get(&ino) {
            Some(n) => reply.attr(&ATTR_TTL, &self.e.attr(ino, n)),
            None => reply.error(libc::ENOENT),
        }
    }

    fn setattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            if let Some(sz) = size {
                // Truncate through an open handle if we have one, else via the cache file.
                let path = {
                    let inner = e.inner.lock();
                    fh.and_then(|h| inner.files.get(&h)).map(|_| ())
                };
                let res: Result<(), DavError> = async {
                    if path.is_some() {
                        let inner = e.inner.lock();
                        if let Some(f) = fh.and_then(|h| inner.files.get(&h)) {
                            f.file.set_len(sz)?;
                        }
                    } else {
                        let cp = if sz == 0 {
                            let id = e.inner.lock().nodes.get(&ino).map(|n| n.id.clone()).ok_or(DavError::NotFound)?;
                            let cp = e.cache_path(&id);
                            File::create(&cp)?;
                            cp
                        } else {
                            e.ensure_cached(ino).await?
                        };
                        OpenOptions::new().write(true).open(&cp)?.set_len(sz)?;
                    }
                    let mut inner = e.inner.lock();
                    if let Some(n) = inner.nodes.get_mut(&ino) {
                        n.item.size = sz;
                        n.dirty = true;
                    }
                    Ok(())
                }
                .await;
                if let Err(err) = res {
                    return reply.error(errno(&err));
                }
                let idle = e.inner.lock().nodes.get(&ino).map(|n| n.open_count == 0).unwrap_or(false);
                if idle {
                    e.upload_node(ino).await;
                }
            }
            if let Some(t) = mtime {
                let secs = match t {
                    TimeOrNow::Now => now_secs() as i64,
                    TimeOrNow::SpecificTime(st) => st.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0),
                };
                if let Some(n) = e.inner.lock().nodes.get_mut(&ino) {
                    n.item.modified = Some(secs);
                }
            }
            let inner = e.inner.lock();
            match inner.nodes.get(&ino) {
                Some(n) => reply.attr(&ATTR_TTL, &e.attr(ino, n)),
                None => reply.error(libc::ENOENT),
            }
        });
    }

    fn readdir(&mut self, _req: &Request<'_>, ino: u64, _fh: u64, offset: i64, mut reply: ReplyDirectory) {
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            if offset == 0 {
                if let Err(err) = e.refresh_children(ino).await {
                    return reply.error(errno(&err));
                }
            } else if let Err(err) = e.ensure_children(ino).await {
                return reply.error(errno(&err));
            }
            let inner = e.inner.lock();
            let Some(node) = inner.nodes.get(&ino) else { return reply.error(libc::ENOENT) };
            let mut entries: Vec<(u64, FileType, String)> = vec![(ino, FileType::Directory, ".".into()), (node.parent, FileType::Directory, "..".into())];
            if let Some((kids, _)) = &node.children {
                for k in kids {
                    if let Some(c) = inner.nodes.get(k) {
                        entries.push((*k, if c.item.is_folder { FileType::Directory } else { FileType::RegularFile }, c.name.clone()));
                    }
                }
            }
            for (i, (ino, kind, name)) in entries.into_iter().enumerate().skip(offset as usize) {
                if reply.add(ino, (i + 1) as i64, kind, name) {
                    break;
                }
            }
            reply.ok();
        });
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            let write = (flags & libc::O_ACCMODE) != libc::O_RDONLY;
            let trunc = flags & libc::O_TRUNC != 0;
            let res: Result<File, DavError> = async {
                let cp = if trunc && write {
                    let id = e.inner.lock().nodes.get(&ino).map(|n| n.id.clone()).ok_or(DavError::NotFound)?;
                    let cp = e.cache_path(&id);
                    File::create(&cp)?;
                    let mut inner = e.inner.lock();
                    if let Some(n) = inner.nodes.get_mut(&ino) {
                        n.item.size = 0;
                        n.dirty = true;
                    }
                    cp
                } else {
                    e.ensure_cached(ino).await?
                };
                Ok(OpenOptions::new().read(true).write(write).open(cp)?)
            }
            .await;
            match res {
                Ok(file) => {
                    let mut inner = e.inner.lock();
                    let fh = inner.next_fh;
                    inner.next_fh += 1;
                    inner.files.insert(fh, OpenFile { ino, file });
                    if let Some(n) = inner.nodes.get_mut(&ino) {
                        n.open_count += 1;
                    }
                    reply.opened(fh, 0);
                }
                Err(err) => reply.error(errno(&err)),
            }
        });
    }

    fn read(&mut self, _req: &Request<'_>, _ino: u64, fh: u64, offset: i64, size: u32, _flags: i32, _lock: Option<u64>, reply: ReplyData) {
        let inner = self.e.inner.lock();
        let Some(f) = inner.files.get(&fh) else { return reply.error(libc::EBADF) };
        let mut buf = vec![0u8; size as usize];
        match f.file.read_at(&mut buf, offset as u64) {
            Ok(n) => reply.data(&buf[..n]),
            Err(_) => reply.error(libc::EIO),
        }
    }

    fn write(&mut self, _req: &Request<'_>, _ino: u64, fh: u64, offset: i64, data: &[u8], _wf: u32, _flags: i32, _lock: Option<u64>, reply: ReplyWrite) {
        let mut inner = self.e.inner.lock();
        let Some(f) = inner.files.get(&fh) else { return reply.error(libc::EBADF) };
        let ino = f.ino;
        match f.file.write_all_at(data, offset as u64) {
            Ok(()) => {
                let len = f.file.metadata().map(|m| m.len()).unwrap_or(0);
                if let Some(n) = inner.nodes.get_mut(&ino) {
                    n.dirty = true;
                    n.item.size = len;
                    n.item.modified = Some(now_secs() as i64);
                }
                reply.written(data.len() as u32)
            }
            Err(_) => reply.error(libc::EIO),
        }
    }

    fn flush(&mut self, _req: &Request<'_>, _ino: u64, fh: u64, _lock: u64, reply: ReplyEmpty) {
        if let Some(f) = self.e.inner.lock().files.get(&fh) {
            let _ = f.file.sync_data();
        }
        reply.ok();
    }

    fn release(&mut self, _req: &Request<'_>, ino: u64, fh: u64, _flags: i32, _lock: Option<u64>, _flush: bool, reply: ReplyEmpty) {
        let upload = {
            let mut inner = self.e.inner.lock();
            inner.files.remove(&fh);
            match inner.nodes.get_mut(&ino) {
                Some(n) => {
                    n.open_count = n.open_count.saturating_sub(1);
                    n.open_count == 0 && n.dirty
                }
                None => false,
            }
        };
        reply.ok();
        if upload {
            let e = self.e.clone();
            e.rt.clone().spawn(async move { e.upload_node(ino).await });
        }
    }

    fn create(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, _mode: u32, _umask: u32, _flags: i32, reply: ReplyCreate) {
        let Some(name) = Self::name(name) else { return reply.error(libc::EINVAL) };
        let mut inner = self.e.inner.lock();
        if Engine::find_child(&inner, parent, &name).is_some() {
            return reply.error(libc::EEXIST);
        }
        let parent_path = inner.nodes.get(&parent).and_then(|p| p.item.path.clone());
        let local_id = format!("local-{}", inner.next_local);
        inner.next_local += 1;
        let cp = self.e.cache_path(&local_id);
        let file = match OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&cp) {
            Ok(f) => f,
            Err(_) => return reply.error(libc::EIO),
        };
        let item = RemoteItem {
            id: local_id.clone(),
            parent_id: inner.nodes.get(&parent).map(|p| p.id.clone()),
            name: name.clone(),
            path: Engine::child_path(parent_path.as_deref(), &name),
            is_folder: false,
            size: 0,
            modified: Some(now_secs() as i64),
            etag: String::new(),
            content_type: None,
            permissions: String::new(),
            tags: vec![],
            private_link: None,
            has_preview: false,
            trash_key: None,
            original_location: None,
            deleted_at: None,
        };
        let ino = inner.next_ino;
        inner.next_ino += 1;
        inner.by_id.insert(local_id.clone(), ino);
        inner.nodes.insert(ino, Node { id: local_id, parent, name, item, children: None, local_only: true, open_count: 1, dirty: true });
        if let Some(p) = inner.nodes.get_mut(&parent) {
            match &mut p.children {
                Some((kids, _)) => kids.push(ino),
                None => p.children = Some((vec![ino], Instant::now() - LIST_TTL)),
            }
        }
        let fh = inner.next_fh;
        inner.next_fh += 1;
        inner.files.insert(fh, OpenFile { ino, file });
        let attr = self.e.attr(ino, &inner.nodes[&ino]);
        reply.created(&ATTR_TTL, &attr, 0, fh, 0);
    }

    fn mkdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, _mode: u32, _umask: u32, reply: ReplyEntry) {
        let Some(name) = Self::name(name) else { return reply.error(libc::EINVAL) };
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            let pid = e.inner.lock().nodes.get(&parent).map(|n| n.id.clone());
            let Some(pid) = pid else { return reply.error(libc::ENOENT) };
            match e.client.create_folder(&pid, &name).await {
                Ok(item) => {
                    let mut inner = e.inner.lock();
                    let ino = Engine::upsert(&mut inner, parent, item);
                    if let Some(n) = inner.nodes.get_mut(&ino) {
                        n.children = Some((vec![], Instant::now()));
                    }
                    if let Some((kids, _)) = inner.nodes.get_mut(&parent).and_then(|p| p.children.as_mut()) {
                        if !kids.contains(&ino) {
                            kids.push(ino);
                        }
                    }
                    let attr = e.attr(ino, &inner.nodes[&ino]);
                    reply.entry(&ATTR_TTL, &attr, 0)
                }
                Err(err) => reply.error(errno(&err)),
            }
        });
    }

    fn unlink(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        self.remove(parent, name, false, reply);
    }

    fn rmdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        self.remove(parent, name, true, reply);
    }

    fn rename(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, newparent: u64, newname: &OsStr, _flags: u32, reply: ReplyEmpty) {
        let (Some(name), Some(newname)) = (Self::name(name), Self::name(newname)) else { return reply.error(libc::EINVAL) };
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            let res = e.do_rename(parent, &name, newparent, &newname).await;
            match res {
                Ok(()) => reply.ok(),
                Err(err) => reply.error(err),
            }
        });
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        let bsize: u64 = 4096;
        let (used, total) = self.e.inner.lock().quota.unwrap_or((0, None));
        let total = total.unwrap_or(used.max(1) * 4 + 1024 * 1024 * 1024 * 1024);
        let blocks = total / bsize;
        let free = total.saturating_sub(used) / bsize;
        reply.statfs(blocks, free, free, 1_000_000, 1_000_000, bsize as u32, 255, bsize as u32);
    }

    fn access(&mut self, _req: &Request<'_>, _ino: u64, _mask: i32, reply: ReplyEmpty) {
        reply.ok();
    }
}

impl Fs {
    fn remove(&mut self, parent: u64, name: &OsStr, dir: bool, reply: ReplyEmpty) {
        let Some(name) = Self::name(name) else { return reply.error(libc::EINVAL) };
        let e = self.e.clone();
        e.rt.clone().spawn(async move {
            if let Err(err) = e.ensure_children(parent).await {
                return reply.error(errno(&err));
            }
            let target = {
                let inner = e.inner.lock();
                Engine::find_child(&inner, parent, &name).map(|ino| (ino, inner.nodes[&ino].clone()))
            };
            let Some((ino, node)) = target else { return reply.error(libc::ENOENT) };
            if dir != node.item.is_folder {
                return reply.error(if dir { libc::ENOTDIR } else { libc::EISDIR });
            }
            if dir {
                if let Err(err) = e.refresh_children(ino).await {
                    return reply.error(errno(&err));
                }
                let empty = e.inner.lock().nodes.get(&ino).and_then(|n| n.children.as_ref()).map(|(k, _)| k.is_empty()).unwrap_or(true);
                if !empty {
                    return reply.error(libc::ENOTEMPTY);
                }
            }
            if !node.local_only {
                if let Err(err) = e.client.delete(&node.id).await {
                    return reply.error(errno(&err));
                }
            }
            let mut inner = e.inner.lock();
            if let Some((kids, _)) = inner.nodes.get_mut(&parent).and_then(|p| p.children.as_mut()) {
                kids.retain(|k| *k != ino);
            }
            if node.open_count == 0 {
                inner.nodes.remove(&ino);
            } else if let Some(n) = inner.nodes.get_mut(&ino) {
                // Still open: keep serving the handle but never upload it.
                n.local_only = true;
                n.dirty = false;
                n.name = format!(".deleted-{}", n.name);
            }
            inner.by_id.remove(&node.id);
            inner.cache.remove(&node.id);
            if node.open_count == 0 {
                let _ = std::fs::remove_file(e.cache_path(&node.id));
            }
            e.save_index(&inner);
            reply.ok();
        });
    }
}

impl Engine {
    async fn do_rename(self: &Arc<Self>, parent: u64, name: &str, newparent: u64, newname: &str) -> Result<(), i32> {
        self.ensure_children(parent).await.map_err(|e| errno(&e))?;
        self.ensure_children(newparent).await.map_err(|e| errno(&e))?;
        let (src_ino, src, dst, newparent_id) = {
            let inner = self.inner.lock();
            let src_ino = Engine::find_child(&inner, parent, name).ok_or(libc::ENOENT)?;
            let dst = Engine::find_child(&inner, newparent, newname).map(|i| (i, inner.nodes[&i].clone()));
            let np = inner.nodes.get(&newparent).map(|n| n.id.clone()).ok_or(libc::ENOENT)?;
            (src_ino, inner.nodes[&src_ino].clone(), dst, np)
        };

        // Safe-save pattern: a local temp file renamed over an existing server file -> upload new contents
        // into the existing file (keeps its id, versions and shares).
        if src.local_only && !src.item.is_folder {
            if let Some((dst_ino, dst_node)) = dst.as_ref().filter(|(_, d)| !d.local_only && !d.item.is_folder) {
                let dst_ino = *dst_ino;
                let src_cp = self.cache_path(&src.id);
                let dst_cp = self.cache_path(&dst_node.id);
                std::fs::rename(&src_cp, &dst_cp).map_err(|_| libc::EIO)?;
                {
                    let mut inner = self.inner.lock();
                    let len = std::fs::metadata(&dst_cp).map(|m| m.len()).unwrap_or(0);
                    if let Some(n) = inner.nodes.get_mut(&dst_ino) {
                        n.dirty = true;
                        n.item.size = len;
                        n.item.modified = Some(now_secs() as i64);
                    }
                    if let Some((kids, _)) = inner.nodes.get_mut(&parent).and_then(|p| p.children.as_mut()) {
                        kids.retain(|k| *k != src_ino);
                    }
                    inner.nodes.remove(&src_ino);
                    inner.by_id.remove(&src.id);
                }
                self.upload_node(dst_ino).await;
                return Ok(());
            }
        }

        // Replace an existing target (POSIX rename semantics).
        if let Some((dst_ino, dst_node)) = &dst {
            if dst_node.item.is_folder != src.item.is_folder {
                return Err(if dst_node.item.is_folder { libc::EISDIR } else { libc::ENOTDIR });
            }
            if !dst_node.local_only {
                self.client.delete(&dst_node.id).await.map_err(|e| errno(&e))?;
            }
            let mut inner = self.inner.lock();
            if let Some((kids, _)) = inner.nodes.get_mut(&newparent).and_then(|p| p.children.as_mut()) {
                kids.retain(|k| k != dst_ino);
            }
            inner.nodes.remove(dst_ino);
            inner.by_id.remove(&dst_node.id);
        }

        let mut moved_item = None;
        if !src.local_only {
            moved_item = Some(self.client.move_item(&src.id, &newparent_id, newname, false).await.map_err(|e| errno(&e))?);
        }
        let needs_upload = {
            let mut inner = self.inner.lock();
            let new_parent_path = inner.nodes.get(&newparent).and_then(|n| n.item.path.clone());
            if let Some((kids, _)) = inner.nodes.get_mut(&parent).and_then(|p| p.children.as_mut()) {
                kids.retain(|k| *k != src_ino);
            }
            if let Some((kids, _)) = inner.nodes.get_mut(&newparent).and_then(|p| p.children.as_mut()) {
                kids.push(src_ino);
            }
            let n = inner.nodes.get_mut(&src_ino).ok_or(libc::ENOENT)?;
            n.parent = newparent;
            n.name = newname.to_string();
            n.item.name = newname.to_string();
            n.item.path = Engine::child_path(new_parent_path.as_deref(), newname);
            if let Some(m) = moved_item {
                n.item.etag = m.etag;
            }
            if n.item.is_folder {
                n.children = None; // descendants' paths changed; re-list lazily
            }
            // A local temp file renamed to a real name with no open handles: upload now.
            n.local_only && n.open_count == 0 && !is_excluded_name(newname)
        };
        if needs_upload {
            if let Some(n) = self.inner.lock().nodes.get_mut(&src_ino) {
                n.dirty = true;
            }
            self.upload_node(src_ino).await;
        }
        Ok(())
    }
}
