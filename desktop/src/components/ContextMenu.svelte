<script>
  import {
    ExternalLink, Download, Pencil, Copy, Link, FolderInput, Star, StarOff, Info, Trash2, RotateCcw, CloudDownload,
    CloudOff, FolderOpen, Globe,
  } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";

  let el = $state();
  let pos = $state({ x: 0, y: 0 });

  const m = $derived(drive.menu);
  const targets = $derived(m ? drive.targets(m.item) : []);
  const single = $derived(targets.length === 1 ? targets[0] : null);
  const allStarred = $derived(targets.every((i) => i.tags?.includes("favorite")));
  const allPinned = $derived(targets.every((i) => drive.isPinned(i)));
  const anyLocal = $derived(targets.some((i) => drive.isOffline(i)));
  const inTrash = $derived(drive.section === "trash");
  const syncOn = $derived(!!drive.session?.syncRoot);

  $effect(() => {
    if (!m || !el) return;
    const r = el.getBoundingClientRect();
    pos = {
      x: Math.max(8, Math.min(m.x, window.innerWidth - r.width - 8)),
      y: Math.max(8, Math.min(m.y, window.innerHeight - r.height - 8)),
    };
  });

  function act(fn) {
    return () => {
      drive.menu = null;
      fn();
    };
  }
</script>

<svelte:window onclick={() => (drive.menu = null)} onblur={() => (drive.menu = null)} onresize={() => (drive.menu = null)} />

{#if m}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="menu" bind:this={el} style:left="{pos.x}px" style:top="{pos.y}px" onclick={(e) => e.stopPropagation()} oncontextmenu={(e) => e.preventDefault()}>
    {#if inTrash}
      <button onclick={act(() => drive.restore(targets))}><RotateCcw size={20} />Restore</button>
      <button onclick={act(() => (drive.dialog = { kind: "deleteForever", items: targets }))}><Trash2 size={20} />Delete forever</button>
    {:else}
      {#if single}
        <button onclick={act(() => drive.open(single))}><ExternalLink size={20} />Open</button>
        {#if syncOn && single.path != null}
          <button onclick={act(() => drive.reveal(single))}><FolderOpen size={20} />Show in file manager</button>
        {/if}
        <button onclick={act(() => api.openWeb(single.id))}><Globe size={20} />Open in web browser</button>
        <hr />
      {/if}
      <button onclick={act(() => drive.download(targets))}><Download size={20} />Download</button>
      {#if single}
        <button onclick={act(() => (drive.dialog = { kind: "rename", item: single, value: single.name }))}><Pencil size={20} />Rename</button>
        {#if !single.isFolder}
          <button onclick={act(() => drive.makeCopy(single))}><Copy size={20} />Make a copy</button>
        {/if}
      {/if}
      <hr />
      {#if single}
        <button onclick={act(() => drive.copyLink(single))}><Link size={20} />Copy link</button>
      {/if}
      <button onclick={act(() => (drive.moveTargets = targets))}><FolderInput size={20} />Move</button>
      {#if allStarred}
        <button onclick={act(() => drive.setStarred(targets, false))}><StarOff size={20} />Remove from Starred</button>
      {:else}
        <button onclick={act(() => drive.setStarred(targets, true))}><Star size={20} />Add to Starred</button>
      {/if}
      {#if syncOn}
        <hr />
        {#if !allPinned}
          <button onclick={act(() => drive.setOffline(targets, true))}><CloudDownload size={20} />Make available offline</button>
        {/if}
        {#if allPinned || anyLocal}
          <button onclick={act(() => drive.setOffline(targets, false))}><CloudOff size={20} />Remove download</button>
        {/if}
      {/if}
      <hr />
      <button onclick={act(() => (drive.showDetails = true))}><Info size={20} />File information</button>
      <button onclick={act(() => drive.trash(targets))}><Trash2 size={20} />Move to trash</button>
    {/if}
  </div>
{/if}
