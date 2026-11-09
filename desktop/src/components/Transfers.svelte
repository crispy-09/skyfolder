<script>
  import { ChevronDown, ChevronUp, X, CircleCheck, CircleAlert, FolderOpen } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";
  import ItemIcon from "./ItemIcon.svelte";

  const list = $derived(drive.transfers);
  const running = $derived(list.filter((t) => t.state === "running").length);
  const uploads = $derived(list.some((t) => t.kind === "upload"));
  const downloads = $derived(list.some((t) => t.kind === "download"));
  const title = $derived.by(() => {
    const noun = uploads && downloads ? "transfer" : uploads ? "upload" : "download";
    if (running) return `${running} ${noun}${running === 1 ? "" : "s"} in progress`;
    const failed = list.filter((t) => t.state === "failed").length;
    if (failed) return `${failed} ${noun}${failed === 1 ? "" : "s"} failed`;
    return `${list.length} ${noun}${list.length === 1 ? "" : "s"} complete`;
  });
</script>

{#if list.length}
  <div class="panel">
    <div class="bar">
      <span class="ellipsis">{title}</span>
      <button class="icon-btn sm" title={drive.transfersCollapsed ? "Expand" : "Minimize"} onclick={() => (drive.transfersCollapsed = !drive.transfersCollapsed)}>
        {#if drive.transfersCollapsed}<ChevronUp size={20} />{:else}<ChevronDown size={20} />{/if}
      </button>
      <button class="icon-btn sm" title="Close" disabled={running > 0} onclick={() => (drive.transfers = [])}><X size={20} /></button>
    </div>
    {#if !drive.transfersCollapsed}
      <div class="rows">
        {#each list as t (t.id)}
          <div class="row" title={t.error ?? ""}>
            <ItemIcon item={{ name: t.name, isFolder: t.isFolder }} />
            <div class="mid">
              <span class="ellipsis">{t.name}</span>
              {#if t.state === "running"}
                <div class="progress"><div style:width="{t.total ? Math.min(100, (t.done / t.total) * 100) : 0}%"></div></div>
              {:else if t.state === "failed"}
                <span class="err ellipsis">{t.error}</span>
              {/if}
            </div>
            {#if t.state === "done"}
              {#if t.resultPath}
                <button class="icon-btn sm" title="Show in folder" onclick={() => api.revealPath(t.resultPath)}><FolderOpen size={18} /></button>
              {/if}
              <CircleCheck size={20} color="#188038" />
            {:else if t.state === "failed"}
              <CircleAlert size={20} color="var(--danger)" />
            {:else}
              <div class="mini-spin"></div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}

<style>
  .panel {
    position: fixed;
    right: 24px;
    bottom: 0;
    width: 360px;
    z-index: 65;
    background: var(--surface);
    border-radius: 12px 12px 0 0;
    box-shadow: var(--shadow);
    overflow: hidden;
  }
  .bar {
    height: 52px;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 0 8px 0 20px;
    background: var(--tile);
    font-weight: 500;
  }
  .bar span {
    flex: 1;
  }
  .rows {
    max-height: 260px;
    overflow-y: auto;
  }
  .row {
    height: 52px;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 0 16px 0 20px;
  }
  .row:hover {
    background: var(--item-hover);
  }
  .row > :global(svg) {
    flex: none;
  }
  .mid {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .err {
    font-size: 12px;
    color: var(--danger);
  }
  .progress {
    height: 4px;
    background: var(--progress-track);
    border-radius: 2px;
    overflow: hidden;
  }
  .progress div {
    height: 100%;
    background: var(--accent);
    transition: width 0.2s;
  }
  .mini-spin {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    border: 2.5px solid var(--progress-track);
    border-top-color: var(--accent);
    animation: spin 0.8s linear infinite;
    flex: none;
  }
</style>
