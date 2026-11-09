<script>
  // Tile preview: server thumbnail when available, else a big type icon.
  import { api } from "../lib/api.js";
  import { canThumbnail } from "../lib/kinds.js";
  import ItemIcon from "./ItemIcon.svelte";

  let { item } = $props();
  let src = $state(null);

  const cache = (globalThis.__thumbs ??= new Map());

  $effect(() => {
    const key = `${item.id}:${item.etag}`;
    src = cache.get(key) ?? null;
    if (src || cache.has(key) || !canThumbnail(item)) return;
    let alive = true;
    api
      .thumbnail(item)
      .then((url) => {
        cache.set(key, url ?? null);
        if (alive) src = url;
      })
      .catch(() => {});
    return () => (alive = false);
  });
</script>

<div class="thumb">
  {#if src}
    <img {src} alt="" draggable="false" onerror={() => { cache.set(`${item.id}:${item.etag}`, null); src = null; }} />
  {:else}
    <ItemIcon {item} size={56} />
  {/if}
</div>

<style>
  .thumb {
    height: 100%;
    display: grid;
    place-items: center;
    background: var(--surface);
    border-radius: 6px;
    overflow: hidden;
  }
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
</style>
