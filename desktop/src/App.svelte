<script>
  import { onMount } from "svelte";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { Upload } from "@lucide/svelte";
  import { drive } from "./lib/state.svelte.js";
  import { listen } from "./lib/api.js";
  import Login from "./components/Login.svelte";
  import TopBar from "./components/TopBar.svelte";
  import Sidebar from "./components/Sidebar.svelte";
  import Browser from "./components/Browser.svelte";
  import Details from "./components/Details.svelte";
  import ContextMenu from "./components/ContextMenu.svelte";
  import Toast from "./components/Toast.svelte";
  import Transfers from "./components/Transfers.svelte";
  import Dialogs from "./components/Dialogs.svelte";
  import MoveDialog from "./components/MoveDialog.svelte";
  import Settings from "./components/Settings.svelte";

  let topBar = $state();
  let dropping = $state(false);

  onMount(() => {
    drive.boot();
    const unlisten = [];
    listen("signed-out", () => {
      drive.session = null;
    }).then((u) => unlisten.push(u));
    getCurrentWebview()
      .onDragDropEvent((e) => {
        const p = e.payload;
        if (!drive.session || drive.section === "trash") return;
        if (p.type === "enter" || p.type === "over") dropping = true;
        else if (p.type === "leave") dropping = false;
        else if (p.type === "drop") {
          dropping = false;
          drive.upload(p.paths);
        }
      })
      .then((u) => unlisten.push(u));
    return () => unlisten.forEach((u) => u());
  });

  const modalOpen = () => drive.dialog || drive.moveTargets || drive.showSettings;

  function onkey(e) {
    if (!drive.session || modalOpen()) return;
    const typing = e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement;
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === "f") {
      e.preventDefault();
      topBar?.focusSearch();
      return;
    }
    if (typing) return;
    const sel = drive.selectedItems;
    if (mod && e.key.toLowerCase() === "a") {
      e.preventDefault();
      drive.selection = new Set(drive.visibleItems.map((i) => i.id));
    } else if (e.key === "Escape") {
      drive.menu = null;
      drive.selection = new Set();
    } else if (e.key === "Delete" && sel.length) {
      if (drive.section === "trash") drive.dialog = { kind: "deleteForever", items: sel };
      else drive.trash(sel);
    } else if (e.key === "F2" && sel.length === 1 && drive.section !== "trash") {
      drive.dialog = { kind: "rename", item: sel[0], value: sel[0].name };
    } else if (e.key === "Enter" && sel.length === 1) {
      drive.open(sel[0]);
    } else if (e.key === "Backspace" && e.altKey === false && drive.section === "myFiles" && drive.crumbs.length > 1) {
      drive.openFolder(drive.crumbs[drive.crumbs.length - 2].path);
    } else if (e.key === "F5" || (mod && e.key.toLowerCase() === "r")) {
      e.preventDefault();
      drive.reload();
    }
  }
</script>

<svelte:window onkeydown={onkey} />
<svelte:document oncontextmenu={(e) => e.target instanceof HTMLInputElement || e.preventDefault()} />

{#if drive.booting}
  <div class="boot"><div class="spinner"></div></div>
{:else if !drive.session}
  <Login />
{:else}
  <div class="shell">
    <TopBar bind:this={topBar} />
    {#if drive.sessionExpired}
      <div class="expired">
        <span>Your session has expired. Sign in again to keep using Skyfolder.</span>
        <button class="pill text" onclick={() => drive.signIn(drive.session.account.serverUrl)} disabled={drive.signingIn}>
          {drive.signingIn ? "Waiting for your browser…" : "Sign in"}
        </button>
      </div>
    {/if}
    <div class="body">
      <Sidebar />
      <Browser />
      {#if drive.showDetails}<Details />{/if}
    </div>
  </div>
  {#if dropping}
    <div class="drop">
      <div class="drop-card">
        <Upload size={28} />
        <span>Drop files to upload them to <b>{drive.section === "myFiles" ? drive.crumbs[drive.crumbs.length - 1].name : "My Files"}</b></span>
      </div>
    </div>
  {/if}
  <ContextMenu />
  <Toast />
  <Transfers />
  <Dialogs />
  <MoveDialog />
  <Settings />
{/if}

<style>
  .boot {
    height: 100%;
    display: grid;
    place-items: center;
  }
  .shell {
    height: 100%;
    display: flex;
    flex-direction: column;
  }
  .body {
    flex: 1;
    min-height: 0;
    display: flex;
    padding: 0 16px 16px 0;
  }
  .expired {
    margin: 0 16px 12px;
    padding: 4px 8px 4px 20px;
    border-radius: 8px;
    background: var(--banner);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .drop {
    position: fixed;
    inset: 0;
    z-index: 80;
    background: color-mix(in srgb, var(--accent) 12%, transparent);
    border: 3px solid var(--accent);
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 48px;
    pointer-events: none;
  }
  .drop-card {
    background: var(--accent);
    color: var(--surface);
    padding: 14px 24px;
    border-radius: 12px;
    display: flex;
    align-items: center;
    gap: 14px;
    box-shadow: var(--shadow);
  }
</style>
