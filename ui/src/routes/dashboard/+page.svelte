<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';

  type WindowOption = '24h' | '7d' | '30d' | 'all';

  let selectedWindow = $state<WindowOption>('7d');
  let data = $state<any>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let hoveredPoint = $state<number | null>(null);
  let requestSequence = 0;

  const windowLabels: Record<WindowOption, string> = {
    '24h': '24 Hours',
    '7d': '7 Days',
    '30d': '30 Days',
    'all': 'All Time'
  };

  function emptyUsageData(window: WindowOption) {
    return {
      window,
      generated_at: Math.floor(Date.now() / 1000),
      totals: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        requests: 0
      },
      by_model: [],
      by_instance: [],
      timeseries: []
    };
  }

  async function loadData(window: WindowOption = selectedWindow) {
    const requestId = ++requestSequence;
    loading = true;
    error = null;
    try {
      const nextData = await api.getGlobalUsage(window);
      if (requestId !== requestSequence) return;
      data = nextData;
    } catch (e) {
      if (requestId !== requestSequence) return;
      const message = (e as Error).message;
      if (message === 'not found' || message === 'HTTP 404') {
        data = emptyUsageData(window);
        error = null;
        return;
      }
      error = message;
    } finally {
      if (requestId !== requestSequence) return;
      loading = false;
    }
  }

  function changeWindow(w: WindowOption) {
    if (selectedWindow === w) return;
    selectedWindow = w;
    hoveredPoint = null;
    void loadData(w);
  }

  onMount(() => { void loadData(); });

  let activeModels = $derived(data?.by_model?.length ?? 0);
  let activeBots = $derived(data?.by_instance?.filter((i: any) => i.total_tokens > 0)?.length ?? 0);
  let sortedModels = $derived(
    [...(data?.by_model ?? [])].sort((a: any, b: any) => b.total_tokens - a.total_tokens)
  );
  let sortedInstances = $derived(
    [...(data?.by_instance ?? [])].sort((a: any, b: any) => b.total_tokens - a.total_tokens)
  );

  // SVG area chart helpers
  const chartW = 800;
  const chartH = 250;
  const padL = 60;
  const padR = 20;
  const padT = 20;
  const padB = 30;
  const plotW = chartW - padL - padR;
  const plotH = chartH - padT - padB;

  let maxY = $derived(() => {
    if (!data?.timeseries?.length) return 1;
    return Math.max(...data.timeseries.map((d: any) => d.prompt_tokens + d.completion_tokens), 1);
  });

  function areaPath(accessor: (d: any) => number, baseline: (d: any) => number): string {
    const ts = data?.timeseries;
    if (!ts?.length) return '';
    const n = ts.length;
    const my = maxY();
    const xStep = plotW / Math.max(n - 1, 1);

    let path = `M ${padL},${padT + plotH - (baseline(ts[0]) / my) * plotH}`;
    for (let i = 0; i < n; i++) {
      const x = padL + i * xStep;
      const y = padT + plotH - ((baseline(ts[i]) + accessor(ts[i])) / my) * plotH;
      path += ` L ${x},${y}`;
    }
    // Close back along baseline
    for (let i = n - 1; i >= 0; i--) {
      const x = padL + i * xStep;
      const y = padT + plotH - (baseline(ts[i]) / my) * plotH;
      path += ` L ${x},${y}`;
    }
    path += ' Z';
    return path;
  }

  let promptAreaPath = $derived(
    areaPath((d) => d.prompt_tokens, () => 0)
  );
  let completionAreaPath = $derived(
    areaPath((d) => d.completion_tokens, (d) => d.prompt_tokens)
  );

  function yTicks(): { value: number; label: string }[] {
    const my = maxY();
    const count = 5;
    const step = my / count;
    return Array.from({ length: count + 1 }, (_, i) => ({
      value: i * step,
      label: formatNumber(i * step)
    }));
  }

  function xTicks(): { x: number; label: string }[] {
    const ts = data?.timeseries;
    if (!ts?.length) return [];
    const n = ts.length;
    const xStep = plotW / Math.max(n - 1, 1);
    const tickCount = Math.min(6, n);
    const every = Math.max(1, Math.floor(n / tickCount));
    const ticks: { x: number; label: string }[] = [];
    for (let i = 0; i < n; i += every) {
      ticks.push({ x: padL + i * xStep, label: formatDate(ts[i].bucket_start) });
    }
    return ticks;
  }

  function formatNumber(n: number): string {
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
    if (n >= 1_000) return (n / 1_000).toFixed(1) + 'K';
    return n.toLocaleString();
  }

  function formatTimestamp(ts: number): string {
    return new Date(ts * 1000).toLocaleString();
  }

  function formatDate(ts: number): string {
    const d = new Date(ts * 1000);
    if (selectedWindow === '24h') return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }

  function onChartHover(e: MouseEvent) {
    const svg = (e.currentTarget as SVGElement);
    const rect = svg.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const ts = data?.timeseries;
    if (!ts?.length) return;
    const n = ts.length;
    const xStep = (plotW * rect.width / chartW) / Math.max(n - 1, 1);
    const startX = padL * rect.width / chartW;
    const idx = Math.round((mouseX - startX) / xStep);
    hoveredPoint = Math.max(0, Math.min(n - 1, idx));
  }

  function onChartLeave() {
    hoveredPoint = null;
  }
</script>

<div class="dashboard">
  <div class="header">
    <h1>Dashboard</h1>
    <div class="window-selector">
      {#each Object.entries(windowLabels) as [value, label]}
        <button
          class:active={selectedWindow === value}
          onclick={() => changeWindow(value as WindowOption)}
        >{label}</button>
      {/each}
    </div>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if loading && !data}
    <div class="loading">Loading usage data...</div>
  {:else if data}
    <!-- Summary Cards -->
    <div class="cards">
      <div class="card">
        <div class="card-label">Total Tokens</div>
        <div class="card-value">{formatNumber(data.totals.total_tokens)}</div>
        <div class="card-sub">
          <span class="prompt">{formatNumber(data.totals.prompt_tokens)} in</span>
          <span class="completion">{formatNumber(data.totals.completion_tokens)} out</span>
        </div>
      </div>
      <div class="card">
        <div class="card-label">Requests</div>
        <div class="card-value">{formatNumber(data.totals.requests)}</div>
      </div>
      <div class="card">
        <div class="card-label">Active Models</div>
        <div class="card-value">{activeModels}</div>
      </div>
      <div class="card">
        <div class="card-label">Active Bots</div>
        <div class="card-value">{activeBots}</div>
      </div>
    </div>

    <!-- Token Usage Over Time -->
    {#if data.timeseries.length > 0}
      <div class="chart-section">
        <h2>Token Usage Over Time</h2>
        <div class="chart-container">
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <svg
            viewBox="0 0 {chartW} {chartH}"
            class="area-chart"
            onmousemove={onChartHover}
            onmouseleave={onChartLeave}
          >
            <!-- Grid lines -->
            {#each yTicks() as tick}
              {@const y = padT + plotH - (tick.value / maxY()) * plotH}
              <line x1={padL} y1={y} x2={chartW - padR} y2={y} class="grid-line" />
              <text x={padL - 8} y={y + 4} class="y-label">{tick.label}</text>
            {/each}

            <!-- Areas -->
            <path d={promptAreaPath} class="area-prompt" />
            <path d={completionAreaPath} class="area-completion" />

            <!-- X axis labels -->
            {#each xTicks() as tick}
              <text x={tick.x} y={chartH - 5} class="x-label">{tick.label}</text>
            {/each}

            <!-- Hover indicator -->
            {#if hoveredPoint !== null && data.timeseries[hoveredPoint]}
              {@const n = data.timeseries.length}
              {@const xStep = plotW / Math.max(n - 1, 1)}
              {@const hx = padL + hoveredPoint * xStep}
              <line x1={hx} y1={padT} x2={hx} y2={padT + plotH} class="hover-line" />
            {/if}
          </svg>

          <!-- Tooltip -->
          {#if hoveredPoint !== null && data.timeseries[hoveredPoint]}
            {@const pt = data.timeseries[hoveredPoint]}
            <div class="chart-tooltip">
              <div class="tt-date">{formatDate(pt.bucket_start)}</div>
              <div class="tt-row"><span class="dot" style="background:#00d4ff"></span> Prompt: {formatNumber(pt.prompt_tokens)}</div>
              <div class="tt-row"><span class="dot" style="background:#7b61ff"></span> Completion: {formatNumber(pt.completion_tokens)}</div>
              <div class="tt-row">Requests: {pt.requests.toLocaleString()}</div>
            </div>
          {/if}

          <div class="legend">
            <span class="legend-item"><span class="dot" style="background: #00d4ff"></span> Prompt</span>
            <span class="legend-item"><span class="dot" style="background: #7b61ff"></span> Completion</span>
          </div>
        </div>
      </div>
    {/if}

    <!-- Bar Charts Row -->
    <div class="chart-row">
      {#if sortedModels.length > 0}
        <div class="chart-section half">
          <h2>Tokens by Model</h2>
          <div class="bar-list">
            {#each sortedModels.slice(0, 10) as item}
              {@const maxTokens = sortedModels[0]?.total_tokens || 1}
              <div class="bar-item">
                <div class="bar-label" title="{item.provider}/{item.model}">
                  {item.model}
                </div>
                <div class="bar-track">
                  <div class="bar-fill prompt" style="width: {(item.prompt_tokens / maxTokens) * 100}%"></div>
                  <div class="bar-fill completion" style="width: {(item.completion_tokens / maxTokens) * 100}%"></div>
                </div>
                <div class="bar-value">{formatNumber(item.total_tokens)}</div>
              </div>
            {/each}
          </div>
        </div>
      {/if}

      {#if sortedInstances.length > 0}
        <div class="chart-section half">
          <h2>Tokens by Bot</h2>
          <div class="bar-list">
            {#each sortedInstances.slice(0, 10) as item}
              {@const maxTokens = sortedInstances[0]?.total_tokens || 1}
              <div class="bar-item">
                <div class="bar-label" title="{item.component}/{item.name}">
                  {item.component}/{item.name}
                </div>
                <div class="bar-track">
                  <div class="bar-fill prompt" style="width: {(item.prompt_tokens / maxTokens) * 100}%"></div>
                  <div class="bar-fill completion" style="width: {(item.completion_tokens / maxTokens) * 100}%"></div>
                </div>
                <div class="bar-value">{formatNumber(item.total_tokens)}</div>
              </div>
            {/each}
          </div>
        </div>
      {/if}
    </div>

    <!-- Detail Table -->
    {#if sortedModels.length > 0}
      <div class="chart-section">
        <h2>Usage Details</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Provider</th>
                <th>Model</th>
                <th>Prompt Tokens</th>
                <th>Completion Tokens</th>
                <th>Total</th>
                <th>Requests</th>
                <th>Last Used</th>
              </tr>
            </thead>
            <tbody>
              {#each sortedModels as row}
                <tr>
                  <td>{row.provider}</td>
                  <td>{row.model}</td>
                  <td class="num">{row.prompt_tokens.toLocaleString()}</td>
                  <td class="num">{row.completion_tokens.toLocaleString()}</td>
                  <td class="num">{row.total_tokens.toLocaleString()}</td>
                  <td class="num">{row.requests.toLocaleString()}</td>
                  <td>{formatTimestamp(row.last_used)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      </div>
    {/if}

    {#if !data.by_model?.length && !data.by_instance?.length}
      <div class="empty-state">
        <p>> No usage data recorded yet.</p>
        <p>Token usage will appear here once your bots start processing requests.</p>
      </div>
    {/if}
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
  .window-selector {
    display: flex;
    gap: 0.25rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0.25rem;
  }
  .window-selector button {
    padding: 0.375rem 0.75rem;
    background: transparent;
    color: var(--fg-dim);
    border: 1px solid transparent;
    border-radius: 3px;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .window-selector button:hover {
    color: var(--fg);
    background: var(--bg-hover);
  }
  .window-selector button.active {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border-color: var(--accent-dim);
    text-shadow: var(--text-glow);
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
    color: var(--accent);
    text-shadow: var(--text-glow);
    font-family: var(--font-mono);
  }
  .card-sub {
    margin-top: 0.375rem;
    font-size: 0.75rem;
    display: flex;
    gap: 0.75rem;
  }
  .card-sub .prompt { color: #00d4ff; }
  .card-sub .completion { color: #7b61ff; }

  .chart-section {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
  }
  .chart-container {
    position: relative;
  }
  .area-chart {
    width: 100%;
    height: auto;
  }
  .area-chart :global(.grid-line) {
    stroke: var(--border);
    stroke-width: 0.5;
    stroke-dasharray: 4 4;
  }
  .area-chart :global(.y-label) {
    fill: var(--fg-dim);
    font-size: 10px;
    text-anchor: end;
    font-family: var(--font-mono);
  }
  .area-chart :global(.x-label) {
    fill: var(--fg-dim);
    font-size: 10px;
    text-anchor: middle;
    font-family: var(--font-mono);
  }
  .area-chart :global(.area-prompt) {
    fill: #00d4ff;
    opacity: 0.6;
  }
  .area-chart :global(.area-completion) {
    fill: #7b61ff;
    opacity: 0.6;
  }
  .area-chart :global(.hover-line) {
    stroke: var(--accent);
    stroke-width: 1;
    stroke-dasharray: 3 3;
    opacity: 0.8;
  }

  .chart-tooltip {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0.5rem 0.75rem;
    font-size: 0.75rem;
    pointer-events: none;
    z-index: 10;
  }
  .tt-date {
    font-weight: 700;
    color: var(--fg);
    margin-bottom: 0.25rem;
  }
  .tt-row {
    color: var(--fg-dim);
    display: flex;
    align-items: center;
    gap: 0.375rem;
  }

  .legend {
    display: flex;
    gap: 1.5rem;
    justify-content: center;
    margin-top: 0.75rem;
    font-size: 0.75rem;
    color: var(--fg-dim);
  }
  .legend-item {
    display: flex;
    align-items: center;
    gap: 0.375rem;
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    display: inline-block;
  }
  .chart-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5rem;
  }
  .chart-section.half {
    margin-bottom: 1.5rem;
  }

  .bar-list {
    display: flex;
    flex-direction: column;
    gap: 0.625rem;
  }
  .bar-item {
    display: grid;
    grid-template-columns: 140px 1fr 70px;
    align-items: center;
    gap: 0.75rem;
  }
  .bar-label {
    font-size: 0.75rem;
    color: var(--fg-dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .bar-track {
    height: 20px;
    background: var(--bg-hover);
    border-radius: 2px;
    display: flex;
    overflow: hidden;
  }
  .bar-fill.prompt {
    background: #00d4ff;
    height: 100%;
    transition: width 0.3s ease;
  }
  .bar-fill.completion {
    background: #7b61ff;
    height: 100%;
    transition: width 0.3s ease;
  }
  .bar-value {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--fg);
    text-align: right;
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
  td.num {
    font-family: var(--font-mono);
    text-align: right;
  }
  tr:hover td {
    background: var(--bg-hover);
  }

  .loading {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
    font-size: 1rem;
  }
  .error-banner {
    padding: 0.75rem 1rem;
    background: rgba(255, 0, 0, 0.1);
    color: var(--error);
    border: 1px solid var(--error);
    border-radius: 4px;
    margin-bottom: 1.5rem;
    font-size: 0.875rem;
    font-weight: bold;
    text-shadow: 0 0 5px var(--error);
    box-shadow: 0 0 10px rgba(255, 0, 0, 0.2);
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
    margin-bottom: 0.75rem;
    font-family: var(--font-mono);
  }

  @media (max-width: 900px) {
    .cards { grid-template-columns: repeat(2, 1fr); }
    .chart-row { grid-template-columns: 1fr; }
  }
</style>
