import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// Thin wrappers over the Rust commands (see src-tauri/src/lib.rs).
export const api = {
  getSession: () => invoke("get_session"),
  signIn: (server) => invoke("sign_in", { server }),
  signOut: () => invoke("sign_out"),
  list: (path) => invoke("list", { path }),
  recent: () => invoke("recent"),
  starred: () => invoke("starred"),
  search: (query) => invoke("search", { query }),
  trash: () => invoke("trash"),
  offlineState: () => invoke("offline_state"),
  offlineItems: () => invoke("offline_items"),
  quota: () => invoke("quota"),
  createFolder: (parentId, name) => invoke("create_folder", { parentId, name }),
  rename: (id, parentId, name) => invoke("rename_item", { id, parentId, name }),
  moveItems: (items, destId) => invoke("move_items", { items, destId }),
  copyItem: (item) => invoke("copy_item", { item }),
  trashItems: (items) => invoke("trash_items", { items }),
  restoreItems: (items) => invoke("restore_items", { items }),
  deleteForever: (keys) => invoke("delete_forever", { keys }),
  emptyTrash: () => invoke("empty_trash"),
  setStarred: (ids, on) => invoke("set_starred", { ids, on }),
  setOffline: (items, on) => invoke("set_offline", { items, on }),
  openItem: (item) => invoke("open_item", { item }),
  revealItem: (item) => invoke("reveal_item", { item }),
  openDriveFolder: () => invoke("open_drive_folder"),
  openWeb: (id) => invoke("open_web", { id: id ?? null }),
  uploadPaths: (paths, parentId) => invoke("upload_paths", { paths, parentId }),
  downloadItems: (items) => invoke("download_items", { items }),
  revealPath: (path) => invoke("reveal_path", { path }),
  thumbnail: (item) => invoke("thumbnail", { item }),
};

export { listen };
