use serde::{Deserialize, Serialize};

/// Signed-in account (non-secret). Tokens live in the OS keyring, see `auth`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub server_url: String, // no trailing slash
    pub username: String,
    pub display_name: String,
    pub user_id: String,
    pub space_id: String, // personal space, "storage$space"
    pub root_id: String,  // fileid of the space root, "storage$space!space"
    pub token_endpoint: String,
    pub authorization_endpoint: String,
}

const FILE: &str = "account.json";

impl Account {
    pub fn load() -> Option<Account> {
        crate::paths::read_json(FILE)
    }

    pub fn save(&self) -> std::io::Result<()> {
        crate::paths::write_json(FILE, self)
    }

    pub fn clear() {
        crate::paths::remove(FILE)
    }

    /// Link to an item in the OpenCloud web UI.
    pub fn web_url(&self, file_id: &str) -> String {
        format!("{}/f/{}", self.server_url, file_id)
    }

    /// "storage$space" -> "storage$space!space"
    pub fn default_root_id(space_id: &str) -> String {
        let opaque = space_id.rsplit('$').next().unwrap_or(space_id);
        format!("{space_id}!{opaque}")
    }
}
