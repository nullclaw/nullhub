<script lang="ts">
  import { page } from '$app/stores';
  import { onMount } from 'svelte';
  import StatusBadge from '$lib/components/StatusBadge.svelte';
  import LogViewer from '$lib/components/LogViewer.svelte';
  import ConfigEditor from '$lib/components/ConfigEditor.svelte';
  import { api } from '$lib/api/client';

  let component = $derived($page.params.component);
  let name = $derived($page.params.name);
  let instance = $state<any>(null);
  let activeTab = $state('overview');

  onMount(async () => {
    try {
      const status = await api.getStatus();
      const instances = status.instances || {};
      if (instances[component] && instances[component][name]) {
        instance = instances[component][name];
      }
    } catch (e) {
      console.error(e);
    }
  });

  async function start() { await api.startInstance(component, name); }
  async function stop() { await api.stopInstance(component, name); }
  async function restart() { await api.restartInstance(component, name); }
  async function remove() {
    if (confirm('Are you sure you want to delete this instance?')) {
      await api.deleteInstance(component, name);
      window.location.href = '/';
    }
  }
</script>

<div class="instance-detail">
  <div class="detail-header">
    <div>
      <h1>{name}</h1>
      <span class="component-tag">{component}</span>
    </div>
    <div class="actions">
      <button class="btn" onclick={start}>Start</button>
      <button class="btn" onclick={stop}>Stop</button>
      <button class="btn" onclick={restart}>Restart</button>
      <button class="btn danger" onclick={remove}>Delete</button>
    </div>
  </div>

  <div class="tabs">
    <button class:active={activeTab === 'overview'} onclick={() => activeTab = 'overview'}>Overview</button>
    <button class:active={activeTab === 'config'} onclick={() => activeTab = 'config'}>Config</button>
    <button class:active={activeTab === 'logs'} onclick={() => activeTab = 'logs'}>Logs</button>
  </div>

  <div class="tab-content">
    {#if activeTab === 'overview'}
      <div class="overview-grid">
        <div class="info-card">
          <span class="label">Status</span>
          <StatusBadge status={instance?.status || 'stopped'} />
        </div>
        <div class="info-card">
          <span class="label">Version</span>
          <span>{instance?.version || '-'}</span>
        </div>
        <div class="info-card">
          <span class="label">Auto Start</span>
          <span>{instance?.auto_start ? 'Yes' : '-'}</span>
        </div>
      </div>
    {:else if activeTab === 'config'}
      <ConfigEditor {component} {name} />
    {:else if activeTab === 'logs'}
      <LogViewer {component} {name} />
    {/if}
  </div>
</div>

<style>
  .instance-detail {
    padding: 2rem;
    max-width: 1200px;
    margin: 0 auto;
  }
  .detail-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 1.5rem;
  }
  .detail-header h1 {
    font-size: 1.75rem;
    font-weight: 600;
    margin-bottom: 0.375rem;
  }
  .component-tag {
    padding: 0.125rem 0.5rem;
    background: var(--bg-tertiary);
    border-radius: var(--radius-sm);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-secondary);
  }
  .actions {
    display: flex;
    gap: 0.5rem;
  }
  .btn {
    padding: 0.375rem 0.75rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-tertiary);
    color: var(--text-primary);
    font-size: 0.8125rem;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }
  .btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
  }
  .btn.danger {
    color: var(--error);
    border-color: color-mix(in srgb, var(--error) 30%, transparent);
  }
  .btn.danger:hover {
    background: color-mix(in srgb, var(--error) 15%, transparent);
    border-color: var(--error);
  }
  .tabs {
    display: flex;
    gap: 0;
    border-bottom: 1px solid var(--border);
    margin-bottom: 1.5rem;
  }
  .tabs button {
    padding: 0.625rem 1.25rem;
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    color: var(--text-secondary);
    font-size: 0.875rem;
    cursor: pointer;
    transition: color 0.15s, border-color 0.15s;
  }
  .tabs button:hover {
    color: var(--text-primary);
  }
  .tabs button.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
  }
  .tab-content {
    min-height: 400px;
  }
  .overview-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 1rem;
  }
  .info-card {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding: 1.25rem;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }
  .label {
    font-size: 0.75rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 500;
  }
</style>
