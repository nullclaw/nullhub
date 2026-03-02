<script lang="ts">
  import StatusBadge from './StatusBadge.svelte';
  import { api } from '$lib/api/client';

  let { component = '', name = '', version = '', status = 'stopped', autoStart = false, port = 0, onAction = () => {} } = $props();
  let loading = $state(false);
  let localStatus = $state(status);

  // Sync localStatus when prop changes (from poll)
  $effect(() => { localStatus = status; });

  async function start(e: Event) {
    e.preventDefault();
    e.stopPropagation();
    loading = true;
    localStatus = 'starting';
    try {
      await api.startInstance(component, name);
      onAction();
    } catch { localStatus = 'stopped'; }
    finally { loading = false; }
  }

  async function stop(e: Event) {
    e.preventDefault();
    e.stopPropagation();
    loading = true;
    localStatus = 'stopping';
    try {
      await api.stopInstance(component, name);
      onAction();
    } catch { localStatus = 'running'; }
    finally { loading = false; }
  }
</script>

<a href="/instances/{component}/{name}" class="card">
  <div class="card-header">
    <span class="card-name">{name}</span>
    <StatusBadge status={localStatus} />
  </div>
  <div class="card-meta">
    <span class="component-tag">{component}</span>
    <span class="version">v{version}</span>
  </div>
  {#if localStatus === 'running' && port > 0}
    <div class="gateway-addr">
      <span class="gateway-label">Gateway:</span>
      <code>127.0.0.1:{port}</code>
    </div>
  {/if}
  <div class="card-actions">
    {#if localStatus === 'running' || localStatus === 'stopping'}
      <button onclick={stop} disabled={loading}>
        {loading ? 'Stopping...' : 'Stop'}
      </button>
    {:else}
      <button onclick={start} disabled={loading}>
        {loading ? 'Starting...' : 'Start'}
      </button>
    {/if}
  </div>
</a>

<style>
  .card {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1.25rem;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    color: var(--text-primary);
    transition: background 0.15s, border-color 0.15s;
  }
  .card:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    color: var(--text-primary);
  }
  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .card-name {
    font-weight: 600;
    font-size: 1rem;
  }
  .card-meta {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }
  .component-tag {
    padding: 0.125rem 0.5rem;
    background: var(--bg-tertiary);
    border-radius: var(--radius-sm);
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }
  .version {
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }
  .card-actions {
    display: flex;
    gap: 0.5rem;
  }
  .card-actions button {
    padding: 0.375rem 0.75rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-tertiary);
    color: var(--text-primary);
    font-size: 0.8125rem;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }
  .card-actions button:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
  }
  .gateway-addr {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8125rem;
  }
  .gateway-label {
    color: var(--text-secondary);
    font-size: 0.75rem;
  }
  .gateway-addr code {
    font-family: var(--font-mono);
    font-size: 0.8rem;
    color: var(--accent);
  }
</style>
