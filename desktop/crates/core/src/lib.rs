//! Shared core for Skyfolder on Windows and Linux: OpenCloud sign-in, tokens, the WebDAV/Graph client,
//! and small persisted stores. Mirrors the Swift `Shared/` module of the macOS app.

pub mod account;
pub mod auth;
pub mod dav;
pub mod model;
pub mod paths;
pub mod store;
mod xml;

pub use account::Account;
pub use auth::{AuthError, TokenProvider, Tokens};
pub use dav::{DavClient, DavError, Quota, UploadTarget};
pub use model::RemoteItem;

/// OIDC client registered in OpenCloud's built-in IdP for desktop clients (loopback redirect + PKCE).
pub const CLIENT_ID: &str = "OpenCloudDesktop";
pub const SCOPES: &str = "openid profile email offline_access";
/// "Starred" is stored as this server-side tag (the favorites capability is usually disabled).
pub const FAVORITE_TAG: &str = "favorite";

/// macOS/Windows/Linux metadata and lock files that are never uploaded.
pub fn is_excluded_name(name: &str) -> bool {
    matches!(name, ".DS_Store" | ".Trash" | ".localized" | "desktop.ini" | "Thumbs.db" | ".directory")
        || name.starts_with("._")
        || name.starts_with(".~lock.")
        || name.starts_with(".goutputstream-")
        || name.starts_with("~$")
        || name.ends_with(".swp")
        || name.ends_with('~') && name.len() > 1 && name.starts_with('.')
}

/// Makes a server-provided name safe as a single local path component on every platform.
pub fn safe_file_name(name: &str) -> String {
    let mut n: String = name
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            c if (c as u32) < 32 => '-',
            c => c,
        })
        .collect();
    n = n.trim().to_string();
    while n.starts_with('.') {
        n.remove(0);
    }
    while n.ends_with('.') || n.ends_with(' ') {
        n.pop();
    }
    if n.is_empty() {
        n = "download".into();
    }
    n.chars().take(200).collect()
}

/// "name (conflicted copy YYYY-MM-DD HH.MM.SS).ext" (UTC), used when a file changed both locally and on the server.
pub fn conflict_name(name: &str) -> String {
    let (base, ext) = dav::split_ext(name);
    let stamp = chrono_stamp();
    if ext.is_empty() {
        format!("{base} (conflicted copy {stamp})")
    } else {
        format!("{base} (conflicted copy {stamp}).{ext}")
    }
}

fn chrono_stamp() -> String {
    // YYYY-MM-DD HH.MM.SS (UTC) without pulling in a date crate.
    let s = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let days = s.div_euclid(86_400);
    let secs = s.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02} {:02}.{:02}.{:02}", secs / 3600, (secs / 60) % 60, secs % 60)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflict_names() {
        let n = conflict_name("report.final.docx");
        assert!(n.starts_with("report.final (conflicted copy 20") && n.ends_with(").docx"), "{n}");
        assert!(conflict_name("Makefile").starts_with("Makefile (conflicted copy "));
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_766), (2026, 11, 9));
    }

    #[test]
    fn excluded() {
        assert!(is_excluded_name(".DS_Store"));
        assert!(is_excluded_name("._foo"));
        assert!(!is_excluded_name("notes.txt"));
    }
}
