<script>
  import { enable, disable, isEnabled } from "@tauri-apps/plugin-autostart";
  import { drive } from "../lib/state.svelte.js";
  import { api } from "../lib/api.js";

  let autostart = $state(false);
  let autostartAvailable = $state(true);
  let confirmSignOut = $state(false);

  $effect(() => {
    if (!drive.showSettings) return;
    confirmSignOut = false;
    isEnabled()
      .then((v) => (autostart = v))
      .catch(() => (autostartAvailable = false));
  });

  async function toggleAutostart() {
    try {
      if (autostart) await disable();
      else await enable();
      autostart = await isEnabled();
    } catch (e) {
      drive.showToast(String(e));
    }
  }

  async function signOut() {
    drive.showSettings = false;
    await drive.signOut();
  }

  const acct = $derived(drive.session?.account);
</script>

<svelte:window onkeydown={(e) => drive.showSettings && e.key === "Escape" && (drive.showSettings = false)} />

{#if drive.showSettings && acct}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scrim" onclick={() => (drive.showSettings = false)}>
    <div class="dialog settings" onclick={(e) => e.stopPropagation()}>
      <h2>Settings</h2>

      <div class="group">
        <div class="label">Account</div>
        <div class="val">{acct.displayName || acct.username}</div>
        <div class="muted small sel">{acct.username} · {acct.serverUrl}</div>
      </div>

      <div class="group">
        <div class="label">File manager</div>
        {#if drive.session.syncRoot}
          <div class="val sel">{drive.session.syncRoot}</div>
          <div class="muted small">Files show up here but download only when you open them. Use “Make available offline” to keep them on this computer.</div>
          <button class="pill outline" onclick={() => api.openDriveFolder()}>Open folder</button>
        {:else}
          <div class="muted small">Not available{drive.session.syncError ? `: ${drive.session.syncError}` : "."}</div>
        {/if}
      </div>

      {#if autostartAvailable}
        <label class="group toggle">
          <div>
            <div class="val">Open Skyfolder when you sign in</div>
            <div class="muted small">Keeps the file manager folder connected in the background.</div>
          </div>
          <input type="checkbox" checked={autostart} onchange={toggleAutostart} />
        </label>
      {/if}

      <div class="actions">
        {#if confirmSignOut}
          <span class="muted small grow">This removes downloaded files from this computer. Files in the cloud are kept.</span>
          <button class="pill text" onclick={() => (confirmSignOut = false)}>Cancel</button>
          <button class="pill text danger" onclick={signOut}>Sign out</button>
        {:else}
          <button class="pill text danger" onclick={() => (confirmSignOut = true)}>Sign out</button>
          <span class="grow"></span>
          <button class="pill text" onclick={() => (drive.showSettings = false)}>Done</button>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .settings {
    width: min(500px, calc(100vw - 32px));
  }
  .group {
    padding: 12px 0;
    border-top: 1px solid var(--divider);
    display: flex;
    flex-direction: column;
    gap: 4px;
    align-items: flex-start;
  }
  .group .pill {
    margin-top: 8px;
  }
  .label {
    font-size: 12px;
    font-weight: 500;
    color: var(--text2);
  }
  .small {
    font-size: 12.5px;
  }
  .sel {
    user-select: text;
    -webkit-user-select: text;
    word-break: break-all;
  }
  .toggle {
    flex-direction: row;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
  }
  .toggle input {
    width: 18px;
    height: 18px;
    accent-color: var(--accent);
    flex: none;
  }
  .grow {
    flex: 1;
  }
  .actions {
    align-items: center;
  }
</style>
