<script>
  import { drive } from "../lib/state.svelte.js";

  const d = $derived(drive.dialog);
  let value = $state("");
  let input = $state();

  $effect(() => {
    if (!d) return;
    value = d.value ?? "";
    queueMicrotask(() => {
      if (!input) return;
      input.focus();
      // Select the name without its extension, like Drive.
      const dot = d.kind === "rename" && !d.item.isFolder ? value.lastIndexOf(".") : -1;
      input.setSelectionRange(0, dot > 0 ? dot : value.length);
    });
  });

  function close() {
    drive.dialog = null;
  }

  function submit(e) {
    e?.preventDefault();
    const name = value.trim();
    const cur = d;
    close();
    if (cur.kind === "newFolder" && name) drive.createFolder(name);
    if (cur.kind === "rename" && name) drive.rename(cur.item, name);
    if (cur.kind === "deleteForever") drive.deleteForever(cur.items);
    if (cur.kind === "emptyTrash") drive.emptyTrash();
  }

  const invalid = $derived(!value.trim() || value.includes("/") || value.includes("\\") || value === "." || value === "..");
</script>

<svelte:window onkeydown={(e) => d && e.key === "Escape" && close()} />

{#if d}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scrim" onclick={(e) => e.target === e.currentTarget && close()}>
    <form class="dialog" onsubmit={submit}>
      {#if d.kind === "newFolder" || d.kind === "rename"}
        <h2>{d.kind === "newFolder" ? "New folder" : "Rename"}</h2>
        <input class="field" bind:this={input} bind:value spellcheck="false" />
        <div class="actions">
          <button type="button" class="pill text" onclick={close}>Cancel</button>
          <button type="submit" class="pill text" disabled={invalid}>{d.kind === "newFolder" ? "Create" : "OK"}</button>
        </div>
      {:else if d.kind === "deleteForever"}
        <h2>Delete forever?</h2>
        <p class="muted">
          {d.items.length === 1 ? `“${d.items[0].name}” will be deleted forever` : `${d.items.length} items will be deleted forever`} and you won't be able to restore {d.items.length === 1 ? "it" : "them"}.
        </p>
        <div class="actions">
          <button type="button" class="pill text" onclick={close}>Cancel</button>
          <button type="submit" class="pill text">Delete forever</button>
        </div>
      {:else if d.kind === "emptyTrash"}
        <h2>Delete forever?</h2>
        <p class="muted">All items in the trash will be deleted forever and you won't be able to restore them.</p>
        <div class="actions">
          <button type="button" class="pill text" onclick={close}>Cancel</button>
          <button type="submit" class="pill text">Delete forever</button>
        </div>
      {/if}
    </form>
  </div>
{/if}

<style>
  p {
    margin: 0;
  }
</style>
