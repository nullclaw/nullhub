<script lang="ts">
  let { name = '', displayName = '', description = '', installed = false, standalone = false, instanceCount = 0 } = $props();
</script>

<a href="/install/{name}" class="component-card">
  <div class="card-header">
    <h3>{displayName}</h3>
    {#if standalone}
      <span class="installed-badge standalone">Standalone</span>
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

  .installed-badge.standalone {
    background: var(--text-secondary);
  }

  p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }
</style>
