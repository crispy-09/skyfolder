//! OpenCloud WebDAV (spaces) + LibreGraph client. Port of the macOS app's DAVClient.

use crate::account::Account;
use crate::auth::{AuthError, TokenProvider};
use crate::model::RemoteItem;
use crate::xml::{escape, parse_multistatus, DavResponse};
use futures_util::StreamExt;
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use reqwest::{header, Method, StatusCode};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

#[derive(Debug, thiserror::Error)]
pub enum DavError {
    #[error("The item no longer exists on the server.")]
    NotFound,
    #[error("The item was changed on the server.")]
    PreconditionFailed,
    #[error("An item with that name already exists.")]
    AlreadyExists,
    #[error("Not enough storage space on the server.")]
    InsufficientStorage,
    #[error("{0}")]
    Auth(#[from] AuthError),
    #[error("Server error {0}{suffix}", suffix = .1.as_ref().map(|m| format!(": {m}")).unwrap_or_default())]
    Http(u16, Option<String>),
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("Cancelled")]
    Cancelled,
}

impl DavError {
    pub fn is_auth(&self) -> bool {
        matches!(self, DavError::Auth(AuthError::NotSignedIn | AuthError::SessionExpired)) || matches!(self, DavError::Http(401, _))
    }
}

pub type Result<T> = std::result::Result<T, DavError>;

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quota {
    pub used: u64,
    pub total: Option<u64>,
}

pub enum UploadTarget<'a> {
    New { parent_id: &'a str, name: &'a str },
    Existing { id: &'a str, if_match: Option<&'a str> },
}

/// Progress callback: (bytes done, bytes total).
pub type ProgressFn<'a> = &'a (dyn Fn(u64, u64) + Send + Sync);

// RFC 3986 unreserved chars stay; everything else is encoded.
const NAME: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');
const ID: &AsciiSet = &NAME.remove(b'$').remove(b'!');

const PROPFIND: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>
<d:getlastmodified/><d:getetag/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
<oc:fileid/><oc:file-parent/><oc:name/><oc:permissions/><oc:size/><oc:tags/><oc:privatelink/><oc:has-preview/>
</d:prop></d:propfind>"#;

const TRASH_PROPFIND: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>
<oc:trashbin-original-filename/><oc:trashbin-original-location/><oc:trashbin-delete-datetime/>
<d:getcontentlength/><oc:size/><d:resourcetype/><d:getcontenttype/>
</d:prop></d:propfind>"#;

#[derive(Clone)]
pub struct DavClient {
    pub account: Account,
    http: reqwest::Client,
    tokens: Arc<TokenProvider>,
}

impl DavClient {
    pub fn new(account: Account, tokens: Arc<TokenProvider>) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(20))
            .read_timeout(Duration::from_secs(120))
            .pool_max_idle_per_host(8)
            .user_agent(concat!("Skyfolder/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("http client");
        Self { account, http, tokens }
    }

    // ---------- URLs ----------

    fn root(&self) -> &str {
        self.account.server_url.trim_end_matches('/')
    }

    pub fn encode_path(p: &str) -> String {
        p.split('/').filter(|s| !s.is_empty()).map(|s| utf8_percent_encode(s, NAME).to_string()).collect::<Vec<_>>().join("/")
    }

    /// /dav/spaces/<resource>[/<path>] where resource is a space id or a file id.
    pub fn dav_url(&self, resource: &str, path: Option<&str>) -> String {
        let mut s = format!("{}/dav/spaces/{}", self.root(), utf8_percent_encode(resource, ID));
        if let Some(p) = path.filter(|p| !p.is_empty()) {
            s.push('/');
            s.push_str(&Self::encode_path(p));
        }
        s
    }
    pub fn space_path_url(&self, path: &str) -> String { self.dav_url(&self.account.space_id, Some(path)) }
    pub fn id_url(&self, id: &str) -> String { self.dav_url(id, None) }
    pub fn child_url(&self, parent_id: &str, name: &str) -> String { self.dav_url(parent_id, Some(name)) }
    fn trash_url(&self) -> String {
        format!("{}/dav/spaces/trash-bin/{}", self.root(), utf8_percent_encode(&self.account.space_id, ID))
    }
    fn graph_url(&self, p: &str) -> String { format!("{}/graph/v1.0/{p}", self.root()) }
    pub fn archive_url(&self, id: &str) -> String {
        format!("{}/archiver?id={}", self.root(), utf8_percent_encode(id, NAME))
    }

    // ---------- core request ----------

    async fn send(&self, method: Method, url: &str, headers: &[(&str, String)], body: Option<String>, ok_extra: &[u16]) -> Result<(StatusCode, header::HeaderMap, bytes_body::Body)> {
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = self.tokens.access_token(rejected.as_deref()).await?;
            let mut req = self.http.request(method.clone(), url).bearer_auth(&token);
            for (k, v) in headers {
                req = req.header(*k, v);
            }
            if let Some(b) = &body {
                req = req.body(b.clone());
            }
            let resp = req.send().await?;
            let status = resp.status();
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            let hdrs = resp.headers().clone();
            let bytes = resp.bytes().await?;
            check(status, &bytes, ok_extra)?;
            return Ok((status, hdrs, bytes_body::Body(bytes.to_vec())));
        }
        Err(AuthError::SessionExpired.into())
    }

    // ---------- parsing ----------

    fn relative_path(&self, href: &str) -> Option<String> {
        let decoded = percent_decode_str(href).decode_utf8_lossy().to_string();
        let mut t = decoded.as_str();
        if let Some(i) = t.find("://") {
            t = &t[i + 3..];
            t = t.find('/').map(|j| &t[j..]).unwrap_or("/");
        }
        let prefix = format!("/dav/spaces/{}", self.account.space_id);
        let rest = t.strip_prefix(&prefix)?;
        if !rest.is_empty() && !rest.starts_with('/') {
            return None; // id-based href ("...!opaque")
        }
        Some(rest.trim_matches('/').to_string())
    }

    fn item(&self, r: &DavResponse) -> Option<RemoteItem> {
        let p = &r.props;
        let id = p.get("fileid").filter(|s| !s.is_empty())?.clone();
        let path = self.relative_path(&r.href);
        let mut name = p.get("name").cloned().unwrap_or_default();
        if let Some(pp) = path.as_ref().filter(|s| !s.is_empty()) {
            name = pp.rsplit('/').next().unwrap_or(pp).to_string();
        }
        if name.is_empty() {
            name = percent_decode_str(r.href.trim_end_matches('/')).decode_utf8_lossy().rsplit('/').next().unwrap_or("").to_string();
        }
        let is_folder = r.is_collection || p.get("getcontenttype").map(|s| s == "httpd/unix-directory").unwrap_or(false);
        let num = |k: &str| p.get(k).and_then(|s| s.parse::<u64>().ok());
        Some(RemoteItem {
            id,
            parent_id: p.get("file-parent").filter(|s| !s.is_empty()).cloned(),
            name,
            path,
            is_folder,
            size: num("getcontentlength").or(num("size")).unwrap_or(0),
            modified: parse_date(p.get("getlastmodified")),
            etag: p.get("getetag").map(|s| s.trim_matches('"').to_string()).unwrap_or_default(),
            content_type: p.get("getcontenttype").cloned(),
            permissions: p.get("permissions").cloned().unwrap_or_default(),
            tags: p.get("tags").map(|s| s.split(',').map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect()).unwrap_or_default(),
            private_link: p.get("privatelink").cloned(),
            has_preview: p.get("has-preview").map(|s| s == "1").unwrap_or(false),
            trash_key: None,
            original_location: None,
            deleted_at: None,
        })
    }

    // ---------- reading ----------

    /// Lists a folder: (the folder itself, its children).
    pub async fn list(&self, url: &str) -> Result<(Option<RemoteItem>, Vec<RemoteItem>)> {
        let (_, _, body) = self
            .send(Method::from_bytes(b"PROPFIND").unwrap(), url, &[("Depth", "1".into()), ("Content-Type", "application/xml".into())], Some(PROPFIND.into()), &[])
            .await?;
        let responses = parse_multistatus(&body.0);
        let mut it = responses.iter();
        let folder = it.next().and_then(|r| self.item(r));
        let mut children: Vec<RemoteItem> = it.filter_map(|r| self.item(r)).collect();
        if let Some(f) = &folder {
            for c in children.iter_mut() {
                if c.parent_id.is_none() {
                    c.parent_id = Some(f.id.clone());
                }
                if c.path.is_none() {
                    if let Some(fp) = &f.path {
                        c.path = Some(if fp.is_empty() { c.name.clone() } else { format!("{fp}/{}", c.name) });
                    }
                }
            }
        }
        Ok((folder, children))
    }

    pub async fn list_id(&self, id: &str) -> Result<(Option<RemoteItem>, Vec<RemoteItem>)> { self.list(&self.id_url(id)).await }
    pub async fn list_path(&self, path: &str) -> Result<(Option<RemoteItem>, Vec<RemoteItem>)> { self.list(&self.space_path_url(path)).await }

    pub async fn stat(&self, url: &str) -> Result<RemoteItem> {
        let (_, _, body) = self
            .send(Method::from_bytes(b"PROPFIND").unwrap(), url, &[("Depth", "0".into()), ("Content-Type", "application/xml".into())], Some(PROPFIND.into()), &[])
            .await?;
        parse_multistatus(&body.0).first().and_then(|r| self.item(r)).ok_or(DavError::NotFound)
    }

    pub async fn item_by_id(&self, id: &str) -> Result<RemoteItem> { self.stat(&self.id_url(id)).await }
    pub async fn item_by_path(&self, path: &str) -> Result<RemoteItem> { self.stat(&self.space_path_url(path)).await }

    pub async fn child(&self, parent_id: &str, name: &str) -> Result<Option<RemoteItem>> {
        match self.stat(&self.child_url(parent_id, name)).await {
            Ok(i) => Ok(Some(i)),
            Err(DavError::NotFound) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// KQL search within the personal space.
    pub async fn search(&self, pattern: &str, limit: usize) -> Result<Vec<RemoteItem>> {
        let body = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<oc:search-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>
<d:getlastmodified/><d:getetag/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
<oc:fileid/><oc:file-parent/><oc:name/><oc:permissions/><oc:size/><oc:tags/><oc:privatelink/><oc:has-preview/>
</d:prop><oc:search><oc:pattern>{}</oc:pattern><oc:limit>{limit}</oc:limit></oc:search></oc:search-files>"#,
            escape(pattern)
        );
        let (_, _, b) = self.send(Method::from_bytes(b"REPORT").unwrap(), &self.space_path_url(""), &[("Content-Type", "application/xml".into())], Some(body), &[]).await?;
        Ok(parse_multistatus(&b.0)
            .iter()
            .filter_map(|r| self.item(r))
            .filter(|i| i.id != self.account.root_id && i.path.as_deref() != Some(""))
            .collect())
    }

    // ---------- transfers ----------

    /// Streams a GET to `dest` (written via a temp file, then renamed).
    pub async fn download_url(&self, url: &str, dest: &Path, progress: Option<ProgressFn<'_>>, range: Option<(u64, u64)>) -> Result<()> {
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = self.tokens.access_token(rejected.as_deref()).await?;
            let mut req = self.http.get(url).bearer_auth(&token);
            if let Some((start, len)) = range {
                req = req.header(header::RANGE, format!("bytes={}-{}", start, start + len.saturating_sub(1)));
            }
            let resp = req.send().await?;
            let status = resp.status();
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            if !status.is_success() {
                let b = resp.bytes().await.unwrap_or_default();
                check(status, &b, &[])?;
                return Err(DavError::Http(status.as_u16(), None));
            }
            let total = resp.content_length().unwrap_or(0);
            let tmp = dest.with_extension("skyfolder-part");
            let mut file = tokio::fs::File::create(&tmp).await?;
            let mut stream = resp.bytes_stream();
            let mut done = 0u64;
            while let Some(chunk) = stream.next().await {
                let chunk = chunk?;
                file.write_all(&chunk).await?;
                done += chunk.len() as u64;
                if let Some(p) = progress {
                    p(done, total);
                }
            }
            file.flush().await?;
            drop(file);
            tokio::fs::rename(&tmp, dest).await?;
            return Ok(());
        }
        Err(AuthError::SessionExpired.into())
    }

    pub async fn download(&self, id: &str, dest: &Path, progress: Option<ProgressFn<'_>>) -> Result<()> {
        self.download_url(&self.id_url(id), dest, progress, None).await
    }

    /// Reads a byte range into memory (used by on-demand hydration).
    /// Starts a ranged GET and returns the response for streaming with `chunk()`.
    /// The bool is true when the server honoured the range (206); on 200 the body starts at byte 0.
    /// The server ignores If-Match on GET, so callers compare the response's ETag header instead.
    pub async fn range_response(&self, id: &str, offset: u64, len: u64) -> Result<(reqwest::Response, bool)> {
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = self.tokens.access_token(rejected.as_deref()).await?;
            let resp = self
                .http
                .get(self.id_url(id))
                .bearer_auth(&token)
                .header(header::RANGE, format!("bytes={}-{}", offset, offset + len.saturating_sub(1)))
                .send()
                .await?;
            let status = resp.status();
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            if !status.is_success() {
                let b = resp.bytes().await.unwrap_or_default();
                check(status, &b, &[])?;
                return Err(DavError::Http(status.as_u16(), None));
            }
            return Ok((resp, status == StatusCode::PARTIAL_CONTENT));
        }
        Err(AuthError::SessionExpired.into())
    }

    pub async fn read_range(&self, id: &str, offset: u64, len: u64) -> Result<Vec<u8>> {
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = self.tokens.access_token(rejected.as_deref()).await?;
            let resp = self
                .http
                .get(self.id_url(id))
                .bearer_auth(&token)
                .header(header::RANGE, format!("bytes={}-{}", offset, offset + len.saturating_sub(1)))
                .send()
                .await?;
            let status = resp.status();
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            let b = resp.bytes().await?;
            check(status, &b, &[])?;
            if status == StatusCode::OK {
                // Server ignored Range: slice it ourselves.
                let s = (offset as usize).min(b.len());
                let e = (s + len as usize).min(b.len());
                return Ok(b[s..e].to_vec());
            }
            return Ok(b.to_vec());
        }
        Err(AuthError::SessionExpired.into())
    }

    /// PUTs a local file. Never call with `New` for a name that may exist (the server overwrites).
    pub async fn upload(&self, file: &Path, target: UploadTarget<'_>, mtime: Option<i64>, progress: Option<Arc<dyn Fn(u64, u64) + Send + Sync>>) -> Result<RemoteItem> {
        let (url, if_match) = match &target {
            UploadTarget::New { parent_id, name } => (self.child_url(parent_id, name), None),
            UploadTarget::Existing { id, if_match } => (self.id_url(id), if_match.map(|s| s.to_string())),
        };
        let size = tokio::fs::metadata(file).await?.len();
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = self.tokens.access_token(rejected.as_deref()).await?;
            let f = tokio::fs::File::open(file).await?;
            let p = progress.clone();
            let mut sent = 0u64;
            let stream = tokio_util::io::ReaderStream::with_capacity(f, 256 * 1024).map(move |chunk| {
                if let (Ok(c), Some(p)) = (&chunk, &p) {
                    sent += c.len() as u64;
                    p(sent, size);
                }
                chunk
            });
            let mut req = self
                .http
                .put(&url)
                .bearer_auth(&token)
                .header(header::CONTENT_TYPE, "application/octet-stream")
                .header(header::CONTENT_LENGTH, size)
                .header("OC-Total-Length", size)
                .body(reqwest::Body::wrap_stream(stream));
            if let Some(m) = &if_match {
                req = req.header(header::IF_MATCH, format!("\"{m}\""));
            }
            if let Some(t) = mtime {
                req = req.header("X-OC-Mtime", t.to_string());
            }
            let resp = req.send().await?;
            let status = resp.status();
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            let fid = resp.headers().get("oc-fileid").and_then(|v| v.to_str().ok()).map(String::from);
            let b = resp.bytes().await?;
            check(status, &b, &[])?;
            if let Some(fid) = fid.filter(|s| !s.is_empty()) {
                return self.item_by_id(&fid).await;
            }
            return match target {
                UploadTarget::New { parent_id, name } => self.stat(&self.child_url(parent_id, name)).await,
                UploadTarget::Existing { id, .. } => self.item_by_id(id).await,
            };
        }
        Err(AuthError::SessionExpired.into())
    }

    // ---------- mutations ----------

    pub async fn create_folder(&self, parent_id: &str, name: &str) -> Result<RemoteItem> {
        let url = self.child_url(parent_id, name);
        let (status, _, _) = self.send(Method::from_bytes(b"MKCOL").unwrap(), &url, &[], None, &[405]).await?;
        if status.as_u16() == 405 {
            return Err(DavError::AlreadyExists);
        }
        self.stat(&url).await
    }

    pub async fn move_item(&self, id: &str, to_parent: &str, name: &str, overwrite: bool) -> Result<RemoteItem> {
        let dest = self.child_url(to_parent, name);
        let (status, _, _) = self
            .send(Method::from_bytes(b"MOVE").unwrap(), &self.id_url(id), &[("Destination", dest), ("Overwrite", if overwrite { "T" } else { "F" }.into())], None, &[412])
            .await?;
        if status.as_u16() == 412 {
            return Err(DavError::AlreadyExists);
        }
        self.item_by_id(id).await
    }

    pub async fn copy_item(&self, id: &str, to_parent: &str, name: &str) -> Result<RemoteItem> {
        let dest = self.child_url(to_parent, name);
        let (status, _, _) = self
            .send(Method::from_bytes(b"COPY").unwrap(), &self.id_url(id), &[("Destination", dest.clone()), ("Overwrite", "F".into())], None, &[412])
            .await?;
        if status.as_u16() == 412 {
            return Err(DavError::AlreadyExists);
        }
        self.stat(&dest).await
    }

    /// Moves to the server trash bin.
    pub async fn delete(&self, id: &str) -> Result<()> {
        match self.send(Method::DELETE, &self.id_url(id), &[], None, &[]).await {
            Ok(_) | Err(DavError::NotFound) => Ok(()),
            Err(e) => Err(e),
        }
    }

    pub async fn available_name(&self, parent_id: &str, desired: &str) -> Result<String> {
        if self.child(parent_id, desired).await?.is_none() {
            return Ok(desired.to_string());
        }
        let (base, ext) = split_ext(desired);
        for i in 1..1000 {
            let c = if ext.is_empty() { format!("{base} ({i})") } else { format!("{base} ({i}).{ext}") };
            if self.child(parent_id, &c).await?.is_none() {
                return Ok(c);
            }
        }
        Ok(format!("{base} ({})", std::process::id()))
    }

    // ---------- trash ----------

    pub async fn list_trash(&self) -> Result<Vec<RemoteItem>> {
        let (_, _, body) = self
            .send(Method::from_bytes(b"PROPFIND").unwrap(), &self.trash_url(), &[("Depth", "1".into()), ("Content-Type", "application/xml".into())], Some(TRASH_PROPFIND.into()), &[])
            .await?;
        Ok(parse_multistatus(&body.0)
            .into_iter()
            .skip(1)
            .filter_map(|r| {
                let key = percent_decode_str(r.href.trim_end_matches('/')).decode_utf8_lossy().rsplit('/').next()?.to_string();
                if key.is_empty() {
                    return None;
                }
                let p = &r.props;
                let num = |k: &str| p.get(k).and_then(|s| s.parse::<u64>().ok());
                let deleted = parse_date(p.get("trashbin-delete-datetime"));
                Some(RemoteItem {
                    id: format!("{}!{key}", self.account.space_id),
                    parent_id: None,
                    name: p.get("trashbin-original-filename").cloned().unwrap_or_else(|| key.clone()),
                    path: None,
                    is_folder: r.is_collection,
                    size: num("getcontentlength").or(num("size")).unwrap_or(0),
                    modified: deleted,
                    etag: String::new(),
                    content_type: p.get("getcontenttype").cloned(),
                    permissions: String::new(),
                    tags: vec![],
                    private_link: None,
                    has_preview: false,
                    trash_key: Some(key),
                    original_location: p.get("trashbin-original-location").cloned(),
                    deleted_at: deleted,
                })
            })
            .collect())
    }

    pub async fn restore(&self, trash_key: &str, original_location: &str) -> Result<()> {
        let src = format!("{}/{}", self.trash_url(), utf8_percent_encode(trash_key, NAME));
        let mut location = original_location.trim_matches('/').to_string();
        for attempt in 1..=20 {
            let (status, _, _) = self
                .send(Method::from_bytes(b"MOVE").unwrap(), &src, &[("Destination", self.space_path_url(&location)), ("Overwrite", "F".into())], None, &[409, 412])
                .await?;
            match status.as_u16() {
                409 => location = original_location.rsplit('/').next().unwrap_or(original_location).to_string(), // parent gone: restore to root
                412 => {
                    let (dir, file) = match location.rfind('/') {
                        Some(i) => (location[..i].to_string(), location[i + 1..].to_string()),
                        None => (String::new(), location.clone()),
                    };
                    let orig_file = original_location.rsplit('/').next().unwrap_or(&file).to_string();
                    let (base, ext) = split_ext(&orig_file);
                    let n = if ext.is_empty() { format!("{base} (restored {attempt})") } else { format!("{base} (restored {attempt}).{ext}") };
                    location = if dir.is_empty() { n } else { format!("{dir}/{n}") };
                }
                _ => return Ok(()),
            }
        }
        Err(DavError::AlreadyExists)
    }

    pub async fn purge(&self, trash_key: &str) -> Result<()> {
        let url = format!("{}/{}", self.trash_url(), utf8_percent_encode(trash_key, NAME));
        self.send(Method::DELETE, &url, &[], None, &[404]).await.map(|_| ())
    }

    pub async fn empty_trash(&self) -> Result<()> {
        self.send(Method::DELETE, &self.trash_url(), &[], None, &[]).await.map(|_| ())
    }

    // ---------- graph ----------

    pub async fn set_favorite(&self, id: &str, on: bool) -> Result<()> {
        let body = serde_json::json!({ "resourceId": id, "tags": [crate::FAVORITE_TAG] }).to_string();
        self.send(if on { Method::PUT } else { Method::DELETE }, &self.graph_url("extensions/org.libregraph/tags"), &[("Content-Type", "application/json".into())], Some(body), &[])
            .await
            .map(|_| ())
    }

    pub async fn quota(&self) -> Result<Quota> {
        let (_, _, b) = self.send(Method::GET, &self.graph_url(&format!("drives/{}", self.account.space_id)), &[], None, &[]).await?;
        let v: serde_json::Value = serde_json::from_slice(&b.0).unwrap_or_default();
        let used = v["quota"]["used"].as_u64().unwrap_or(0);
        let total = v["quota"]["total"].as_u64().filter(|t| *t > 0);
        Ok(Quota { used, total })
    }

    /// Server thumbnail (only if the server's preview service is enabled).
    pub async fn thumbnail(&self, id: &str, size: u32) -> Option<Vec<u8>> {
        let url = format!("{}?preview=1&x={size}&y={size}&a=1", self.id_url(id));
        let (s, _, b) = self.send(Method::GET, &url, &[], None, &[]).await.ok()?;
        (s == StatusCode::OK).then_some(b.0)
    }
}

mod bytes_body {
    pub struct Body(pub Vec<u8>);
}

fn check(status: StatusCode, body: &[u8], ok_extra: &[u16]) -> Result<()> {
    let code = status.as_u16();
    if status.is_success() || ok_extra.contains(&code) {
        return Ok(());
    }
    Err(match code {
        401 => AuthError::SessionExpired.into(),
        404 => DavError::NotFound,
        412 => DavError::PreconditionFailed,
        507 => DavError::InsufficientStorage,
        _ => {
            let s = String::from_utf8_lossy(body);
            let msg = s.split("<s:message>").nth(1).and_then(|r| r.split("</s:message>").next()).map(String::from);
            DavError::Http(code, msg)
        }
    })
}

fn parse_date(s: Option<&String>) -> Option<i64> {
    let s = s?.trim();
    if s.is_empty() {
        return None;
    }
    // "Mon, 09 Nov 2026 01:29:20 GMT" or "... +0000"
    let normalized = s.replace(" +0000", " GMT");
    httpdate::parse_http_date(&normalized)
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
}

pub fn split_ext(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i + 1..].to_string()),
        _ => (name.to_string(), String::new()),
    }
}
