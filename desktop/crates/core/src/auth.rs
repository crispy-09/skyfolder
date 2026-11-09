//! OIDC (authorization code + PKCE, loopback redirect) and token storage/refresh.

use crate::account::Account;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("You're not signed in.")]
    NotSignedIn,
    #[error("Your session expired. Please sign in again.")]
    SessionExpired,
    #[error("{0}")]
    Server(String),
    #[error("Sign-in was cancelled.")]
    Cancelled,
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: u64,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl Tokens {
    pub fn is_fresh(&self) -> bool {
        self.expires_at > now() + 30
    }
}

/// Persists tokens in the OS credential store (Windows Credential Manager / Secret Service),
/// falling back to an owner-only file when no keyring is available (e.g. headless Linux).
pub mod store {
    use super::Tokens;
    const SERVICE: &str = "io.github.crispy-09.skyfolder";
    const USER: &str = "tokens";
    const FALLBACK: &str = ".tokens.json";

    fn entry() -> Option<keyring::Entry> {
        keyring::Entry::new(SERVICE, USER).ok()
    }

    pub fn load() -> Option<Tokens> {
        if let Some(e) = entry() {
            if let Ok(s) = e.get_password() {
                if let Ok(t) = serde_json::from_str(&s) {
                    return Some(t);
                }
            }
        }
        crate::paths::read_json(FALLBACK)
    }

    pub fn save(t: &Tokens) {
        let json = serde_json::to_string(t).unwrap_or_default();
        if let Some(e) = entry() {
            if e.set_password(&json).is_ok() {
                crate::paths::remove(FALLBACK);
                return;
            }
        }
        tracing::warn!("OS keyring unavailable; storing tokens in an owner-only file");
        let _ = crate::paths::write_json(FALLBACK, t);
    }

    pub fn clear() {
        if let Some(e) = entry() {
            let _ = e.delete_credential();
        }
        crate::paths::remove(FALLBACK);
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
}

#[derive(Deserialize)]
struct ErrorResponse {
    error: String,
    error_description: Option<String>,
}

/// Hands out valid access tokens, refreshing (single-flight) when needed.
pub struct TokenProvider {
    token_endpoint: String,
    http: reqwest::Client,
    state: Mutex<Option<Tokens>>,
}

impl TokenProvider {
    pub fn new(account: &Account) -> Arc<Self> {
        Arc::new(Self {
            token_endpoint: account.token_endpoint.clone(),
            http: reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap(),
            state: Mutex::new(store::load()),
        })
    }

    /// For tests/CLI: use a fixed token that is never persisted.
    pub fn with_static(account: &Account, access_token: String) -> Arc<Self> {
        Arc::new(Self {
            token_endpoint: account.token_endpoint.clone(),
            http: reqwest::Client::new(),
            state: Mutex::new(Some(Tokens { access_token, refresh_token: None, expires_at: now() + 3600 })),
        })
    }

    pub async fn set(&self, t: Tokens) {
        store::save(&t);
        *self.state.lock().await = Some(t);
    }

    /// `rejected`: an access token the server just refused with 401.
    pub async fn access_token(&self, rejected: Option<&str>) -> Result<String, AuthError> {
        let mut guard = self.state.lock().await; // holding the lock makes refresh single-flight
        let current = guard.clone().or_else(store::load).ok_or(AuthError::NotSignedIn)?;
        if current.is_fresh() && Some(current.access_token.as_str()) != rejected {
            *guard = Some(current.clone());
            return Ok(current.access_token);
        }
        let refresh = current.refresh_token.clone().ok_or(AuthError::SessionExpired)?;
        let new = refresh_tokens(&self.http, &self.token_endpoint, &refresh).await?;
        store::save(&new);
        *guard = Some(new.clone());
        Ok(new.access_token)
    }
}

async fn token_request(http: &reqwest::Client, endpoint: &str, form: &[(&str, &str)], prev_refresh: Option<&str>) -> Result<Tokens, AuthError> {
    let resp = http.post(endpoint).form(form).send().await?;
    let status = resp.status();
    let body = resp.bytes().await?;
    if !status.is_success() {
        if let Ok(e) = serde_json::from_slice::<ErrorResponse>(&body) {
            if e.error == "invalid_grant" {
                return Err(AuthError::SessionExpired);
            }
            return Err(AuthError::Server(e.error_description.unwrap_or(e.error)));
        }
        return Err(AuthError::Server(format!("Sign-in failed (HTTP {status}).")));
    }
    let r: TokenResponse = serde_json::from_slice(&body).map_err(|e| AuthError::Server(e.to_string()))?;
    Ok(Tokens {
        access_token: r.access_token,
        refresh_token: r.refresh_token.or(prev_refresh.map(String::from)),
        expires_at: now() + r.expires_in.unwrap_or(300),
    })
}

async fn refresh_tokens(http: &reqwest::Client, endpoint: &str, refresh: &str) -> Result<Tokens, AuthError> {
    token_request(
        http,
        endpoint,
        &[("grant_type", "refresh_token"), ("client_id", crate::CLIENT_ID), ("refresh_token", refresh)],
        Some(refresh),
    )
    .await
}

#[derive(Deserialize)]
struct Discovery {
    authorization_endpoint: String,
    token_endpoint: String,
}

fn random_url_safe(n: usize) -> String {
    let mut b = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut b);
    URL_SAFE_NO_PAD.encode(b)
}

/// Normalizes user input like "cloud.example.com" into "https://cloud.example.com" and refuses plain HTTP
/// (except to this machine).
pub fn normalize_server(input: &str) -> Result<String, AuthError> {
    let mut s = input.trim().to_string();
    if !s.to_lowercase().starts_with("http") {
        s = format!("https://{s}");
    }
    while s.ends_with('/') {
        s.pop();
    }
    let u = url::Url::parse(&s).map_err(|_| AuthError::Server("Enter a valid server address, like cloud.example.com.".into()))?;
    let host = u.host_str().ok_or_else(|| AuthError::Server("Enter a valid server address.".into()))?.to_string();
    if u.scheme() != "https" && !matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]") {
        return Err(AuthError::Server(format!("The server must use HTTPS (https://{host}).")));
    }
    Ok(s)
}

const DONE_PAGE: &str = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Skyfolder</title><style>body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f8fafd;color:#1f1f1f}div{text-align:center}h1{font-weight:500;font-size:22px}p{color:#444746}</style></head><body><div><h1>You're signed in</h1><p>You can close this tab and return to Skyfolder.</p></div></body></html>";

/// Full browser sign-in. `open_browser` is called with the authorization URL.
/// Resolves once the browser redirects back to the loopback listener.
pub async fn sign_in(server_input: &str, open_browser: impl FnOnce(&str)) -> Result<(Account, Tokens), AuthError> {
    let server = normalize_server(server_input)?;
    let http = reqwest::Client::builder().timeout(Duration::from_secs(30)).build()?;
    let disc: Discovery = http
        .get(format!("{server}/.well-known/openid-configuration"))
        .send()
        .await?
        .error_for_status()
        .map_err(|_| AuthError::Server("This doesn't look like an OpenCloud server (no OpenID configuration found).".into()))?
        .json()
        .await?;

    let verifier = random_url_safe(64);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = random_url_safe(24);

    let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|e| AuthError::Server(e.to_string()))?;
    let port = listener.local_addr().map_err(|e| AuthError::Server(e.to_string()))?.port();
    let redirect = format!("http://127.0.0.1:{port}");

    let mut auth_url = url::Url::parse(&disc.authorization_endpoint).map_err(|e| AuthError::Server(e.to_string()))?;
    auth_url
        .query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", crate::CLIENT_ID)
        .append_pair("redirect_uri", &redirect)
        .append_pair("scope", crate::SCOPES)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", &state);
    open_browser(auth_url.as_str());

    // Wait (up to 10 minutes) for the redirect carrying ?code=...&state=...
    let params = tokio::time::timeout(Duration::from_secs(600), async {
        loop {
            let (mut sock, _) = listener.accept().await.map_err(|e| AuthError::Server(e.to_string()))?;
            let mut buf = vec![0u8; 16 * 1024];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]);
            let target = req.split_whitespace().nth(1).unwrap_or("/").to_string();
            let u = url::Url::parse(&format!("http://127.0.0.1{target}")).ok();
            let q: Vec<(String, String)> = u.map(|u| u.query_pairs().into_owned().collect()).unwrap_or_default();
            let is_cb = q.iter().any(|(k, _)| k == "code" || k == "error");
            let (status, body) = if is_cb { ("200 OK", DONE_PAGE) } else { ("404 Not Found", "Not found") };
            let resp = format!("HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            let _ = sock.write_all(resp.as_bytes()).await;
            if is_cb {
                return Ok::<_, AuthError>(q);
            }
        }
    })
    .await
    .map_err(|_| AuthError::Cancelled)??;

    let get = |k: &str| params.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
    if let Some(err) = get("error") {
        return Err(AuthError::Server(get("error_description").unwrap_or(err)));
    }
    if get("state").as_deref() != Some(state.as_str()) {
        return Err(AuthError::Server("Sign-in was interrupted. Please try again.".into()));
    }
    let code = get("code").ok_or_else(|| AuthError::Server("No authorization code received.".into()))?;
    let tokens = token_request(
        &http,
        &disc.token_endpoint,
        &[
            ("grant_type", "authorization_code"),
            ("client_id", crate::CLIENT_ID),
            ("code", &code),
            ("code_verifier", &verifier),
            ("redirect_uri", &redirect),
        ],
        None,
    )
    .await?;

    let account = build_account(&http, &server, &disc, &tokens.access_token).await?;
    Ok((account, tokens))
}

/// Builds the Account from Graph (/me, /me/drives) using an access token.
pub async fn build_account_with_token(server: &str, access_token: &str) -> Result<Account, AuthError> {
    let http = reqwest::Client::new();
    let disc: Discovery = http.get(format!("{server}/.well-known/openid-configuration")).send().await?.json().await?;
    build_account(&http, server, &disc, access_token).await
}

async fn build_account(http: &reqwest::Client, server: &str, disc: &Discovery, token: &str) -> Result<Account, AuthError> {
    let get = |p: &str| http.get(format!("{server}{p}")).bearer_auth(token).send();
    let me: serde_json::Value = get("/graph/v1.0/me").await?.error_for_status()?.json().await?;
    let drives: serde_json::Value = get("/graph/v1.0/me/drives").await?.error_for_status()?.json().await?;
    let personal = drives["value"]
        .as_array()
        .and_then(|a| a.iter().find(|d| d["driveType"] == "personal"))
        .ok_or_else(|| AuthError::Server("Your account has no personal space on this server.".into()))?;
    let space_id = personal["id"].as_str().unwrap_or_default().to_string();
    let root_id = personal["root"]["id"].as_str().map(String::from).unwrap_or_else(|| Account::default_root_id(&space_id));
    let s = |v: &serde_json::Value| v.as_str().unwrap_or_default().to_string();
    Ok(Account {
        server_url: server.to_string(),
        username: me["onPremisesSamAccountName"].as_str().or(me["mail"].as_str()).unwrap_or_default().to_string(),
        display_name: s(&me["displayName"]),
        user_id: s(&me["id"]),
        space_id,
        root_id,
        token_endpoint: disc.token_endpoint.clone(),
        authorization_endpoint: disc.authorization_endpoint.clone(),
    })
}
