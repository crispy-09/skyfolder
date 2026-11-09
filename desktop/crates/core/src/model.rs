use serde::{Deserialize, Serialize};
use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteItem {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    /// Path relative to the space root, no leading slash ("" = root). None when addressed by id.
    pub path: Option<String>,
    pub is_folder: bool,
    pub size: u64,
    /// Unix seconds.
    pub modified: Option<i64>,
    pub etag: String,
    pub content_type: Option<String>,
    pub permissions: String,
    pub tags: Vec<String>,
    pub private_link: Option<String>,
    pub has_preview: bool,
    // Trash-only
    pub trash_key: Option<String>,
    pub original_location: Option<String>,
    pub deleted_at: Option<i64>,
}

impl RemoteItem {
    pub fn is_favorite(&self) -> bool {
        self.tags.iter().any(|t| t == crate::FAVORITE_TAG)
    }

    /// Opaque node id (after "!"); also the trash-bin key once deleted.
    pub fn opaque_id(&self) -> &str {
        self.id.rsplit('!').next().unwrap_or(&self.id)
    }

    pub fn modified_time(&self) -> SystemTime {
        match self.modified {
            Some(s) if s >= 0 => SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(s as u64),
            _ => SystemTime::UNIX_EPOCH,
        }
    }

    fn perm(&self, c: char) -> bool {
        self.permissions.is_empty() || self.permissions.contains(c)
    }
    pub fn can_write(&self) -> bool { self.perm('W') }
    pub fn can_delete(&self) -> bool { self.perm('D') }
    pub fn can_rename(&self) -> bool { self.perm('N') }
    pub fn can_move(&self) -> bool { self.perm('V') }
    pub fn can_add_children(&self) -> bool {
        self.permissions.is_empty() || self.permissions.contains('C') || self.permissions.contains('K')
    }

    pub fn parent_path(&self) -> Option<String> {
        let p = self.path.as_ref()?;
        Some(match p.rfind('/') {
            Some(i) => p[..i].to_string(),
            None => String::new(),
        })
    }
}
