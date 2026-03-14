<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { page } from '$app/stores';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';
  import GraphViewer from '$lib/components/orchestration/GraphViewer.svelte';
  import StateInspector from '$lib/components/orchestration/StateInspector.svelte';
  import RunEventLog from '$lib/components/orchestration/RunEventLog.svelte';
  import InterruptPanel from '$lib/components/orchestration/InterruptPanel.svelte';

  let id = $derived($page.params.id);

  let run = $state<any>(null);
  let workflow = $state<any>({ nodes: {}, edges: [] });
  let events = $state<any[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let nodeStatus = $state<Record<string, string>>({});
  let previousState = $state<any>(null);
  let eventSource: EventSource | null = null;
  let pollInterval: ReturnType<typeof setInterval>;

  async function loadRun() {
    try {
      const data = await api.getRun(id);
      previousState = run?.state || null;
      run = data;
      if (data.workflow) {
        workflow = data.workflow;
      } else if (data.workflow_id) {
        try {
          workflow = await api.getWorkflow(data.workflow_id);
        } catch { /* keep current */ }
      }
      // Build node status map
      const ns: Record<string, string> = {};
      if (data.steps) {
        for (const step of data.steps) {
          ns[step.node_id || step.step] = step.status;
        }
      }
      nodeStatus = ns;
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function connectStream() {
    try {
      eventSource = api.streamRun(id, (event) => {
        events = [...events, { ...event, timestamp: event.timestamp ?? Date.now() / 1000 }];
        // On significant events, refresh run data
        if (['step_completed', 'step_failed', 'run_completed', 'run_failed', 'interrupted', 'state_update', 'values', 'updates', 'task_result'].includes(event.type)) {
          void loadRun();
        }
      });
    } catch {
      // SSE not available, rely on polling
    }
  }

  onMount(() => {
    void loadRun();
    connectStream();
    pollInterval = setInterval(loadRun, 3000);
  });

  onDestroy(() => {
    clearInterval(pollInterval);
    eventSource?.close();
  });

  let isInterrupted = $derived(run?.status === 'interrupted');
  let isActive = $derived(run?.status === 'running' || run?.status === 'pending');

  async function cancelRun() {
    try {
      await api.cancelRun(id);
      await loadRun();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function resumeRun(updates: any) {
    try {
      await api.resumeRun(id, updates);
      await loadRun();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  const statusColors: Record<string, string> = {
    running: 'var(--accent)',
    pending: 'var(--accent)',
    completed: 'var(--success)',
    failed: 'var(--error)',
    interrupted: 'var(--warning)',
    cancelled: 'var(--fg-dim)',
  };

  function runForkHref(runId: string): string {
    return orchestrationUiRoutes.runFork(runId);
  }
</script>

<div class="run-detail">
  <div class="toolbar">
    <div class="toolbar-left">
      <a href={orchestrationUiRoutes.runs()} class="back-link">Runs</a>
      <span class="sep">/</span>
      <span class="run-id">{(id || '').slice(0, 8)}</span>
      {#if run}
        <span
          class="status-badge"
          style="--badge-color: {statusColors[run.status] || 'var(--fg-dim)'}"
        >{run.status}</span>
      {/if}
    </div>
    <div class="toolbar-actions">
      {#if isActive}
        <button class="tool-btn cancel" onclick={cancelRun}>Cancel</button>
      {/if}
      <a href={runForkHref(id)} class="tool-btn">Fork</a>
    </div>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if loading}
    <div class="loading">Loading run...</div>
  {:else if run}
    <div class="panels">
      <div class="panel-left">
        <GraphViewer {workflow} {nodeStatus} />
      </div>
      <div class="panel-right">
        <StateInspector currentState={run.state} {previousState} />
      </div>
    </div>
    <div class="panel-bottom">
      <RunEventLog {events} />
    </div>

    {#if isInterrupted}
      <InterruptPanel
        message={run.interrupt_message || ''}
        onResume={resumeRun}
        onCancel={cancelRun}
      />
    {/if}
  {/if}
</div>

<style>
  .run-detail {
    padding: 1.5rem;
    max-width: 1600px;
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: 1rem;
    height: calc(100vh - 3rem);
  }
  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.75rem 1rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    flex-shrink: 0;
  }
  .toolbar-left {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 0;
  }
  .back-link {
    font-size: 0.8125rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .back-link:hover {
    text-shadow: var(--text-glow);
  }
  .sep {
    color: var(--fg-dim);
    font-size: 0.8125rem;
  }
  .run-id {
    font-size: 0.875rem;
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--fg);
  }
  .toolbar-actions {
    display: flex;
    gap: 0.5rem;
  }
  .tool-btn {
    padding: 0.375rem 0.75rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
    text-decoration: none;
  }
  .tool-btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
    text-decoration: none;
  }
  .tool-btn.cancel {
    color: var(--error);
    border-color: color-mix(in srgb, var(--error) 40%, transparent);
    text-shadow: 0 0 4px var(--error);
  }
  .tool-btn.cancel:hover {
    border-color: var(--error);
    box-shadow: 0 0 8px color-mix(in srgb, var(--error) 30%, transparent);
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
  .panels {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
    flex: 1;
    min-height: 0;
  }
  .panel-left,
  .panel-right {
    min-height: 0;
    overflow: auto;
  }
  .panel-bottom {
    height: 250px;
    flex-shrink: 0;
  }
  .error-banner {
    padding: 0.75rem 1rem;
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid var(--error);
    border-radius: 4px;
    font-size: 0.875rem;
    font-weight: bold;
    text-shadow: 0 0 5px var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 20%, transparent);
    flex-shrink: 0;
  }
  .loading {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
  }
  @media (max-width: 900px) {
    .panels {
      grid-template-columns: 1fr;
    }
  }
</style>
