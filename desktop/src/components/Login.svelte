<script>
  import { Cloud } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";

  let server = $state(localStorage.getItem("lastServer") || "");

  function submit(e) {
    e.preventDefault();
    if (server.trim() && !drive.signingIn) drive.signIn(server.trim());
  }
</script>

<div class="wrap">
  <form class="card" onsubmit={submit}>
    <div class="logo"><Cloud size={40} strokeWidth={1.6} /></div>
    <h1>Sign in to Skyfolder</h1>
    <p class="muted">Enter the address of your OpenCloud server. You'll finish signing in with your browser.</p>
    <input class="field" placeholder="https://cloud.example.com" bind:value={server} disabled={drive.signingIn} autocomplete="url" spellcheck="false" />
    {#if drive.signInError}
      <p class="error">{drive.signInError}</p>
    {/if}
    <div class="row">
      {#if drive.signingIn}
        <span class="muted waiting">Waiting for your browser…</span>
      {/if}
      <button class="pill filled" type="submit" disabled={!server.trim() || drive.signingIn}>Sign in</button>
    </div>
  </form>
</div>

<style>
  .wrap {
    height: 100%;
    display: grid;
    place-items: center;
    padding: 16px;
  }
  .card {
    width: min(440px, 100%);
    background: var(--surface);
    border-radius: 28px;
    padding: 40px 36px 32px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    box-shadow: var(--shadow);
  }
  .logo {
    color: var(--accent);
  }
  h1 {
    margin: 0;
    font-size: 24px;
    font-weight: 400;
  }
  p {
    margin: 0 0 8px;
  }
  .error {
    color: var(--danger);
    user-select: text;
    -webkit-user-select: text;
  }
  .row {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 12px;
    margin-top: 8px;
  }
  .waiting {
    flex: 1;
  }
</style>
