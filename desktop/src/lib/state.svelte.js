// App state and actions (port of the macOS DriveModel).
import { api, listen } from "./api.js";
import { kindOf } from "./kinds.js";

const TITLES = { myFiles: "My Files", recent: "Recent", starred: "Starred", offline: "Available offline", trash: "Trash", search: "Search results" };

class Drive {
  // session
  session = $state(null); // { account, syncRoot, syncError, platform }
  booting = $state(true);
  signingIn = $state(false);
  signInError = $state("");
  sessionExpired = $state(false);

  // navigation
  section = $state("myFiles");
  query = $state("");
  searchText = $state("");
  crumbs = $state([{ name: "My Files", path: "" }]);
  currentFolder = $state(null);
  items = $state([]);
  loading = $state(false);
  loadError = $state("");

  // presentation
  selection = $state(new Set());
  lastSelected = null;
  viewMode = $state(localStorage.getItem("viewMode") || "list");
  sortKey = $state("name");
  sortAsc = $state(true);
  typeFilter = $state(null);
  modifiedFilter = $state(null);
  showDetails = $state(false);
  dialog = $state(null); // { kind, item?, items?, value? }
  moveTargets = $state(null);
  menu = $state(null); // { x, y, item }
  showSettings = $state(false);

  // status
  quota = $state(null);
  toast = $state(null);
  transfers = $state([]);
  transfersCollapsed = $state(false);
  pinned = $state(new Set());
  pinnedFolders = $state([]);
  downloaded = $state(new Set());

  #gen = 0;
  #timer = null;

  get title() {
    return TITLES[this.section];
  }
  get currentPath() {
    return this.crumbs[this.crumbs.length - 1]?.path ?? "";
  }
  get rootId() {
    return this.session?.account.rootId;
  }

  get visibleItems() {
    let list = this.items;
    if (this.typeFilter) list = list.filter((i) => kindOf(i) === this.typeFilter);
    if (this.modifiedFilter) list = list.filter((i) => matchesModified(this.modifiedFilter, i.modified));
    if (this.section === "recent") return [...list].sort((a, b) => (b.modified ?? 0) - (a.modified ?? 0));
    if (this.section === "trash") return [...list].sort((a, b) => (b.deletedAt ?? 0) - (a.deletedAt ?? 0));
    const dir = this.sortAsc ? 1 : -1;
    return [...list].sort((a, b) => {
      if (a.isFolder !== b.isFolder) return a.isFolder ? -1 : 1;
      let r = 0;
      if (this.sortKey === "name") r = a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
      else if (this.sortKey === "modified") r = (a.modified ?? 0) - (b.modified ?? 0);
      else r = a.size - b.size;
      return r * dir;
    });
  }

  get selectedItems() {
    return this.items.filter((i) => this.selection.has(i.id));
  }

  // ---------- boot & session ----------

  async boot() {
    await listen("transfer", (e) => this.#onTransfer(e.payload));
    await listen("changed", () => this.reload(true));
    try {
      this.session = await api.getSession();
    } catch (e) {
      console.error(e);
    }
    this.booting = false;
    if (this.session) this.#activate();
  }

  async signIn(server) {
    this.signingIn = true;
    this.signInError = "";
    try {
      localStorage.setItem("lastServer", server);
      this.session = await api.signIn(server);
      this.#activate();
    } catch (e) {
      this.signInError = String(e);
    }
    this.signingIn = false;
  }

  async signOut() {
    clearInterval(this.#timer);
    await api.signOut();
    this.session = null;
    this.items = [];
    this.pinned = new Set();
    this.downloaded = new Set();
  }

  #activate() {
    this.sessionExpired = false;
    this.go("myFiles");
    this.refreshQuota();
    this.refreshOffline();
    clearInterval(this.#timer);
    let n = 0;
    this.#timer = setInterval(() => {
      if (this.sessionExpired || this.dialog) return;
      n++;
      this.reload(true);
      this.refreshOffline();
      if (n % 10 === 0) this.refreshQuota();
    }, 30_000);
  }

  #handle(e) {
    const msg = String(e);
    if (msg.startsWith("AUTH:")) {
      this.sessionExpired = true;
      return;
    }
    this.showToast(msg);
  }

  async refreshQuota() {
    try {
      this.quota = await api.quota();
    } catch {}
  }

  async refreshOffline() {
    try {
      const s = await api.offlineState();
      this.pinned = new Set(s.pinned);
      this.pinnedFolders = s.pinnedFolders;
      this.downloaded = new Set(s.downloaded);
    } catch {}
  }

  // ---------- navigation ----------

  go(section, query = "") {
    this.section = section;
    this.query = query;
    this.selection = new Set();
    this.typeFilter = null;
    this.modifiedFilter = null;
    if (section === "myFiles") this.crumbs = [{ name: "My Files", path: "" }];
    if (section !== "search") this.searchText = "";
    this.reload();
  }

  openFolder(path) {
    const crumbs = [{ name: "My Files", path: "" }];
    let acc = "";
    for (const part of path.split("/").filter(Boolean)) {
      acc = acc ? `${acc}/${part}` : part;
      crumbs.push({ name: part, path: acc });
    }
    this.section = "myFiles";
    this.crumbs = crumbs;
    this.selection = new Set();
    this.typeFilter = null;
    this.modifiedFilter = null;
    this.searchText = "";
    this.reload();
  }

  search() {
    const q = this.searchText.trim();
    if (!q) return;
    this.go("search", q);
    this.searchText = q;
  }

  async reload(silent = false) {
    if (!this.session) return;
    const gen = ++this.#gen;
    const section = this.section;
    const path = this.currentPath;
    if (!silent) {
      this.loading = true;
      this.loadError = "";
      this.items = [];
    }
    try {
      let result;
      switch (section) {
        case "myFiles": {
          const l = await api.list(path);
          if (gen === this.#gen) this.currentFolder = l.folder;
          result = l.items;
          break;
        }
        case "recent": result = await api.recent(); break;
        case "starred": result = await api.starred(); break;
        case "offline": result = await api.offlineItems(); break;
        case "trash": result = await api.trash(); break;
        case "search": result = await api.search(this.query); break;
      }
      if (gen !== this.#gen) return;
      if (JSON.stringify(result) !== JSON.stringify($state.snapshot(this.items))) this.items = result;
      this.selection = new Set([...this.selection].filter((id) => result.some((i) => i.id === id)));
      this.loadError = "";
    } catch (e) {
      if (gen !== this.#gen) return;
      const msg = String(e);
      if (msg.includes("no longer exists") && section === "myFiles" && this.crumbs.length > 1) {
        this.crumbs = this.crumbs.slice(0, -1);
        return this.reload();
      }
      if (!silent) this.loadError = msg.replace(/^AUTH:/, "");
      this.#handle(e);
    }
    if (gen === this.#gen) this.loading = false;
  }

  setSort(key) {
    if (this.sortKey === key) this.sortAsc = !this.sortAsc;
    else {
      this.sortKey = key;
      this.sortAsc = key === "name";
    }
  }

  setViewMode(m) {
    this.viewMode = m;
    localStorage.setItem("viewMode", m);
  }

  // ---------- selection ----------

  click(item, list, ev) {
    const sel = new Set(this.selection);
    if (ev.metaKey || ev.ctrlKey) {
      sel.has(item.id) ? sel.delete(item.id) : sel.add(item.id);
    } else if (ev.shiftKey && this.lastSelected) {
      const a = list.findIndex((i) => i.id === this.lastSelected);
      const b = list.findIndex((i) => i.id === item.id);
      if (a >= 0 && b >= 0) for (let i = Math.min(a, b); i <= Math.max(a, b); i++) sel.add(list[i].id);
    } else {
      sel.clear();
      sel.add(item.id);
    }
    this.selection = sel;
    this.lastSelected = item.id;
  }

  targets(item) {
    if (this.selection.has(item.id) && this.selection.size > 1) return this.selectedItems;
    return [item];
  }

  // ---------- offline ----------

  isPinned(item) {
    return this.pinned.has(item.id);
  }
  isOffline(item) {
    if (this.pinned.has(item.id) || this.downloaded.has(item.id)) return true;
    if (!item.path) return false;
    return this.pinnedFolders.some((fp) => fp === "" || item.path.startsWith(fp + "/"));
  }

  async setOffline(items, on) {
    try {
      await api.setOffline(items, on);
      const what = items.length === 1 ? `“${items[0].name}”` : `${items.length} items`;
      this.showToast(on ? `${what} will be available offline` : `${what} removed from this computer (still in the cloud)`);
      await this.refreshOffline();
      if (this.section === "offline") this.reload(true);
    } catch (e) {
      this.#handle(e);
    }
  }

  // ---------- open ----------

  async open(item) {
    if (this.section === "trash") return;
    if (item.isFolder) {
      if (item.path != null) this.openFolder(item.path);
      return;
    }
    try {
      await api.openItem(item);
    } catch (e) {
      this.#handle(e);
    }
  }

  async reveal(item) {
    try {
      await api.revealItem(item);
    } catch (e) {
      this.#handle(e);
    }
  }

  async copyLink(item) {
    const link = item.privateLink || `${this.session.account.serverUrl}/f/${item.id}`;
    try {
      await navigator.clipboard.writeText(link);
      this.showToast("Link copied");
    } catch {
      this.showToast(link);
    }
  }

  // ---------- mutations ----------

  showToast(message, actionTitle = null, action = null) {
    const t = { id: Math.random(), message, actionTitle, action };
    this.toast = t;
    setTimeout(() => {
      if (this.toast?.id === t.id) this.toast = null;
    }, action ? 7000 : 4000);
  }

  folderIdForUploads() {
    if (this.section === "myFiles" && this.currentFolder) return this.currentFolder.id;
    return this.rootId;
  }

  async createFolder(name) {
    try {
      await api.createFolder(this.folderIdForUploads(), name);
      this.reload(true);
    } catch (e) {
      this.#handle(e);
    }
  }

  async rename(item, name) {
    if (!name.trim() || name === item.name) return;
    try {
      await api.rename(item.id, item.parentId ?? this.rootId, name);
      this.reload(true);
    } catch (e) {
      this.#handle(e);
    }
  }

  async trash(items) {
    try {
      await api.trashItems(items);
      const restore = items.filter((i) => i.path).map((i) => ({ key: i.id.split("!").pop(), location: i.path }));
      this.items = this.items.filter((i) => !items.some((t) => t.id === i.id));
      this.selection = new Set();
      this.refreshOffline();
      const msg = items.length === 1 ? `“${items[0].name}” moved to trash` : `${items.length} items moved to trash`;
      this.showToast(msg, "Undo", async () => {
        try {
          await api.restoreItems(restore);
          this.reload(true);
          this.showToast("Action undone");
        } catch (e) {
          this.#handle(e);
        }
      });
    } catch (e) {
      this.#handle(e);
    }
  }

  async setStarred(items, on) {
    try {
      await api.setStarred(items.map((i) => i.id), on);
      this.items = this.items
        .map((i) => (items.some((t) => t.id === i.id) ? { ...i, tags: on ? [...new Set([...i.tags, "favorite"])] : i.tags.filter((t) => t !== "favorite") } : i))
        .filter((i) => !(this.section === "starred" && !on && items.some((t) => t.id === i.id)));
      this.showToast(on ? "Added to Starred" : "Removed from Starred");
    } catch (e) {
      this.#handle(e);
    }
  }

  async makeCopy(item) {
    try {
      const c = await api.copyItem(item);
      this.reload(true);
      this.showToast(`Created “${c.name}”`);
    } catch (e) {
      this.#handle(e);
    }
  }

  async move(items, dest) {
    try {
      await api.moveItems(items, dest.id);
      this.reload(true);
      const what = items.length === 1 ? `“${items[0].name}”` : `${items.length} items`;
      this.showToast(`Moved ${what} to “${dest.path ? dest.name : "My Files"}”`, "Open folder", () => this.openFolder(dest.path ?? ""));
    } catch (e) {
      this.#handle(e);
    }
  }

  async restore(items) {
    try {
      await api.restoreItems(items.map((i) => ({ key: i.trashKey, location: i.originalLocation ?? i.name })));
      this.items = this.items.filter((i) => !items.some((t) => t.id === i.id));
      this.selection = new Set();
      this.showToast(items.length === 1 ? `“${items[0].name}” restored` : `${items.length} items restored`);
    } catch (e) {
      this.#handle(e);
    }
  }

  async deleteForever(items) {
    try {
      await api.deleteForever(items.map((i) => i.trashKey));
      this.items = this.items.filter((i) => !items.some((t) => t.id === i.id));
      this.selection = new Set();
      this.refreshQuota();
    } catch (e) {
      this.#handle(e);
    }
  }

  async emptyTrash() {
    try {
      await api.emptyTrash();
      this.items = [];
      this.refreshQuota();
      this.showToast("Trash emptied");
    } catch (e) {
      this.#handle(e);
    }
  }

  // ---------- transfers ----------

  async upload(paths, folderId = null) {
    if (!paths?.length) return;
    this.transfersCollapsed = false;
    try {
      await api.uploadPaths(paths, folderId ?? this.folderIdForUploads());
    } catch (e) {
      this.#handle(e);
    }
  }

  async download(items) {
    this.transfersCollapsed = false;
    try {
      await api.downloadItems(items);
    } catch (e) {
      this.#handle(e);
    }
  }

  #onTransfer(t) {
    const i = this.transfers.findIndex((x) => x.id === t.id);
    if (i >= 0) this.transfers[i] = t;
    else this.transfers = [t, ...this.transfers];
    if (t.state === "done" && t.kind === "upload") this.refreshQuota();
  }
}

function matchesModified(f, secs) {
  if (!secs) return false;
  const d = new Date(secs * 1000);
  const now = new Date();
  switch (f) {
    case "Today": return d.toDateString() === now.toDateString();
    case "Last 7 days": return now - d < 7 * 86400e3;
    case "Last 30 days": return now - d < 30 * 86400e3;
    case "This year": return d.getFullYear() === now.getFullYear();
    case "Last year": return d.getFullYear() === now.getFullYear() - 1;
  }
  return true;
}

export const MODIFIED_FILTERS = ["Today", "Last 7 days", "Last 30 days", "This year", "Last year"];
export const drive = new Drive();
