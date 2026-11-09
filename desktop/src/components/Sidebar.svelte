<script>
  import { Plus, HardDrive, Clock, Star, CloudDownload, Trash2, FolderPlus, FileUp, FolderUp, FolderOpen, CircleAlert } from "@lucide/svelte";
  import { open } from "@tauri-apps/plugin-dialog";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";
  import { formatBytes } from "../lib/kinds.js";

  let newMenu = $state(false);

  const nav = [
    { id: "myFiles", label: "My Files", icon: HardDrive },
    { id: "recent", label: "Recent", icon: Clock },
    { id: "starred", label: "Starred", icon: Star },
    { id: "offline", label: "Available offline", icon: CloudDownload },
    { id: "trash", label: "Trash", icon: Trash2 },
  ];

  const pct = $derived(drive.quota?.total ? Math.min(100, (drive.quota.used / drive.quota.total) * 100) : 0);

  async function uploadFiles() {
    newMenu = false;
    const sel = await open({ multiple: true, title: "Upload files" });
    if (sel) drive.upload(Array.isArray(sel) ? sel : [sel]);
  }
  async function uploadFolder() {
    newMenu = false;
    const sel = await open({ directory: true, multiple: true, title: "Upload folder" });
    if (sel) drive.upload(Array.isArray(sel) ? sel : [sel]);
  }
  function newFolder() {
    newMenu = false;
    drive.dialog = { kind: "newFolder", value: "Untitled folder" };
  }
</script>

<svelte:window onclick={() => (newMenu = false)} />

<nav>
  <div class="new-wrap">
    <button class="new" onclick={(e) => { e.stopPropagation(); newMenu = !newMenu; }}>
      <Plus size={24} strokeWidth={2.2} />
      <span>New</span>
    </button>
    {#if newMenu}
      <div class="menu new-menu" role="menu">
        <button onclick={newFolder}><FolderPlus size={20} />New folder</button>
        <hr />
        <button onclick={uploadFiles}><FileUp size={20} />File upload</button>
        <button onclick={uploadFolder}><FolderUp size={20} />Folder upload</button>
      </div>
    {/if}
  </div>

  {#each nav as n}
    {@const Icon = n.icon}
    <button class="item" class:selected={drive.section === n.id} onclick={() => drive.go(n.id)}>
      <Icon size={20} />
      <span>{n.label}</span>
    </button>
  {/each}

  {#if drive.session?.syncRoot}
    <button class="item" onclick={() => api.openDriveFolder()} title={drive.session.syncRoot}>
      <FolderOpen size={20} />
      <span>Open Skyfolder folder</span>
    </button>
  {:else if drive.session?.syncError}
    <div class="sync-error" title={drive.session.syncError}>
      <CircleAlert size={16} />
      <span>File manager integration is off: {drive.session.syncError}</span>
    </div>
  {/if}

  <div class="storage">
    {#if drive.quota}
      {#if drive.quota.total}
        <div class="bar"><div style:width="{pct}%" class:full={pct > 90}></div></div>
        <span class="muted">{formatBytes(drive.quota.used)} of {formatBytes(drive.quota.total)} used</span>
      {:else}
        <span class="muted">{formatBytes(drive.quota.used)} used</span>
      {/if}
    {/if}
  </div>
</nav>

<style>
  nav {
    width: 256px;
    flex: none;
    display: flex;
    flex-direction: column;
    padding: 4px 16px 16px 8px;
    gap: 1px;
    overflow-y: auto;
  }
  .new-wrap {
    position: relative;
    margin: 4px 0 16px 8px;
  }
  .new {
    height: 56px;
    padding: 0 20px 0 16px;
    border-radius: 16px;
    background: var(--new-button);
    box-shadow: var(--shadow);
    display: inline-flex;
    align-items: center;
    gap: 12px;
    font-weight: 500;
  }
  .new:hover {
    filter: brightness(0.97);
  }
  .new-menu {
    position: absolute;
    top: 0;
    left: 0;
  }
  .item {
    height: 32px;
    border-radius: 16px;
    padding: 0 12px 0 16px;
    display: flex;
    align-items: center;
    gap: 16px;
    text-align: left;
    color: var(--text);
  }
  .item :global(svg) {
    color: var(--text2);
    flex: none;
  }
  .item:hover {
    background: var(--nav-hover);
  }
  .item.selected {
    background: var(--nav-selected);
    font-weight: 600;
  }
  .sync-error {
    display: flex;
    gap: 8px;
    padding: 8px 12px 8px 16px;
    font-size: 12px;
    color: var(--danger);
  }
  .sync-error :global(svg) {
    flex: none;
    margin-top: 2px;
  }
  .storage {
    margin-top: 16px;
    padding: 0 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    font-size: 13px;
  }
  .bar {
    height: 4px;
    border-radius: 2px;
    background: var(--progress-track);
    overflow: hidden;
  }
  .bar div {
    height: 100%;
    background: var(--accent);
  }
  .bar div.full {
    background: var(--danger);
  }
</style>
