<script lang="ts">
  import { api } from "$lib/api/client";

  let {
    name = "",
    displayName = "",
    description = "",
    alpha = false,
    installed = false,
    standalone = false,
    instanceCount = 0,
  } = $props();
  let importing = $state(false);
  let imported = $state(false);
  let comingSoon = $derived(alpha && !installed && !standalone);

  async function handleImport(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    importing = true;
    try {
      await api.importInstance(name);
      imported = true;
      standalone = false;
      installed = true;
      instanceCount = 1;
    } catch (err) {
      console.error("Import failed:", err);
    } finally {
      importing = false;
    }
  }
</script>

{#if comingSoon}
<div class="component-card disabled">
  <div class="card-header">
    <h3>{displayName}</h3>
    <div class="card-actions">
      <span class="alpha-badge">&lt;Alpha&gt;</span>
      <span class="coming-soon-badge">Coming Soon</span>
    </div>
  </div>
  <p>{description}</p>
</div>
{:else}
<a href="/install/{name}" class="component-card">
  <div class="card-header">
    <h3>{displayName}</h3>
    <div class="card-actions">
      {#if alpha}
        <span class="alpha-badge">&lt;Alpha&gt;</span>
      {/if}
      {#if imported}
        <span class="installed-badge">Imported</span>
      {:else if standalone}
        <button class="import-btn" onclick={handleImport} disabled={importing}>
          {importing ? "Importing..." : "Import"}
        </button>
      {:else if installed}
        <span class="installed-badge"
          >{instanceCount} {instanceCount === 1 ? "instance" : "instances"}</span
        >
      {/if}
    </div>
  </div>
  <p>{description}</p>
</a>
{/if}

<style>
  .component-card {
    display: block;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1.5rem;
    color: var(--fg);
    transition: all 0.2s ease;
    backdrop-filter: blur(4px);
  }

  .component-card:hover:not(.disabled) {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 15px var(--border-glow);
    transform: translateY(-2px);
  }

  .component-card.disabled {
    opacity: 0.45;
    cursor: not-allowed;
    pointer-events: none;
  }

  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    padding-bottom: 0.75rem;
  }

  .card-actions {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  h3 {
    font-size: 1.125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .installed-badge {
    font-size: 0.75rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    padding: 0.25rem 0.5rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: bold;
    box-shadow: inset 0 0 5px color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .alpha-badge {
    font-size: 0.7rem;
    background: color-mix(in srgb, #ffb84d 18%, transparent);
    color: #ffb84d;
    border: 1px solid color-mix(in srgb, #ffb84d 65%, #000 35%);
    padding: 0.25rem 0.45rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    font-weight: 700;
    box-shadow: inset 0 0 4px color-mix(in srgb, #ffb84d 35%, transparent);
  }

  .coming-soon-badge {
    font-size: 0.7rem;
    background: color-mix(in srgb, var(--fg-dim) 12%, transparent);
    color: var(--fg-dim);
    border: 1px solid color-mix(in srgb, var(--fg-dim) 40%, transparent);
    padding: 0.25rem 0.45rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    font-weight: 700;
  }

  .import-btn {
    font-size: 0.75rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    padding: 0.375rem 0.75rem;
    border-radius: 2px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: bold;
  }

  .import-btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }

  .import-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    box-shadow: none;
    text-shadow: none;
  }

  p {
    font-size: 0.875rem;
    color: var(--fg-dim);
    line-height: 1.6;
    font-family: var(--font-mono);
  }
</style>
