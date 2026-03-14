<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { orchestrationUiRoutes } from '$lib/orchestration/routes';
  import CheckpointTimeline from '$lib/components/orchestration/CheckpointTimeline.svelte';
  import StateInspector from '$lib/components/orchestration/StateInspector.svelte';

  let runId = $derived($page.params.id);

  let checkpoints = $state<any[]>([]);
  let selectedCp = $state('');
  let selectedState = $state<any>(null);
  let overridesJson = $state('{}');
  let overridesValid = $state(true);
  let loading = $state(true);
  let forking = $state(false);
  let error = $state<string | null>(null);

  onMount(async () => {
    try {
      checkpoints = await api.listCheckpoints(runId) || [];
      if (checkpoints.length > 0) {
        selectCheckpoint(checkpoints[checkpoints.length - 1].id);
      }
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  });

  async function selectCheckpoint(cpId: string) {
    selectedCp = cpId;
    try {
      const cp = await api.getCheckpoint(runId, cpId);
      selectedState = cp?.state || cp;
    } catch (e) {
      error = (e as Error).message;
    }
  }

  function handleOverridesInput(e: Event) {
    overridesJson = (e.target as HTMLTextAreaElement).value;
    try {
      JSON.parse(overridesJson);
      overridesValid = true;
    } catch {
      overridesValid = false;
    }
  }

  async function forkRun() {
    if (!selectedCp || !overridesValid) return;
    forking = true;
    error = null;
    try {
      const overrides = JSON.parse(overridesJson);
      const result = await api.forkRun(selectedCp, Object.keys(overrides).length > 0 ? overrides : undefined);
      if (result?.id) {
        await goto(orchestrationUiRoutes.run(result.id));
      }
    } catch (e) {
      error = (e as Error).message;
    } finally {
      forking = false;
    }
  }

  function runHref(id: string): string {
    return orchestrationUiRoutes.run(id);
  }
</script>

<div class="fork-page">
  <div class="toolbar">
    <div class="toolbar-left">
      <a href={runHref(runId)} class="back-link">Run {(runId || '').slice(0, 8)}</a>
      <span class="sep">/</span>
      <span class="page-title">Fork</span>
    </div>
    <div class="toolbar-actions">
      <button
        class="fork-btn"
        onclick={forkRun}
        disabled={!selectedCp || !overridesValid || forking}
      >
        {forking ? 'Forking...' : 'Fork Run'}
      </button>
    </div>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if loading}
    <div class="loading">Loading checkpoints...</div>
  {:else}
    <div class="fork-panels">
      <div class="panel-timeline">
        <div class="panel-label">Checkpoints</div>
        <CheckpointTimeline
          {checkpoints}
          selected={selectedCp}
          onSelect={selectCheckpoint}
        />
      </div>
      <div class="panel-state">
        <div class="state-top">
          <StateInspector currentState={selectedState} />
        </div>
        <div class="state-bottom">
          <label class="override-label" for="overrides">State Overrides (JSON)</label>
          <textarea
            id="overrides"
            class="override-editor"
            class:invalid={!overridesValid}
            spellcheck="false"
            value={overridesJson}
            oninput={handleOverridesInput}
          ></textarea>
          {#if !overridesValid}
            <span class="json-err">Invalid JSON</span>
          {/if}
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .fork-page {
    padding: 1.5rem;
    max-width: 1400px;
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
  }
  .toolbar-actions {
    display: flex;
    gap: 0.5rem;
  }
  .fork-btn {
    padding: 0.5rem 1rem;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .fork-btn:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .fork-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .fork-panels {
    display: grid;
    grid-template-columns: 280px 1fr;
    gap: 1rem;
    flex: 1;
    min-height: 0;
  }
  .panel-timeline {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    overflow-y: auto;
  }
  .panel-label {
    padding: 0.625rem 1rem;
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--accent);
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  }
  .panel-state {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    min-height: 0;
  }
  .state-top {
    flex: 1;
    min-height: 0;
    overflow: auto;
  }
  .state-bottom {
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    flex-shrink: 0;
  }
  .override-label {
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
  }
  .override-editor {
    width: 100%;
    min-height: 120px;
    padding: 0.75rem;
    background: var(--bg-surface);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.5;
    resize: vertical;
    outline: none;
  }
  .override-editor:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 6px var(--border-glow);
  }
  .override-editor.invalid {
    border-color: var(--error);
    box-shadow: 0 0 6px color-mix(in srgb, var(--error) 30%, transparent);
  }
  .json-err {
    font-size: 0.6875rem;
    color: var(--error);
    font-family: var(--font-mono);
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
    .fork-panels {
      grid-template-columns: 1fr;
    }
  }
</style>
