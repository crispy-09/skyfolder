<script>
  import { X } from "@lucide/svelte";
  import { drive } from "../lib/state.svelte.js";
</script>

{#if drive.toast}
  {@const t = drive.toast}
  <div class="toast" role="status">
    <span class="msg">{t.message}</span>
    {#if t.action}
      <button class="action" onclick={() => { drive.toast = null; t.action(); }}>{t.actionTitle}</button>
    {/if}
    <button class="close" title="Dismiss" onclick={() => (drive.toast = null)}><X size={18} /></button>
  </div>
{/if}

<style>
  .toast {
    position: fixed;
    left: 24px;
    bottom: 24px;
    z-index: 70;
    min-width: 300px;
    max-width: min(560px, calc(100vw - 48px));
    min-height: 48px;
    padding: 6px 8px 6px 16px;
    border-radius: 4px;
    background: var(--toast);
    color: var(--toast-text);
    box-shadow: var(--shadow);
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .msg {
    flex: 1;
    user-select: text;
    -webkit-user-select: text;
  }
  .action {
    color: var(--toast-action);
    font-weight: 500;
    padding: 8px;
    border-radius: 4px;
  }
  .close {
    color: var(--toast-text);
    width: 32px;
    height: 32px;
    display: grid;
    place-items: center;
    border-radius: 50%;
  }
  .action:hover,
  .close:hover {
    background: color-mix(in srgb, var(--toast-text) 12%, transparent);
  }
</style>
