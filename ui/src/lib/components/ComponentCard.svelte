<script lang="ts">
  import { api } from '$lib/api/client';

  let { name = '', displayName = '', description = '', installed = false, standalone = false, instanceCount = 0 } = $props();
  let importing = $state(false);
  let imported = $state(false);

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
      console.error('Import failed:', err);
    } finally {
      importing = false;
    }
  }
</script>

<a href="/install/{name}" class="component-card">
  <div class="card-header">
    <h3>{displayName}</h3>
    {#if imported}
      <span class="installed-badge">Imported</span>
    {:else if standalone}
      <button class="import-btn" onclick={handleImport} disabled={importing}>
        {importing ? 'Importing...' : 'Import'}
      </button>
    {:else if installed}
      <span class="installed-badge">{instanceCount} installed</span>
    {/if}
  </div>
  <p>{description}</p>
</a>

<style>
  .component-card {
    display: block;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1.25rem;
    color: var(--text-primary);
    transition: background 0.15s, border-color 0.15s;
  }

  .component-card:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    color: var(--text-primary);
  }

  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 0.5rem;
  }

  h3 {
    font-size: 1rem;
    font-weight: 600;
  }

  .installed-badge {
    font-size: 0.75rem;
    background: var(--accent);
    color: #fff;
    padding: 0.15rem 0.5rem;
    border-radius: var(--radius-sm);
  }

  .import-btn {
    font-size: 0.75rem;
    background: var(--accent);
    color: #fff;
    border: none;
    padding: 0.25rem 0.75rem;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: opacity 0.15s;
  }

  .import-btn:hover {
    opacity: 0.85;
  }

  .import-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }
</style>
