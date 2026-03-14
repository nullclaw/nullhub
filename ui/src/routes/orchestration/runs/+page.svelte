<script lang="ts">
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';

  let runs = $state<any[]>([]);
  let workflows = $state<any[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  let filterStatus = $state('');
  let filterWorkflow = $state('');

  const statuses = ['', 'running', 'pending', 'completed', 'failed', 'interrupted', 'cancelled'];

  async function loadData() {
    try {
      const [r, w] = await Promise.all([
        api.listRuns({ status: filterStatus || undefined, workflow_id: filterWorkflow || undefined }),
        api.listWorkflows(),
      ]);
      runs = r || [];
      workflows = w || [];
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    // Re-load when filters change (also runs on initial mount)
    filterStatus;
    filterWorkflow;
    void loadData();
  });

  const statusColors: Record<string, string> = {
    running: 'var(--accent)',
    pending: 'var(--accent)',
    completed: 'var(--success)',
    failed: 'var(--error)',
    interrupted: 'var(--warning)',
    cancelled: 'var(--fg-dim)',
  };

  function formatDuration(run: any): string {
    if (!run.created_at) return '-';
    const start = new Date(run.created_at).getTime();
    const end = run.completed_at ? new Date(run.completed_at).getTime() : Date.now();
    const secs = Math.floor((end - start) / 1000);
    if (secs < 60) return `${secs}s`;
    if (secs < 3600) return `${Math.floor(secs / 60)}m ${secs % 60}s`;
    return `${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`;
  }

  function formatTime(ts: string): string {
    if (!ts) return '-';
    return new Date(ts).toLocaleString();
  }

  function runHref(id: string): string {
    return orchestrationUiRoutes.run(id);
  }
</script>

<div class="page">
  <div class="header">
    <h1>Runs</h1>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  <div class="filter-bar">
    <div class="filter-group">
      <label class="filter-label" for="status-filter">Status</label>
      <select id="status-filter" class="filter-select" bind:value={filterStatus}>
        {#each statuses as s}
          <option value={s}>{s || 'All'}</option>
        {/each}
      </select>
    </div>
    <div class="filter-group">
      <label class="filter-label" for="workflow-filter">Workflow</label>
      <select id="workflow-filter" class="filter-select" bind:value={filterWorkflow}>
        <option value="">All</option>
        {#each workflows as wf}
          <option value={wf.id}>{wf.name || wf.id}</option>
        {/each}
      </select>
    </div>
  </div>

  {#if loading}
    <div class="loading">Loading runs...</div>
  {:else if runs.length === 0}
    <div class="empty-state">
      <p>> No runs match the current filter.</p>
    </div>
  {:else}
    <div class="table-section">
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Workflow</th>
              <th>Status</th>
              <th>Duration</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {#each runs as run}
              <tr onclick={() => goto(runHref(run.id))} class="clickable">
                <td class="mono">{(run.id || '').slice(0, 8)}</td>
                <td>{run.workflow_name || run.workflow_id || '-'}</td>
                <td>
                  <span
                    class="status-badge"
                    style="--badge-color: {statusColors[run.status] || 'var(--fg-dim)'}"
                  >{run.status}</span>
                </td>
                <td class="mono">{formatDuration(run)}</td>
                <td>{formatTime(run.created_at)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </div>
  {/if}
</div>

<style>
  .page {
    padding: 2rem;
    max-width: 1400px;
    margin: 0 auto;
  }
  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 2rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid var(--border);
  }
  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    text-shadow: var(--text-glow);
    text-transform: uppercase;
    letter-spacing: 2px;
  }
  .filter-bar {
    display: flex;
    gap: 1rem;
    margin-bottom: 1.5rem;
    padding: 0.75rem 1rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
  }
  .filter-group {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .filter-label {
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
  }
  .filter-select {
    padding: 0.375rem 0.625rem;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    outline: none;
    cursor: pointer;
  }
  .filter-select:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 4px var(--border-glow);
  }
  .table-section {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1rem;
  }
  .table-wrap {
    overflow-x: auto;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }
  th {
    text-align: left;
    padding: 0.625rem 0.75rem;
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
  }
  td {
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    color: var(--fg);
  }
  td.mono {
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }
  tr.clickable {
    cursor: pointer;
    transition: background 0.15s ease;
  }
  tr.clickable:hover td {
    background: var(--bg-hover);
  }
  .status-badge {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.2rem 0.5rem;
    border-radius: 2px;
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--badge-color);
    background: color-mix(in srgb, var(--badge-color) 10%, transparent);
    box-shadow: inset 0 0 5px color-mix(in srgb, var(--badge-color) 20%, transparent);
    text-shadow: 0 0 4px var(--badge-color);
  }
  .status-badge::before {
    content: '';
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--badge-color);
    box-shadow: 0 0 4px var(--badge-color);
  }
  .error-banner {
    padding: 0.75rem 1rem;
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid var(--error);
    border-radius: 4px;
    margin-bottom: 1.5rem;
    font-size: 0.875rem;
    font-weight: bold;
    text-shadow: 0 0 5px var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 20%, transparent);
  }
  .loading {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
  }
  .empty-state {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
    border: 1px dashed var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .empty-state p {
    font-family: var(--font-mono);
  }
</style>
