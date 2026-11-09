<script>
  import { ArrowLeft, ChevronRight, FolderPlus } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";
  import ItemIcon from "./ItemIcon.svelte";

  const targets = $derived(drive.moveTargets);
  let path = $state("");
  let folder = $state(null);
  let folders = $state([]);
  let loading = $state(false);
  let error = $state("");
  let selected = $state(null);
  let creating = $state(false);
  let newName = $state("");

  $effect(() => {
    if (targets) {
      const first = targets[0];
      const parent = first?.path?.includes("/") ? first.path.split("/").slice(0, -1).join("/") : "";
      load(drive.section === "myFiles" ? drive.currentPath : parent);
    }
  });

  async function load(p) {
    path = p;
    selected = null;
    loading = true;
    error = "";
    try {
      const l = await api.list(p);
      folder = l.folder;
      folders = l.items.filter((i) => i.isFolder).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    } catch (e) {
      error = String(e).replace(/^AUTH:/, "");
      folders = [];
    }
    loading = false;
  }

  // Can't move a folder into itself or its own subfolders.
  function blocked(f) {
    return targets.some((t) => t.isFolder && t.path != null && (f.path === t.path || f.path.startsWith(t.path + "/")));
  }

  const dest = $derived(selected ?? folder);
  const sameParent = $derived(dest && targets?.every((t) => t.parentId === dest.id));
  const title = $derived(path === "" ? "My Files" : path.split("/").pop());

  function close() {
    drive.moveTargets = null;
    creating = false;
  }

  async function createFolder() {
    const name = newName.trim();
    creating = false;
    if (!name || !folder) return;
    try {
      await api.createFolder(folder.id, name);
      await load(path);
    } catch (e) {
      error = String(e);
    }
  }

  function move() {
    const t = targets;
    const d = { ...dest, name: dest.path === "" ? "My Files" : dest.name };
    close();
    drive.move(t, d);
  }
</script>

{#if targets}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scrim" onclick={close}>
    <div class="dialog move" onclick={(e) => e.stopPropagation()}>
      <h2 class="ellipsis">Move {targets.length === 1 ? `“${targets[0].name}”` : `${targets.length} items`}</h2>
      <div class="loc">
        <button class="icon-btn sm" disabled={path === ""} title="Back" onclick={() => load(path.split("/").slice(0, -1).join("/"))}><ArrowLeft size={18} /></button>
        <span class="ellipsis">{title}</span>
        <button class="icon-btn sm" title="New folder" disabled={!folder} onclick={() => { creating = true; newName = "Untitled folder"; }}><FolderPlus size={18} /></button>
      </div>
      <div class="list">
        {#if creating}
          <form class="row new" onsubmit={(e) => { e.preventDefault(); createFolder(); }}>
            <!-- svelte-ignore a11y_autofocus -->
            <input class="field" bind:value={newName} autofocus onblur={createFolder} />
          </form>
        {/if}
        {#if loading}
          <div class="msg"><div class="spinner"></div></div>
        {:else if error}
          <div class="msg err">{error}</div>
        {:else if !folders.length && !creating}
          <div class="msg muted">No folders here</div>
        {/if}
        {#each folders as f (f.id)}
          <button
            class="row"
            class:selected={selected?.id === f.id}
            disabled={blocked(f)}
            onclick={() => (selected = f)}
            ondblclick={() => !blocked(f) && load(f.path)}
          >
            <ItemIcon item={f} />
            <span class="ellipsis">{f.name}</span>
            <span class="go" role="presentation" onclick={(e) => { e.stopPropagation(); if (!blocked(f)) load(f.path); }}><ChevronRight size={18} /></span>
          </button>
        {/each}
      </div>
      <div class="actions">
        <button class="pill text" onclick={close}>Cancel</button>
        <button class="pill filled" disabled={!dest || sameParent || loading} onclick={move}>Move here</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .move {
    width: min(480px, calc(100vw - 32px));
  }
  .loc {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 500;
    margin: -4px 0 8px;
  }
  .loc span {
    flex: 1;
  }
  .list {
    height: 320px;
    overflow-y: auto;
    border-top: 1px solid var(--divider);
    border-bottom: 1px solid var(--divider);
  }
  .row {
    width: 100%;
    height: 44px;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 0 8px 0 12px;
    text-align: left;
  }
  .row.new {
    padding: 4px 8px;
  }
  .row .field {
    height: 36px;
  }
  .row:hover:not(:disabled) {
    background: var(--item-hover);
  }
  .row.selected {
    background: var(--item-selected);
  }
  .row span.ellipsis {
    flex: 1;
  }
  .go {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    display: grid;
    place-items: center;
    color: var(--text2);
  }
  .go:hover {
    background: var(--nav-hover);
  }
  .msg {
    padding: 32px;
    display: grid;
    place-items: center;
    text-align: center;
  }
  .err {
    color: var(--danger);
  }
</style>
