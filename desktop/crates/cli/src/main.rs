//! skyfolder-cli: headless tool for testing and power users.
//!
//!   skyfolder-cli login <server>     browser sign-in, stores the account + tokens
//!   skyfolder-cli selftest           exercises the API in a temporary folder (cleans up after)
//!   skyfolder-cli mount [dir]        (Linux) mounts the drive with FUSE until Ctrl-C
//!
//! For automated tests, set SKYFOLDER_TOKEN and SKYFOLDER_SERVER to use a fixed access token.

use anyhow::{bail, Context, Result};
use skyfolder_core::{auth, Account, DavClient, DavError, TokenProvider, UploadTarget};
use std::sync::Arc;

async fn client() -> Result<DavClient> {
    if let (Ok(token), Ok(server)) = (std::env::var("SKYFOLDER_TOKEN"), std::env::var("SKYFOLDER_SERVER")) {
        let server = auth::normalize_server(&server)?;
        let mut acc = auth::build_account_with_token(&server, &token).await?;
        // Confirm root id via WebDAV.
        let tmp = DavClient::new(acc.clone(), TokenProvider::with_static(&acc, token.clone()));
        if let Ok(root) = tmp.item_by_path("").await {
            acc.root_id = root.id;
        }
        return Ok(DavClient::new(acc.clone(), TokenProvider::with_static(&acc, token)));
    }
    let acc = Account::load().context("not signed in: run `skyfolder-cli login <server>`")?;
    let tokens = TokenProvider::new(&acc);
    Ok(DavClient::new(acc, tokens))
}

fn check(name: &str, ok: bool, extra: impl std::fmt::Display) -> bool {
    println!("{} {name} {extra}", if ok { "PASS" } else { "FAIL" });
    ok
}

async fn selftest() -> Result<()> {
    let c = client().await?;
    let root_id = c.account.root_id.clone();
    let mut fails = 0;
    let mut t = |name: &str, ok: bool, extra: String| {
        if !check(name, ok, extra) {
            fails += 1;
        }
    };

    let (folder, children) = c.list_path("").await?;
    t("list root", folder.as_ref().map(|f| f.id == root_id).unwrap_or(false), format!("children={}", children.len()));
    t("child paths", children.iter().all(|c| c.path.as_deref().map(|p| !p.contains('/')).unwrap_or(false)), String::new());
    let (_, by_id) = c.list_id(&root_id).await?;
    t("list root by id", by_id.len() == children.len(), String::new());

    let fname = "_skyfolder selftest ü";
    if let Some(old) = c.child(&root_id, fname).await? {
        c.delete(&old.id).await?;
    }
    let f = c.create_folder(&root_id, fname).await?;
    t("mkcol", f.is_folder, String::new());
    t("mkcol dup", matches!(c.create_folder(&root_id, fname).await, Err(DavError::AlreadyExists)), String::new());

    let dir = std::env::temp_dir().join(format!("skyfolder-selftest-{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let local = dir.join("h.txt");
    std::fs::write(&local, "hello world")?;
    let up = c.upload(&local, UploadTarget::New { parent_id: &f.id, name: "a b&c.txt" }, Some(1_700_000_000), None).await?;
    t("upload", up.size == 11 && up.name == "a b&c.txt", format!("mtime={:?}", up.modified));
    let n2 = c.available_name(&f.id, "a b&c.txt").await?;
    t("available name", n2 == "a b&c (1).txt", n2);
    std::fs::write(&local, "changed!")?;
    t(
        "if-match conflict",
        matches!(c.upload(&local, UploadTarget::Existing { id: &up.id, if_match: Some("bogus") }, None, None).await, Err(DavError::PreconditionFailed)),
        String::new(),
    );
    let up2 = c.upload(&local, UploadTarget::Existing { id: &up.id, if_match: Some(&up.etag) }, None, None).await?;
    t("overwrite with etag", up2.size == 8 && up2.id == up.id, String::new());
    let dl = dir.join("dl.txt");
    c.download(&up.id, &dl, None).await?;
    t("download", std::fs::read_to_string(&dl)? == "changed!", String::new());
    let part = c.read_range(&up.id, 2, 3).await?;
    t("range read", part == b"ang", String::from_utf8_lossy(&part).to_string());
    let mv = c.move_item(&up.id, &f.id, "renamed.txt", false).await?;
    t("rename", mv.name == "renamed.txt" && mv.id == up.id, String::new());
    let cp = c.copy_item(&up.id, &f.id, "copy.txt").await?;
    t("copy", cp.name == "copy.txt" && cp.id != up.id, String::new());
    let sub = c.create_folder(&f.id, "sub").await?;
    c.move_item(&cp.id, &sub.id, "copy.txt", false).await?;
    let (_, subl) = c.list_path(&format!("{fname}/sub")).await?;
    t("move into sub", subl.iter().map(|i| i.name.as_str()).collect::<Vec<_>>() == ["copy.txt"], subl.first().and_then(|i| i.path.clone()).unwrap_or_default());
    c.set_favorite(&mv.id, true).await?;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let st = c.item_by_id(&mv.id).await?;
    t("star tag", st.is_favorite(), st.tags.join(","));
    let favs = c.search("tag:favorite", 200).await?;
    t("search starred", favs.iter().any(|i| i.id == mv.id), format!("path={:?}", favs.iter().find(|i| i.id == mv.id).and_then(|i| i.path.clone())));
    let s = c.search("name:\"*renamed*\"", 200).await?;
    t("search name", s.iter().any(|i| i.id == mv.id), String::new());
    let recent = c.search("mtime:\"last 30 days\"", 50).await?;
    t("recent", !recent.is_empty(), format!("n={}", recent.len()));
    c.set_favorite(&mv.id, false).await?;
    let q = c.quota().await?;
    t("quota", q.used > 0, format!("used={} total={:?}", q.used, q.total));
    c.delete(&mv.id).await?;
    let trash = c.list_trash().await?;
    let ti = trash.iter().find(|i| i.trash_key.as_deref() == Some(mv.opaque_id()));
    t("trash list", ti.is_some(), format!("loc={:?}", ti.and_then(|i| i.original_location.clone())));
    if let Some(ti) = ti {
        c.restore(ti.trash_key.as_ref().unwrap(), ti.original_location.as_ref().unwrap()).await?;
    }
    t("restore", c.child(&f.id, "renamed.txt").await?.map(|i| i.id == mv.id).unwrap_or(false), String::new());

    // Clean up: delete and purge the test folder.
    c.delete(&f.id).await?;
    let trash = c.list_trash().await?;
    let purged = if let Some(ti) = trash.iter().find(|i| i.trash_key.as_deref() == Some(f.opaque_id())) {
        c.purge(ti.trash_key.as_ref().unwrap()).await.is_ok()
    } else {
        false
    };
    t("purge", purged, String::new());
    let _ = std::fs::remove_dir_all(&dir);
    if fails > 0 {
        bail!("{fails} check(s) failed");
    }
    println!("all checks passed");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into())).with_writer(std::io::stderr).init();
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("login") => {
            let server = args.get(2).context("usage: skyfolder-cli login <server>")?;
            let (acc, tokens) = auth::sign_in(server, |url| {
                println!("Open this URL in your browser to sign in:\n\n  {url}\n");
            })
            .await?;
            acc.save()?;
            auth::store::save(&tokens);
            println!("Signed in as {} ({})", acc.display_name, acc.username);
        }
        Some("selftest") => selftest().await?,
        Some("ls") => {
            // Server-side listing (bypasses any mount): name<TAB>size<TAB>etag
            let c = client().await?;
            let (_, kids) = c.list_path(args.get(2).map(String::as_str).unwrap_or("")).await?;
            for k in kids {
                println!("{}{}\t{}\t{}", k.name, if k.is_folder { "/" } else { "" }, k.size, k.etag);
            }
        }
        Some("cat") => {
            let c = client().await?;
            let item = c.item_by_path(args.get(2).context("usage: cat <path>")?).await?;
            let tmp = std::env::temp_dir().join(format!("skyfolder-cat-{}", std::process::id()));
            c.download(&item.id, &tmp, None).await?;
            print!("{}", std::fs::read_to_string(&tmp)?);
            let _ = std::fs::remove_file(tmp);
        }
        Some("rmtree") => {
            // Delete a path and purge it from the trash (test cleanup).
            let c = client().await?;
            let item = c.item_by_path(args.get(2).context("usage: rmtree <path>")?).await?;
            c.delete(&item.id).await?;
            if let Some(t) = c.list_trash().await?.into_iter().find(|t| t.trash_key.as_deref() == Some(item.opaque_id())) {
                c.purge(t.trash_key.as_deref().unwrap()).await?;
            }
            println!("removed {}", item.name);
        }
        #[cfg(target_os = "linux")]
        Some("mount") => {
            let c = client().await?;
            let dir = args.get(2).map(std::path::PathBuf::from).unwrap_or_else(skyfolder_core::paths::drive_root);
            let handle = skyfolder_fuse::mount(Arc::new(c), &dir)?;
            println!("Mounted at {} — press Ctrl-C to unmount", dir.display());
            tokio::signal::ctrl_c().await?;
            drop(handle);
        }
        _ => {
            let _ = Arc::new(());
            eprintln!("usage: skyfolder-cli <login <server> | selftest | mount [dir]>");
            std::process::exit(2);
        }
    }
    Ok(())
}
