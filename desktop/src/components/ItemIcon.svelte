<script>
  import { KINDS, kindOf } from "../lib/kinds.js";
  let { item, size = 20 } = $props();
  const kind = $derived(KINDS[kindOf(item)]);
</script>

{#if item.isFolder}
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
    <path fill="var(--text2)" d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
  </svg>
{:else}
  {@const Icon = kind.icon}
  <Icon size={size} color={kind.color} strokeWidth={2} />
{/if}
