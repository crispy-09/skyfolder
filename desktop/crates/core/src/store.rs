//! Small persisted sets: items pinned for offline use, and local cache bookkeeping.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinInfo {
    pub name: String,
    pub is_folder: bool,
    pub path: Option<String>,
}

const PINNED: &str = "pinned.json";

pub struct PinnedStore;

impl PinnedStore {
    pub fn all() -> HashMap<String, PinInfo> {
        crate::paths::read_json(PINNED).unwrap_or_default()
    }

    pub fn set(id: &str, pinned: bool, info: Option<PinInfo>) {
        let mut all = Self::all();
        match (pinned, info) {
            (true, Some(i)) => {
                all.insert(id.to_string(), i);
            }
            _ => {
                all.remove(id);
            }
        }
        let _ = crate::paths::write_json(PINNED, &all);
    }

    pub fn clear() {
        crate::paths::remove(PINNED);
    }

    /// True if `path` is pinned directly or lies inside a pinned folder.
    pub fn covers(all: &HashMap<String, PinInfo>, id: &str, path: Option<&str>) -> bool {
        if all.contains_key(id) {
            return true;
        }
        let Some(p) = path else { return false };
        all.values().any(|i| i.is_folder && i.path.as_deref().map(|fp| fp.is_empty() || p.starts_with(&format!("{fp}/"))).unwrap_or(false))
    }
}
