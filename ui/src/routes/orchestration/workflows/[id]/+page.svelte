<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';
  import GraphViewer from '$lib/components/orchestration/GraphViewer.svelte';
  import WorkflowJsonEditor from '$lib/components/orchestration/WorkflowJsonEditor.svelte';

  let id = $derived($page.params.id);
  let isNew = $derived(id === 'new');

  const emptyWorkflow = {
    id: '',
    name: '',
    state_schema: {},
    nodes: {},
    edges: [],
  };

  let jsonValue = $state(JSON.stringify(emptyWorkflow, null, 2));
  let parsedWorkflow = $state<any>(emptyWorkflow);
  let parseError = $state('');
  let loading = $state(true);
  let error = $state<string | null>(null);
  let saving = $state(false);
  let validating = $state(false);
  let validationResult = $state<{ valid: boolean; errors?: string[] } | null>(null);

  onMount(async () => {
    if (!isNew) {
      try {
        const wf = await api.getWorkflow(id);
        parsedWorkflow = wf;
        jsonValue = JSON.stringify(wf, null, 2);
        error = null;
      } catch (e) {
        error = (e as Error).message;
      }
    }
    loading = false;
  });

  function onJsonChange() {
    try {
      parsedWorkflow = JSON.parse(jsonValue);
      parseError = '';
    } catch (e) {
      parseError = (e as Error).message;
    }
  }

  $effect(() => {
    jsonValue;
    onJsonChange();
  });

  async function validate() {
    if (isNew) return;
    validating = true;
    validationResult = null;
    try {
      const result = await api.validateWorkflow(id);
      validationResult = result;
    } catch (e) {
      validationResult = { valid: false, errors: [(e as Error).message] };
    } finally {
      validating = false;
    }
  }

  async function save() {
    if (parseError) return;
    saving = true;
    error = null;
    try {
      if (isNew) {
        const result = await api.createWorkflow(parsedWorkflow);
        await goto(orchestrationUiRoutes.workflow(result.id || parsedWorkflow.id));
      } else {
        await api.updateWorkflow(id, parsedWorkflow);
      }
    } catch (e) {
      error = (e as Error).message;
    } finally {
      saving = false;
    }
  }

  async function run() {
    if (parseError || isNew) return;
    try {
      const result = await api.runWorkflow(id, {});
      if (result?.id) {
        await goto(orchestrationUiRoutes.run(result.id));
      }
    } catch (e) {
      error = (e as Error).message;
    }
  }
</script>

<div class="editor-page">
  <div class="toolbar">
    <div class="toolbar-left">
      <a href={orchestrationUiRoutes.workflows()} class="back-link">Workflows</a>
      <span class="sep">/</span>
      <span class="page-title">{isNew ? 'New Workflow' : (parsedWorkflow?.name || id)}</span>
    </div>
    <div class="toolbar-actions">
      {#if !isNew}
        <button class="tool-btn" onclick={validate} disabled={validating || !!parseError}>
          {validating ? 'Validating...' : 'Validate'}
        </button>
      {/if}
      <button class="tool-btn" onclick={save} disabled={saving || !!parseError}>
        {saving ? 'Saving...' : 'Save'}
      </button>
      {#if !isNew}
        <button class="tool-btn run" onclick={run} disabled={!!parseError}>Run</button>
      {/if}
    </div>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if validationResult}
    <div class="validation-result" class:valid={validationResult.valid} class:invalid={!validationResult.valid}>
      {#if validationResult.valid}
        Workflow is valid.
      {:else}
        <strong>Validation errors:</strong>
        {#each validationResult.errors || [] as err}
          <div class="val-err">{err}</div>
        {/each}
      {/if}
    </div>
  {/if}

  {#if loading}
    <div class="loading">Loading workflow...</div>
  {:else}
    <div class="editor-panels">
      <div class="panel-graph">
        <GraphViewer workflow={parsedWorkflow} nodeStatus={{}} />
      </div>
      <div class="panel-json">
        <WorkflowJsonEditor bind:value={jsonValue} onerror={(msg) => parseError = msg} />
      </div>
    </div>
  {/if}
</div>

<style>
  .editor-page {
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
  .page-title {
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
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
  }
  .tool-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }
  .tool-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .tool-btn.run {
    color: var(--success);
    border-color: color-mix(in srgb, var(--success) 40%, transparent);
    text-shadow: 0 0 4px var(--success);
  }
  .tool-btn.run:hover:not(:disabled) {
    border-color: var(--success);
    box-shadow: 0 0 8px color-mix(in srgb, var(--success) 30%, transparent);
  }
  .editor-panels {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
    flex: 1;
    min-height: 0;
  }
  .panel-graph {
    overflow: auto;
    min-height: 0;
  }
  .panel-json {
    display: flex;
    flex-direction: column;
    min-height: 0;
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
  }
  .validation-result {
    padding: 0.625rem 1rem;
    border-radius: 4px;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
  }
  .validation-result.valid {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    color: var(--success);
    border: 1px solid color-mix(in srgb, var(--success) 40%, transparent);
  }
  .validation-result.invalid {
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid color-mix(in srgb, var(--error) 40%, transparent);
  }
  .val-err {
    margin-top: 0.25rem;
    padding-left: 1rem;
  }
  .loading {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
  }
  @media (max-width: 900px) {
    .editor-panels {
      grid-template-columns: 1fr;
    }
  }
</style>
