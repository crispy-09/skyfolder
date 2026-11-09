use directories::{ProjectDirs, UserDirs};
use std::path::PathBuf;

fn dirs() -> ProjectDirs {
    ProjectDirs::from("io.github", "crispy-09", "Skyfolder").expect("no home directory")
}

/// Per-user config dir (account.json, pinned.json, ...).
pub fn config_dir() -> PathBuf {
    let d = std::env::var_os("SKYFOLDER_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| dirs().config_dir().to_path_buf());
    let _ = std::fs::create_dir_all(&d);
    d
}

/// Cache dir (downloaded file contents, thumbnails).
pub fn cache_dir() -> PathBuf {
    let d = std::env::var_os("SKYFOLDER_CACHE_DIR").map(PathBuf::from).unwrap_or_else(|| dirs().cache_dir().to_path_buf());
    let _ = std::fs::create_dir_all(&d);
    d
}

/// Where the cloud folder appears: ~/Skyfolder (Linux mount point / Windows sync root).
pub fn drive_root() -> PathBuf {
    if let Some(p) = std::env::var_os("SKYFOLDER_ROOT") {
        return PathBuf::from(p);
    }
    UserDirs::new().map(|u| u.home_dir().join("Skyfolder")).unwrap_or_else(|| PathBuf::from("Skyfolder"))
}

pub fn downloads_dir() -> PathBuf {
    UserDirs::new()
        .and_then(|u| u.download_dir().map(|p| p.to_path_buf()))
        .or_else(|| UserDirs::new().map(|u| u.home_dir().join("Downloads")))
        .unwrap_or_else(std::env::temp_dir)
}

/// Writes JSON atomically (temp file + rename) with owner-only permissions on Unix.
pub fn write_json<T: serde::Serialize>(name: &str, value: &T) -> std::io::Result<()> {
    let path = config_dir().join(name);
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(value)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(tmp, path)
}

pub fn read_json<T: serde::de::DeserializeOwned>(name: &str) -> Option<T> {
    let data = std::fs::read(config_dir().join(name)).ok()?;
    serde_json::from_slice(&data).ok()
}

pub fn remove(name: &str) {
    let _ = std::fs::remove_file(config_dir().join(name));
}
