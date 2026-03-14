<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';

  let runs = $state<any[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let stats = $state({ active: 0, completed: 0, failed: 0, interrupted: 0 });

  async function loadRuns() {
    try {
      runs = await api.listRuns() || [];
      stats = {
        active: runs.filter((r: any) => r.status === 'running' || r.status === 'pending').length,
        completed: runs.filter((r: any) => r.status === 'completed').length,
        failed: runs.filter((r: any) => r.status === 'failed').length,
        interrupted: runs.filter((r: any) => r.status === 'interrupted').length,
      };
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  let interval: ReturnType<typeof setInterval>;
  onMount(() => {
    void loadRuns();
    interval = setInterval(loadRuns, 5000);
  });
  onDestroy(() => clearInterval(interval));

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

<div class="dashboard">
  <div class="header">
    <h1>Orchestration</h1>
    <a href={orchestrationUiRoutes.workflows()} class="action-btn">New Run</a>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  <div class="cards">
    <div class="card">
      <div class="card-label">Active</div>
      <div class="card-value" style="color: var(--accent); text-shadow: 0 0 8px var(--accent);">{stats.active}</div>
    </div>
    <div class="card">
      <div class="card-label">Completed</div>
      <div class="card-value" style="color: var(--success); text-shadow: 0 0 8px var(--success);">{stats.completed}</div>
    </div>
    <div class="card">
      <div class="card-label">Failed</div>
      <div class="card-value" style="color: var(--error); text-shadow: 0 0 8px var(--error);">{stats.failed}</div>
    </div>
    <div class="card">
      <div class="card-label">Interrupted</div>
      <div class="card-value" style="color: var(--warning); text-shadow: 0 0 8px var(--warning);">{stats.interrupted}</div>
    </div>
  </div>

  {#if loading && runs.length === 0}
    <div class="loading">Loading runs...</div>
  {:else if runs.length === 0}
    <div class="empty-state">
      <p>> No orchestration runs yet.</p>
      <a href={orchestrationUiRoutes.workflows()} class="btn">Create a Workflow</a>
    </div>
  {:else}
    <div class="table-section">
      <h2>Recent Runs</h2>
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
            {#each runs.slice(0, 20) as run}
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
      {#if runs.length > 20}
        <div class="more-link">
          <a href={orchestrationUiRoutes.runs()}>View all {runs.length} runs</a>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .dashboard {
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
  h2 {
    font-size: 1rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-bottom: 1rem;
    color: var(--fg-dim);
  }
  .action-btn {
    padding: 0.5rem 1rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius);
    font-size: 0.875rem;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .action-btn:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .cards {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 1rem;
    margin-bottom: 2rem;
  }
  .card {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1.25rem;
  }
  .card-label {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
    margin-bottom: 0.5rem;
  }
  .card-value {
    font-size: 2rem;
    font-weight: 700;
    font-family: var(--font-mono);
  }
  .table-section {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1.5rem;
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
    font-size: 1rem;
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
    margin-bottom: 1.5rem;
    font-size: 1.125rem;
    font-family: var(--font-mono);
  }
  .empty-state .btn {
    display: inline-block;
    padding: 0.75rem 1.5rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius);
    font-size: 0.875rem;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .empty-state .btn:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .more-link {
    text-align: center;
    padding: 0.75rem;
  }
  .more-link a {
    color: var(--accent);
    font-size: 0.8125rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .more-link a:hover {
    text-shadow: var(--text-glow);
  }
  @media (max-width: 900px) {
    .cards { grid-template-columns: repeat(2, 1fr); }
  }
</style>
