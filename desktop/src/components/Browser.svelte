<script>
  import {
    ChevronRight, ChevronDown, List, LayoutGrid, Info, X, Download, Trash2, FolderInput, Star, Link, MoreVertical,
    ArrowUp, ArrowDown, RotateCcw, CloudDownload, CircleCheck, Pencil, Check, FolderOpen,
  } from "@lucide/svelte";
  import { drive, MODIFIED_FILTERS } from "../lib/state.svelte.js";
  import { KINDS, formatBytes, shortDate } from "../lib/kinds.js";
  import ItemIcon from "./ItemIcon.svelte";
  import Thumb from "./Thumb.svelte";

  let chipMenu = $state(null); // "type" | "modified"
  const items = $derived(drive.visibleItems);
  const folders = $derived(items.filter((i) => i.isFolder));
  const files = $derived(items.filter((i) => !i.isFolder));
  const sel = $derived(drive.selectedItems);
  const inTrash = $derived(drive.section === "trash");
  const showLocation = $derived(["recent", "starred", "offline", "search", "trash"].includes(drive.section));

  function contextMenu(e, item) {
    e.preventDefault();
    e.stopPropagation();
    if (!drive.selection.has(item.id)) {
      drive.selection = new Set([item.id]);
      drive.lastSelected = item.id;
    }
    drive.menu = { x: e.clientX, y: e.clientY, item };
  }

  function moreMenu(e, item) {
    e.stopPropagation();
    const r = e.currentTarget.getBoundingClientRect();
    if (!drive.selection.has(item.id)) drive.selection = new Set([item.id]);
    drive.menu = { x: r.left, y: r.bottom, item };
  }

  function location(item) {
    if (inTrash) return item.originalLocation ? "/" + item.originalLocation.split("/").slice(0, -1).join("/") : "—";
    if (!item.path) return "—";
    const parts = item.path.split("/");
    return parts.length > 1 ? parts[parts.length - 2] : "My Files";
  }

  function emptyText() {
    switch (drive.section) {
      case "myFiles": return drive.crumbs.length > 1 ? ["This folder is empty", "Drop files here or use the New button."] : ["Welcome to Skyfolder", "Drop files here or use the New button to upload."];
      case "recent": return ["No recent files", "See all the files you've recently edited or opened."];
      case "starred": return ["No starred files", "Add stars to things you want to easily find later."];
      case "offline": return ["Nothing available offline", "Right-click a file or folder and choose “Make available offline” to keep it on this computer."];
      case "trash": return ["Trash is empty", "Items in the trash can be restored or deleted forever."];
      case "search": return ["No results", "Try different keywords."];
    }
  }
</script>

<svelte:window onclick={() => (chipMenu = null)} />

<section class="browser">
  <div class="head">
    {#if drive.section === "myFiles"}
      <div class="crumbs">
        {#each drive.crumbs as c, i}
          {#if i > 0}<ChevronRight size={20} class="muted" />{/if}
          <button class="crumb" class:last={i === drive.crumbs.length - 1} onclick={() => i < drive.crumbs.length - 1 && drive.openFolder(c.path)}>{c.name}</button>
        {/each}
      </div>
    {:else}
      <h1>{drive.section === "search" ? `Results for “${drive.query}”` : drive.title}</h1>
    {/if}
    <div class="tools">
      <div class="seg">
        <button class:on={drive.viewMode === "list"} onclick={() => drive.setViewMode("list")} title="List layout">
          {#if drive.viewMode === "list"}<Check size={16} />{/if}<List size={18} />
        </button>
        <button class:on={drive.viewMode === "grid"} onclick={() => drive.setViewMode("grid")} title="Grid layout">
          {#if drive.viewMode === "grid"}<Check size={16} />{/if}<LayoutGrid size={18} />
        </button>
      </div>
      <button class="icon-btn" class:active={drive.showDetails} title="View details" onclick={() => (drive.showDetails = !drive.showDetails)}><Info size={20} /></button>
    </div>
  </div>

  {#if sel.length > 0}
    <div class="selbar">
      <button class="icon-btn sm" title="Clear selection" onclick={() => (drive.selection = new Set())}><X size={18} /></button>
      <span class="count">{sel.length} selected</span>
      {#if inTrash}
        <button class="icon-btn sm" title="Restore" onclick={() => drive.restore(sel)}><RotateCcw size={18} /></button>
        <button class="icon-btn sm" title="Delete forever" onclick={() => (drive.dialog = { kind: "deleteForever", items: sel })}><Trash2 size={18} /></button>
      {:else}
        <button class="icon-btn sm" title="Download" onclick={() => drive.download(sel)}><Download size={18} /></button>
        <button class="icon-btn sm" title="Move" onclick={() => (drive.moveTargets = sel)}><FolderInput size={18} /></button>
        <button class="icon-btn sm" title="Move to trash" onclick={() => drive.trash(sel)}><Trash2 size={18} /></button>
        {#if sel.length === 1}
          <button class="icon-btn sm" title="Copy link" onclick={() => drive.copyLink(sel[0])}><Link size={18} /></button>
        {/if}
        <button class="icon-btn sm" title="More actions" onclick={(e) => moreMenu(e, sel[0])}><MoreVertical size={18} /></button>
      {/if}
    </div>
  {:else if !inTrash}
    <div class="chips">
      <div class="chip-wrap">
        <button class="chip" class:set={drive.typeFilter} onclick={(e) => { e.stopPropagation(); chipMenu = chipMenu === "type" ? null : "type"; }}>
          {#if drive.typeFilter}<Check size={16} />{KINDS[drive.typeFilter].label}{:else}Type{/if}<ChevronDown size={16} />
        </button>
        {#if chipMenu === "type"}
          <div class="menu chip-menu">
            {#each Object.entries(KINDS) as [k, v]}
              {@const Icon = v.icon}
              <button onclick={() => (drive.typeFilter = k)}><Icon size={18} color={v.color} />{v.label}</button>
            {/each}
          </div>
        {/if}
      </div>
      <div class="chip-wrap">
        <button class="chip" class:set={drive.modifiedFilter} onclick={(e) => { e.stopPropagation(); chipMenu = chipMenu === "modified" ? null : "modified"; }}>
          {#if drive.modifiedFilter}<Check size={16} />{drive.modifiedFilter}{:else}Modified{/if}<ChevronDown size={16} />
        </button>
        {#if chipMenu === "modified"}
          <div class="menu chip-menu">
            {#each MODIFIED_FILTERS as f}
              <button onclick={() => (drive.modifiedFilter = f)}>{f}</button>
            {/each}
          </div>
        {/if}
      </div>
      {#if drive.typeFilter || drive.modifiedFilter}
        <button class="pill text" onclick={() => { drive.typeFilter = null; drive.modifiedFilter = null; }}>Clear filters</button>
      {/if}
    </div>
  {:else}
    <div class="banner">
      <span>Items in trash stay here until you delete them forever.</span>
      <button class="pill text" disabled={!drive.items.length} onclick={() => (drive.dialog = { kind: "emptyTrash" })}>Empty trash</button>
    </div>
  {/if}

  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="content" onclick={() => (drive.selection = new Set())}>
    {#if drive.loading && !drive.items.length}
      <div class="center"><div class="spinner"></div></div>
    {:else if drive.loadError}
      <div class="center col">
        <p>Couldn't load this view.</p>
        <p class="muted err">{drive.loadError}</p>
        <button class="pill outline" onclick={() => drive.reload()}>Try again</button>
      </div>
    {:else if !items.length}
      {@const [t, s] = emptyText()}
      <div class="center col">
        <div class="empty-art">
          {#if drive.section === "trash"}<Trash2 size={64} strokeWidth={1.2} />
          {:else if drive.section === "starred"}<Star size={64} strokeWidth={1.2} />
          {:else if drive.section === "offline"}<CloudDownload size={64} strokeWidth={1.2} />
          {:else}<FolderOpen size={64} strokeWidth={1.2} />{/if}
        </div>
        <h2>{drive.typeFilter || drive.modifiedFilter ? "No matching items" : t}</h2>
        <p class="muted">{drive.typeFilter || drive.modifiedFilter ? "Try clearing the filters." : s}</p>
      </div>
    {:else if drive.viewMode === "list"}
      <table>
        <thead>
          <tr>
            <th class="name">
              {#if drive.section === "recent" || inTrash}Name{:else}
                <button onclick={(e) => { e.stopPropagation(); drive.setSort("name"); }}>Name
                  {#if drive.sortKey === "name"}{#if drive.sortAsc}<ArrowUp size={16} />{:else}<ArrowDown size={16} />{/if}{/if}
                </button>
              {/if}
            </th>
            <th class="date">
              {#if inTrash}Date deleted{:else if drive.section === "recent"}Last modified{:else}
                <button onclick={(e) => { e.stopPropagation(); drive.setSort("modified"); }}>Last modified
                  {#if drive.sortKey === "modified"}{#if drive.sortAsc}<ArrowUp size={16} />{:else}<ArrowDown size={16} />{/if}{/if}
                </button>
              {/if}
            </th>
            <th class="size">
              {#if drive.section === "recent" || inTrash}File size{:else}
                <button onclick={(e) => { e.stopPropagation(); drive.setSort("size"); }}>File size
                  {#if drive.sortKey === "size"}{#if drive.sortAsc}<ArrowUp size={16} />{:else}<ArrowDown size={16} />{/if}{/if}
                </button>
              {/if}
            </th>
            {#if showLocation}<th class="loc">{inTrash ? "Original location" : "Location"}</th>{/if}
            <th class="actions"></th>
          </tr>
        </thead>
        <tbody>
          {#each items as item (item.id)}
            <tr
              class:selected={drive.selection.has(item.id)}
              onclick={(e) => { e.stopPropagation(); drive.click(item, items, e); }}
              ondblclick={() => drive.open(item)}
              oncontextmenu={(e) => contextMenu(e, item)}
            >
              <td class="name">
                <div class="namecell">
                  <ItemIcon {item} />
                  <span class="ellipsis">{item.name}</span>
                  {#if item.tags?.includes("favorite")}<Star size={14} class="muted" />{/if}
                  {#if drive.isOffline(item)}<span title="Available offline"><CircleCheck size={15} color="#188038" /></span>{/if}
                </div>
              </td>
              <td class="date muted">{shortDate(inTrash ? item.deletedAt : item.modified)}</td>
              <td class="size muted">{item.isFolder ? "—" : formatBytes(item.size)}</td>
              {#if showLocation}<td class="loc muted ellipsis">{location(item)}</td>{/if}
              <td class="actions">
                <div class="hover-actions">
                  {#if inTrash}
                    <button class="icon-btn sm" title="Restore" onclick={(e) => { e.stopPropagation(); drive.restore([item]); }}><RotateCcw size={17} /></button>
                  {:else}
                    <button class="icon-btn sm" title="Download" onclick={(e) => { e.stopPropagation(); drive.download([item]); }}><Download size={17} /></button>
                    <button class="icon-btn sm" title="Rename" onclick={(e) => { e.stopPropagation(); drive.dialog = { kind: "rename", item, value: item.name }; }}><Pencil size={17} /></button>
                    <button class="icon-btn sm" title={item.tags?.includes("favorite") ? "Remove from Starred" : "Add to Starred"} onclick={(e) => { e.stopPropagation(); drive.setStarred([item], !item.tags?.includes("favorite")); }}><Star size={17} /></button>
                  {/if}
                </div>
                <button class="icon-btn sm" title="More actions" onclick={(e) => moreMenu(e, item)}><MoreVertical size={17} /></button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    {:else}
      {#if folders.length}
        <h3>Folders</h3>
        <div class="grid folders">
          {#each folders as item (item.id)}
            <button
              class="folder-tile"
              class:selected={drive.selection.has(item.id)}
              onclick={(e) => { e.stopPropagation(); drive.click(item, items, e); }}
              ondblclick={() => drive.open(item)}
              oncontextmenu={(e) => contextMenu(e, item)}
            >
              <ItemIcon {item} size={22} />
              <span class="ellipsis">{item.name}</span>
              {#if drive.isOffline(item)}<CircleCheck size={15} color="#188038" />{/if}
            </button>
          {/each}
        </div>
      {/if}
      {#if files.length}
        <h3>Files</h3>
        <div class="grid files">
          {#each files as item (item.id)}
            <button
              class="file-tile"
              class:selected={drive.selection.has(item.id)}
              onclick={(e) => { e.stopPropagation(); drive.click(item, items, e); }}
              ondblclick={() => drive.open(item)}
              oncontextmenu={(e) => contextMenu(e, item)}
            >
              <div class="tile-head">
                <ItemIcon {item} size={18} />
                <span class="ellipsis">{item.name}</span>
                {#if drive.isOffline(item)}<CircleCheck size={15} color="#188038" />{/if}
              </div>
              <div class="tile-body"><Thumb {item} /></div>
            </button>
          {/each}
        </div>
      {/if}
    {/if}
  </div>
</section>

<style>
  .browser {
    flex: 1;
    min-width: 0;
    background: var(--surface);
    border-radius: 16px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .head {
    height: 64px;
    flex: none;
    display: flex;
    align-items: center;
    padding: 0 12px 0 16px;
    gap: 8px;
  }
  h1 {
    margin: 0 0 0 8px;
    font-size: 22px;
    font-weight: 400;
    flex: 1;
  }
  .crumbs {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    overflow: hidden;
  }
  .crumb {
    font-size: 22px;
    padding: 4px 8px;
    border-radius: 18px;
    white-space: nowrap;
    color: var(--text2);
  }
  .crumb:hover:not(.last) {
    background: var(--nav-hover);
  }
  .crumb.last {
    color: var(--text);
    cursor: default;
  }
  .tools {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .seg {
    display: flex;
    border: 1px solid var(--chip-border);
    border-radius: 16px;
    overflow: hidden;
    height: 32px;
  }
  .seg button {
    padding: 0 12px;
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .seg button + button {
    border-left: 1px solid var(--chip-border);
  }
  .seg button.on {
    background: var(--nav-selected);
  }
  .icon-btn.active {
    background: var(--nav-selected);
  }
  .chips,
  .selbar,
  .banner {
    flex: none;
    min-height: 48px;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 20px 8px;
  }
  .selbar {
    margin: 0 16px 8px;
    padding: 0 8px;
    min-height: 40px;
    background: var(--tile);
    border-radius: 20px;
  }
  .selbar .count {
    margin-right: 8px;
  }
  .banner {
    margin: 0 16px 8px;
    padding: 4px 8px 4px 20px;
    background: var(--tile);
    border-radius: 8px;
    justify-content: space-between;
  }
  .chip-wrap {
    position: relative;
  }
  .chip {
    height: 32px;
    padding: 0 8px 0 16px;
    border: 1px solid var(--chip-border);
    border-radius: 8px;
    display: flex;
    align-items: center;
    gap: 6px;
    font-weight: 500;
  }
  .chip:hover {
    background: var(--nav-hover);
  }
  .chip.set {
    background: var(--nav-selected);
    border-color: transparent;
    padding-left: 8px;
  }
  .chip-menu {
    position: absolute;
    top: 36px;
    left: 0;
    max-height: 60vh;
    overflow-y: auto;
  }
  .content {
    flex: 1;
    overflow: auto;
    padding: 0 16px 24px;
  }
  .center {
    height: 100%;
    display: grid;
    place-items: center;
  }
  .center.col {
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    gap: 4px;
    text-align: center;
  }
  .center p {
    margin: 0;
  }
  .err {
    max-width: 480px;
    margin-bottom: 12px !important;
    user-select: text;
    -webkit-user-select: text;
  }
  .empty-art {
    color: var(--accent);
    opacity: 0.7;
    margin-bottom: 8px;
  }
  .center h2 {
    margin: 0;
    font-weight: 400;
    font-size: 22px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
  }
  th {
    position: sticky;
    top: 0;
    background: var(--surface);
    z-index: 1;
    height: 48px;
    text-align: left;
    font-weight: 500;
    border-bottom: 1px solid var(--divider);
    padding: 0 8px;
  }
  th button {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-weight: 500;
    padding: 4px 8px;
    margin-left: -8px;
    border-radius: 14px;
  }
  th button:hover {
    background: var(--nav-hover);
  }
  th.date,
  td.date {
    width: 160px;
  }
  th.size,
  td.size {
    width: 110px;
  }
  th.loc,
  td.loc {
    width: 170px;
  }
  th.actions,
  td.actions {
    width: 152px;
    text-align: right;
  }
  td {
    height: 48px;
    padding: 0 8px;
    border-bottom: 1px solid var(--divider);
  }
  tr:hover td {
    background: var(--item-hover);
  }
  tr.selected td {
    background: var(--item-selected);
  }
  tbody tr td:first-child {
    border-radius: 0;
  }
  .namecell {
    display: flex;
    align-items: center;
    gap: 14px;
    padding-left: 8px;
    min-width: 0;
  }
  .namecell :global(svg) {
    flex: none;
  }
  td.actions {
    white-space: nowrap;
  }
  .hover-actions {
    display: inline-flex;
    visibility: hidden;
  }
  tr:hover .hover-actions {
    visibility: visible;
  }
  h3 {
    font-size: 14px;
    font-weight: 500;
    margin: 12px 4px 12px;
  }
  .grid {
    display: grid;
    gap: 16px;
  }
  .grid.folders {
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  }
  .grid.files {
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  }
  .folder-tile {
    height: 48px;
    border-radius: 12px;
    background: var(--tile);
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 0 16px;
    text-align: left;
    min-width: 0;
  }
  .file-tile {
    border-radius: 12px;
    background: var(--tile);
    display: flex;
    flex-direction: column;
    padding: 0 8px 8px;
    text-align: left;
    min-width: 0;
  }
  .folder-tile:hover,
  .file-tile:hover {
    background: var(--item-hover);
  }
  .folder-tile.selected,
  .file-tile.selected {
    background: var(--item-selected);
  }
  .tile-head {
    height: 44px;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 6px;
    min-width: 0;
    width: 100%;
  }
  .tile-head :global(svg),
  .folder-tile :global(svg) {
    flex: none;
  }
  .tile-body {
    height: 160px;
    width: 100%;
  }
  @media (max-width: 1100px) {
    th.loc,
    td.loc {
      display: none;
    }
  }
</style>
