<script>
  import { X } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
  import { KINDS, kindOf, formatBytes, longDate } from "../lib/kinds.js";
  import ItemIcon from "./ItemIcon.svelte";
  import Thumb from "./Thumb.svelte";

  const sel = $derived(drive.selectedItems);
  const item = $derived(sel.length === 1 ? sel[0] : null);
  const target = $derived(item ?? (sel.length === 0 && drive.section === "myFiles" ? drive.currentFolder : null));

  function where(i) {
    if (drive.section === "trash") return i.originalLocation ? "/" + i.originalLocation : "—";
    if (i.path == null) return "—";
    return "/" + i.path;
  }
</script>

<aside>
  <div class="top">
    {#if target}
      <ItemIcon item={target} size={22} />
      <span class="ellipsis title">{target.path === "" ? "My Files" : target.name}</span>
    {:else}
      <span class="title">{sel.length ? `${sel.length} items selected` : drive.title}</span>
    {/if}
    <button class="icon-btn" title="Close" onclick={() => (drive.showDetails = false)}><X size={20} /></button>
  </div>
  {#if target}
    {#if !target.isFolder}
      <div class="preview"><Thumb item={target} /></div>
    {/if}
    <h4>File details</h4>
    <dl>
      <dt>Type</dt>
      <dd>{KINDS[kindOf(target)].type}</dd>
      {#if !target.isFolder}
        <dt>Size</dt>
        <dd>{formatBytes(target.size)}</dd>
      {/if}
      <dt>Location</dt>
      <dd class="sel">{where(target)}</dd>
      <dt>Modified</dt>
      <dd>{longDate(target.modified)}</dd>
      {#if target.deletedAt}
        <dt>Deleted</dt>
        <dd>{longDate(target.deletedAt)}</dd>
      {/if}
      <dt>Available offline</dt>
      <dd>{drive.isPinned(target) ? "Yes (kept on this computer)" : drive.isOffline(target) ? "Downloaded" : "No (online only)"}</dd>
      {#if target.contentType}
        <dt>Content type</dt>
        <dd>{target.contentType}</dd>
      {/if}
    </dl>
  {:else}
    <div class="none muted">
      {sel.length ? "Select a single item to see its details." : "Select a file or folder to see its details."}
    </div>
  {/if}
</aside>

<style>
  aside {
    width: 340px;
    flex: none;
    background: var(--surface);
    border-radius: 16px;
    margin-left: 16px;
    padding: 12px 16px 16px 20px;
    overflow-y: auto;
  }
  .top {
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 40px;
  }
  .top :global(svg) {
    flex: none;
  }
  .title {
    flex: 1;
    font-size: 18px;
  }
  .preview {
    height: 190px;
    margin: 16px 0;
    border: 1px solid var(--divider);
    border-radius: 8px;
    overflow: hidden;
  }
  h4 {
    font-size: 16px;
    font-weight: 500;
    margin: 16px 0 8px;
  }
  dl {
    margin: 0;
  }
  dt {
    font-size: 12px;
    font-weight: 500;
    margin-top: 14px;
  }
  dd {
    margin: 2px 0 0;
    color: var(--text2);
    word-break: break-word;
  }
  .sel {
    user-select: text;
    -webkit-user-select: text;
  }
  .none {
    padding: 48px 8px;
    text-align: center;
  }
</style>
