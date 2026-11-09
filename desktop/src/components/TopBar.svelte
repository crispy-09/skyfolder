<script>
  import { Search, X, Settings, Cloud, ExternalLink } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";

  let focused = $state(false);
  let input;

  const initials = $derived((drive.session?.account.displayName || drive.session?.account.username || "?").trim().slice(0, 1).toUpperCase());

  function onkey(e) {
    if (e.key === "Enter") drive.search();
    if (e.key === "Escape") {
      drive.searchText = "";
      input.blur();
    }
  }

  export function focusSearch() {
    input?.focus();
  }
</script>

<header>
  <div class="brand">
    <Cloud size={30} color="var(--accent)" strokeWidth={1.8} />
    <span>Skyfolder</span>
  </div>
  <div class="search" class:focused>
    <button class="icon-btn" onclick={() => drive.search()} title="Search"><Search size={20} /></button>
    <input
      bind:this={input}
      bind:value={drive.searchText}
      placeholder="Search in Drive"
      onfocus={() => (focused = true)}
      onblur={() => (focused = false)}
      onkeydown={onkey}
      spellcheck="false"
    />
    {#if drive.searchText}
      <button class="icon-btn" title="Clear search" onclick={() => { drive.searchText = ""; if (drive.section === "search") drive.go("myFiles"); }}><X size={20} /></button>
    {/if}
  </div>
  <div class="right">
    <button class="icon-btn" title="Open in web browser" onclick={() => api.openWeb()}><ExternalLink size={20} /></button>
    <button class="icon-btn" title="Settings" onclick={() => (drive.showSettings = true)}><Settings size={20} /></button>
    <button class="avatar" title={`${drive.session?.account.displayName}\n${drive.session?.account.serverUrl}`} onclick={() => (drive.showSettings = true)}>{initials}</button>
  </div>
</header>

<style>
  header {
    height: 64px;
    display: flex;
    align-items: center;
    padding: 0 8px 0 16px;
    gap: 16px;
    flex: none;
  }
  .brand {
    width: 232px;
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 22px;
    color: var(--text2);
    flex: none;
  }
  .search {
    flex: 1;
    max-width: 720px;
    height: 48px;
    border-radius: 24px;
    background: var(--search);
    display: flex;
    align-items: center;
    padding: 0 4px;
  }
  .search.focused {
    background: var(--search-focus);
    box-shadow: var(--shadow);
  }
  .search input {
    flex: 1;
    border: none;
    outline: none;
    background: transparent;
    font-size: 16px;
    min-width: 0;
  }
  .right {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .avatar {
    width: 32px;
    height: 32px;
    margin: 0 8px;
    border-radius: 50%;
    background: var(--accent);
    color: var(--surface);
    font-weight: 500;
  }
  @media (max-width: 1000px) {
    .brand {
      width: auto;
    }
    .brand span {
      display: none;
    }
  }
</style>
