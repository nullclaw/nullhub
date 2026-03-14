<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';

  let workflows = $state<any[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let deleteConfirm = $state<string | null>(null);

  async function loadWorkflows() {
    try {
      workflows = await api.listWorkflows() || [];
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  onMount(() => { void loadWorkflows(); });

  async function deleteWorkflow(id: string) {
    try {
      await api.deleteWorkflow(id);
      deleteConfirm = null;
      await loadWorkflows();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  function nodeCount(wf: any): number {
    if (!wf.nodes) return 0;
    return Object.keys(wf.nodes).length;
  }

  function workflowHref(id: string): string {
    return orchestrationUiRoutes.workflow(id);
  }
</script>

<div class="page">
  <div class="header">
    <h1>Workflows</h1>
    <a href={orchestrationUiRoutes.newWorkflow()} class="action-btn">+ New Workflow</a>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if loading}
    <div class="loading">Loading workflows...</div>
  {:else if workflows.length === 0}
    <div class="empty-state">
      <p>> No workflows defined yet.</p>
      <a href={orchestrationUiRoutes.newWorkflow()} class="btn">Create Workflow</a>
    </div>
  {:else}
    <div class="workflow-grid">
      {#each workflows as wf}
        <div class="wf-card">
          <div class="wf-header">
            <span class="wf-name">{wf.name || wf.id}</span>
            <span class="wf-nodes">{nodeCount(wf)} nodes</span>
          </div>
          {#if wf.id}
            <div class="wf-id">{wf.id}</div>
          {/if}
          <div class="wf-actions">
            <a href={workflowHref(wf.id)} class="btn-edit">Edit</a>
            <button class="btn-run" onclick={() => goto(workflowHref(wf.id))}>Run</button>
            {#if deleteConfirm === wf.id}
              <button class="btn-confirm-delete" onclick={() => deleteWorkflow(wf.id)}>Confirm</button>
              <button class="btn-cancel" onclick={() => deleteConfirm = null}>Cancel</button>
            {:else}
              <button class="btn-delete" onclick={() => deleteConfirm = wf.id}>Delete</button>
            {/if}
          </div>
        </div>
      {/each}
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
  .workflow-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 1.5rem;
  }
  .wf-card {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    transition: all 0.2s ease;
  }
  .wf-card:hover {
    border-color: var(--accent-dim);
    box-shadow: 0 0 12px var(--border-glow);
  }
  .wf-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 0.5rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  }
  .wf-name {
    font-weight: 700;
    font-size: 1.125rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }
  .wf-nodes {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--fg-dim);
    padding: 0.2rem 0.5rem;
    background: color-mix(in srgb, var(--border) 20%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
  }
  .wf-id {
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: var(--fg-dim);
    opacity: 0.7;
  }
  .wf-actions {
    display: flex;
    gap: 0.5rem;
    margin-top: 0.25rem;
  }
  .btn-edit,
  .btn-run,
  .btn-delete,
  .btn-confirm-delete,
  .btn-cancel {
    padding: 0.375rem 0.75rem;
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .btn-edit {
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    text-shadow: var(--text-glow);
  }
  .btn-edit:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }
  .btn-run {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    color: var(--success);
    border: 1px solid color-mix(in srgb, var(--success) 40%, transparent);
  }
  .btn-run:hover {
    background: color-mix(in srgb, var(--success) 20%, transparent);
    border-color: var(--success);
    box-shadow: 0 0 8px color-mix(in srgb, var(--success) 30%, transparent);
  }
  .btn-delete {
    background: transparent;
    color: var(--fg-dim);
    border: 1px solid var(--border);
    margin-left: auto;
  }
  .btn-delete:hover {
    color: var(--error);
    border-color: var(--error);
    background: color-mix(in srgb, var(--error) 10%, transparent);
  }
  .btn-confirm-delete {
    background: color-mix(in srgb, var(--error) 15%, transparent);
    color: var(--error);
    border: 1px solid var(--error);
    margin-left: auto;
    text-shadow: 0 0 4px var(--error);
  }
  .btn-cancel {
    background: transparent;
    color: var(--fg-dim);
    border: 1px solid var(--border);
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
</style>
