//! Platform file-manager integration behind one small interface.
//! Linux: FUSE mount at ~/Skyfolder. Windows: Cloud Files sync root at %USERPROFILE%\Skyfolder.
//! Other platforms (e.g. running the UI on macOS during development): unavailable.

use skyfolder_core::{DavClient, RemoteItem};
use std::sync::Arc;

pub struct Sync {
    #[cfg(target_os = "linux")]
    mount: skyfolder_fuse::MountHandle,
    #[cfg(windows)]
    root: skyfolder_winsync::SyncRoot,
}

impl Sync {
    #[allow(unused_variables)]
    pub async fn start(client: Arc<DavClient>) -> anyhow::Result<Sync> {
        let dir = skyfolder_core::paths::drive_root();
        #[cfg(target_os = "linux")]
        {
            let mount = skyfolder_fuse::mount(client, &dir)?;
            return Ok(Sync { mount });
        }
        #[cfg(windows)]
        {
            let root = skyfolder_winsync::SyncRoot::start(client, &dir).await?;
            return Ok(Sync { root });
        }
        #[allow(unreachable_code)]
        Err(anyhow::anyhow!("File manager integration is only available on Windows and Linux."))
    }

    pub fn cached_ids(&self) -> Vec<String> {
        #[cfg(target_os = "linux")]
        return self.mount.engine.cached_ids();
        #[cfg(windows)]
        return self.root.cached_ids();
        #[allow(unreachable_code)]
        Vec::new()
    }

    #[allow(unused_variables)]
    pub async fn set_offline(&self, items: &[RemoteItem], on: bool) {
        #[cfg(target_os = "linux")]
        self.mount.engine.set_offline(items, on).await;
        #[cfg(windows)]
        self.root.set_offline(items, on).await;
    }

    /// Stops the integration. `forget` also removes local state (sign-out).
    #[allow(unused_variables)]
    pub async fn shutdown(self, forget: bool) {
        #[cfg(target_os = "linux")]
        {
            if forget {
                self.mount.engine.clear_cache();
            }
            drop(self.mount);
        }
        #[cfg(windows)]
        self.root.shutdown(forget).await;
    }
}
