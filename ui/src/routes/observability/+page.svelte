<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import { api } from '$lib/api/client';

  let summary = $state<any>(null);
  let runs = $state<any[]>([]);
  let selectedRunId = $state('');
  let selectedRun = $state<any>(null);
  let loading = $state(true);
  let loadingRun = $state(false);
  let error = $state<string | null>(null);
  let pollInterval: ReturnType<typeof setInterval> | null = null;

  const selectedSummary = $derived(selectedRun?.summary || null);
  const sortedSpans = $derived(
    (selectedRun?.spans || []).slice().sort((a: any, b: any) => (a.started_at_ms || 0) - (b.started_at_ms || 0)),
  );
  const sortedEvals = $derived(
    (selectedRun?.evals || []).slice().sort((a: any, b: any) => (a.recorded_at_ms || 0) - (b.recorded_at_ms || 0)),
  );

  async function loadOverview() {
    try {
      const [summaryResult, runsResult] = await Promise.all([
        api.getObservabilitySummary(),
        api.getObservabilityRuns({ limit: 50 }),
      ]);
      summary = summaryResult;
      runs = runsResult?.items || [];
      error = null;

      if (!selectedRunId && runs.length > 0) {
        await selectRun(runs[0].run_id);
      } else if (selectedRunId) {
        await loadRun(selectedRunId, false);
      }
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function loadRun(runId: string, showSpinner = true) {
    if (showSpinner) loadingRun = true;
    try {
      selectedRun = await api.getObservabilityRun(runId);
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loadingRun = false;
    }
  }

  async function selectRun(runId: string) {
    selectedRunId = runId;
    await loadRun(runId);
  }

  onMount(() => {
    void loadOverview();
    pollInterval = setInterval(loadOverview, 5000);
  });

  onDestroy(() => {
    if (pollInterval) clearInterval(pollInterval);
  });

  function formatDuration(ms: number | undefined | null): string {
    if (ms == null) return '-';
    if (ms < 1000) return `${Math.round(ms)}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    return `${Math.floor(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
  }

  function formatCost(cost: number | undefined | null): string {
    if (cost == null || cost === 0) return '$0.0000';
    return `$${cost.toFixed(4)}`;
  }

  function formatTime(ms: number | undefined | null): string {
    if (!ms) return '-';
    return new Date(ms).toLocaleString();
  }

  function formatTokens(input: number | undefined | null, output: number | undefined | null): string {
    const total = (input || 0) + (output || 0);
    return total > 0 ? total.toLocaleString() : '-';
  }

  function verdictClass(verdict: string | undefined): string {
    if (verdict === 'pass') return 'pass';
    if (verdict === 'fail') return 'fail';
    return 'neutral';
  }

  function statusClass(status: string | undefined): string {
    if (status === 'ok') return 'pass';
    if (status === 'error') return 'fail';
    return 'neutral';
  }
</script>

<div class="flight-recorder">
  <div class="header">
    <div>
      <h1>Flight Recorder</h1>
      <p class="subtitle">NullWatch traces, evals, cost, and failure context</p>
    </div>
    <button class="action-btn" onclick={loadOverview}>Refresh</button>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  <div class="metric-grid">
    <div class="metric">
      <span class="label">Runs</span>
      <strong>{summary?.run_count ?? 0}</strong>
    </div>
    <div class="metric">
      <span class="label">Spans</span>
      <strong>{summary?.span_count ?? 0}</strong>
    </div>
    <div class="metric">
      <span class="label">Errors</span>
      <strong class:bad={(summary?.error_count || 0) > 0}>{summary?.error_count ?? 0}</strong>
    </div>
    <div class="metric">
      <span class="label">Eval Pass</span>
      <strong>{summary?.pass_count ?? 0}</strong>
    </div>
    <div class="metric">
      <span class="label">Eval Fail</span>
      <strong class:bad={(summary?.fail_count || 0) > 0}>{summary?.fail_count ?? 0}</strong>
    </div>
    <div class="metric">
      <span class="label">Cost</span>
      <strong>{formatCost(summary?.total_cost_usd)}</strong>
    </div>
  </div>

  {#if loading && runs.length === 0}
    <div class="loading">Loading observability data...</div>
  {:else}
    <div class="workspace">
      <section class="runs-panel">
        <div class="panel-title">
          <h2>Runs</h2>
          <span>{runs.length}</span>
        </div>
        {#if runs.length === 0}
          <div class="empty-state">No NullWatch runs found.</div>
        {:else}
          <div class="run-list">
            {#each runs as run}
              <button
                class="run-row"
                class:selected={selectedRunId === run.run_id}
                onclick={() => selectRun(run.run_id)}
              >
                <span class="run-main">
                  <span class="mono">{run.run_id}</span>
                  <span class="muted">{formatDuration(run.total_duration_ms)} · {formatTokens(run.total_input_tokens, run.total_output_tokens)} tokens</span>
                </span>
                <span class="pill {verdictClass(run.overall_verdict)}">{run.overall_verdict}</span>
              </button>
            {/each}
          </div>
        {/if}
      </section>

      <section class="detail-panel">
        {#if loadingRun}
          <div class="loading">Loading run detail...</div>
        {:else if selectedRun}
          <div class="detail-header">
            <div>
              <h2>{selectedSummary?.run_id}</h2>
              <div class="detail-meta">
                <span>{formatTime(selectedSummary?.first_seen_ms)}</span>
                <span>{formatDuration(selectedSummary?.total_duration_ms)}</span>
                <span>{formatCost(selectedSummary?.total_cost_usd)}</span>
              </div>
            </div>
            <span class="pill {verdictClass(selectedSummary?.overall_verdict)}">{selectedSummary?.overall_verdict}</span>
          </div>

          <div class="detail-stats">
            <div><span>Spans</span><strong>{selectedSummary?.span_count || 0}</strong></div>
            <div><span>Errors</span><strong>{selectedSummary?.error_count || 0}</strong></div>
            <div><span>Evals</span><strong>{selectedSummary?.eval_count || 0}</strong></div>
            <div><span>Tokens</span><strong>{formatTokens(selectedSummary?.total_input_tokens, selectedSummary?.total_output_tokens)}</strong></div>
          </div>

          <div class="section-title">Span Timeline</div>
          <div class="timeline">
            {#each sortedSpans as span}
              <div class="span-row">
                <div class="span-marker {statusClass(span.status)}"></div>
                <div class="span-body">
                  <div class="span-top">
                    <span class="mono">{span.operation}</span>
                    <span class="pill {statusClass(span.status)}">{span.status}</span>
                  </div>
                  <div class="span-meta">
                    <span>{span.source}</span>
                    {#if span.agent_id}<span>{span.agent_id}</span>{/if}
                    {#if span.tool_name}<span>{span.tool_name}</span>{/if}
                    {#if span.model}<span>{span.model}</span>{/if}
                    <span>{formatDuration(span.duration_ms)}</span>
                  </div>
                  {#if span.error_message}
                    <div class="span-error">{span.error_message}</div>
                  {/if}
                  {#if span.attributes_json}
                    <pre>{span.attributes_json}</pre>
                  {/if}
                </div>
              </div>
            {/each}
          </div>

          <div class="section-title">Evals</div>
          {#if sortedEvals.length === 0}
            <div class="empty-state">No evals attached to this run.</div>
          {:else}
            <div class="eval-list">
              {#each sortedEvals as evaluation}
                <div class="eval-row">
                  <div>
                    <span class="mono">{evaluation.eval_key}</span>
                    <span class="muted">{evaluation.scorer} · {evaluation.dataset || '-'}</span>
                  </div>
                  <div class="eval-score">
                    <span>{evaluation.score.toFixed(2)}</span>
                    <span class="pill {verdictClass(evaluation.verdict)}">{evaluation.verdict}</span>
                  </div>
                  {#if evaluation.notes}
                    <p>{evaluation.notes}</p>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}
        {:else}
          <div class="empty-state">Select a run.</div>
        {/if}
      </section>
    </div>
  {/if}
</div>

<style>
  .flight-recorder {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    max-width: 1600px;
    margin: 0 auto;
  }

  .header,
  .detail-header,
  .panel-title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
  }

  h1,
  h2 {
    margin: 0;
    letter-spacing: 0;
  }

  h1 {
    font-size: 1.75rem;
    color: var(--fg);
  }

  h2 {
    font-size: 1rem;
    color: var(--accent);
  }

  .subtitle,
  .muted,
  .detail-meta,
  .span-meta {
    color: var(--fg-muted);
    font-size: 0.8125rem;
  }

  .subtitle {
    margin: 0.25rem 0 0;
  }

  .action-btn {
    padding: 0.5rem 0.85rem;
    background: var(--bg-surface);
    border: 1px solid var(--accent-dim);
    color: var(--accent);
    border-radius: 4px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    cursor: pointer;
  }

  .action-btn:hover {
    border-color: var(--accent);
    background: var(--bg-hover);
  }

  .error-banner {
    padding: 0.75rem 1rem;
    border: 1px solid var(--error);
    color: var(--error);
    background: color-mix(in srgb, var(--error) 10%, transparent);
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  .metric-grid {
    display: grid;
    grid-template-columns: repeat(6, minmax(0, 1fr));
    gap: 0.75rem;
  }

  .metric {
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
    padding: 0.85rem;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .label {
    color: var(--fg-muted);
    font-size: 0.7rem;
    text-transform: uppercase;
    font-weight: 700;
  }

  .metric strong {
    color: var(--fg);
    font-size: 1.35rem;
  }

  .metric strong.bad {
    color: var(--error);
  }

  .workspace {
    display: grid;
    grid-template-columns: minmax(280px, 390px) minmax(0, 1fr);
    gap: 1rem;
    align-items: start;
  }

  .runs-panel,
  .detail-panel {
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
    min-width: 0;
  }

  .runs-panel {
    overflow: hidden;
  }

  .detail-panel {
    padding: 1rem;
  }

  .panel-title {
    padding: 0.9rem 1rem;
    border-bottom: 1px solid var(--border);
  }

  .panel-title span {
    color: var(--fg-muted);
    font-family: var(--font-mono);
  }

  .run-list {
    display: flex;
    flex-direction: column;
  }

  .run-row {
    width: 100%;
    border: 0;
    border-bottom: 1px solid var(--border);
    background: transparent;
    color: var(--fg);
    padding: 0.85rem 1rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    text-align: left;
    cursor: pointer;
  }

  .run-row:hover,
  .run-row.selected {
    background: var(--bg-hover);
  }

  .run-main {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  .mono {
    font-family: var(--font-mono);
    overflow-wrap: anywhere;
  }

  .pill {
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 0.15rem 0.45rem;
    font-size: 0.7rem;
    font-weight: 700;
    text-transform: uppercase;
    white-space: nowrap;
  }

  .pill.pass {
    color: var(--success);
    border-color: var(--success);
  }

  .pill.fail {
    color: var(--error);
    border-color: var(--error);
  }

  .pill.neutral {
    color: var(--fg-muted);
  }

  .detail-meta,
  .span-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 0.3rem;
  }

  .detail-stats {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.5rem;
    margin: 1rem 0;
  }

  .detail-stats div {
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0.65rem;
    display: flex;
    justify-content: space-between;
    gap: 0.5rem;
  }

  .detail-stats span {
    color: var(--fg-muted);
    font-size: 0.75rem;
  }

  .section-title {
    margin: 1rem 0 0.6rem;
    color: var(--fg);
    font-size: 0.8rem;
    text-transform: uppercase;
    font-weight: 700;
  }

  .timeline {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
  }

  .span-row {
    display: grid;
    grid-template-columns: 12px minmax(0, 1fr);
    gap: 0.75rem;
  }

  .span-marker {
    margin-top: 0.45rem;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    border: 1px solid var(--fg-muted);
  }

  .span-marker.pass {
    border-color: var(--success);
    background: var(--success);
  }

  .span-marker.fail {
    border-color: var(--error);
    background: var(--error);
  }

  .span-body,
  .eval-row {
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0.75rem;
    background: var(--bg);
    min-width: 0;
  }

  .span-top,
  .eval-row {
    display: flex;
    justify-content: space-between;
    gap: 0.75rem;
  }

  .span-error {
    margin-top: 0.55rem;
    color: var(--error);
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  pre {
    margin: 0.55rem 0 0;
    padding: 0.6rem;
    overflow-x: auto;
    border-radius: 4px;
    background: var(--bg-surface);
    color: var(--fg-muted);
    font-size: 0.75rem;
  }

  .eval-list {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
  }

  .eval-row {
    flex-direction: column;
  }

  .eval-score {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
  }

  .eval-row p {
    margin: 0;
    color: var(--fg-muted);
    font-size: 0.8125rem;
  }

  .loading,
  .empty-state {
    padding: 1rem;
    color: var(--fg-muted);
    font-family: var(--font-mono);
  }

  @media (max-width: 1100px) {
    .metric-grid {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .workspace {
      grid-template-columns: 1fr;
    }
  }

  @media (max-width: 680px) {
    .metric-grid,
    .detail-stats {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    .header,
    .detail-header {
      align-items: flex-start;
      flex-direction: column;
    }
  }
</style>
