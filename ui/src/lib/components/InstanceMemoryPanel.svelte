<script lang="ts">
  import { api } from "$lib/api/client";
  import {
    describeInstanceCliError,
    isInstanceCliError,
  } from "$lib/instanceCli";

  type MemoryStats = {
    backend?: string;
    retrieval?: string;
    vector?: string;
    embedding?: string;
    rollout?: string;
    sync?: string;
    fallback?: string;
    sources?: number;
    entries?: number;
    vector_entries?: number | null;
    outbox_pending?: number | null;
  };

  type MemoryEntry = {
    key: string;
    category: string;
    timestamp: string;
    content: string;
    session_id?: string | null;
  };

  type MemorySearchResult = {
    key: string;
    category: string;
    snippet: string;
    source: string;
    source_path: string;
    final_score: number;
    start_line: number;
    end_line: number;
    created_at: number;
    keyword_rank?: number | null;
    vector_score?: number | null;
  };

  let { component, name, active = false } = $props<{
    component: string;
    name: string;
    active?: boolean;
  }>();

  let stats = $state<MemoryStats | null>(null);
  let statsLoading = $state(false);
  let statsError = $state<string | null>(null);
  let loadedStatsKey = $state("");

  let entries = $state<MemoryEntry[]>([]);
  let entriesLoading = $state(false);
  let entriesError = $state<string | null>(null);
  let category = $state("conversation");
  let limit = $state("50");
  let loadedEntriesKey = $state("");

  let searchQuery = $state("");
  let searchResults = $state<MemorySearchResult[]>([]);
  let searchLoading = $state(false);
  let searchError = $state<string | null>(null);
  let searchSubmittedQuery = $state("");
  let searchContextKey = $state("");

  const instanceKey = $derived(`${component}/${name}`);
  let statsRequestSeq = 0;
  let entriesRequestSeq = 0;
  let searchRequestSeq = 0;

  function formatSearchTimestamp(epochSeconds: number): string {
    if (!epochSeconds) return "-";
    const date = new Date(epochSeconds * 1000);
    return Number.isNaN(date.getTime()) ? String(epochSeconds) : date.toLocaleString();
  }

  function parsedLimit(): number {
    return Math.max(1, Number(limit || 50) || 50);
  }

  async function loadStats(force = false) {
    if (!active || !component || !name) return;
    const contextKey = instanceKey;
    const nextKey = `${instanceKey}:stats`;
    if (!force && loadedStatsKey === nextKey) return;

    const req = ++statsRequestSeq;
    statsLoading = true;
    statsError = null;
    try {
      const result = await api.getMemory(component, name, { stats: true });
      if (req !== statsRequestSeq || contextKey !== instanceKey || !active) return;
      if (isInstanceCliError(result)) {
        stats = null;
        statsError = describeInstanceCliError(result, "Memory stats are unavailable.");
      } else {
        stats = result || null;
        statsError = null;
      }
      loadedStatsKey = nextKey;
    } catch (error) {
      if (req !== statsRequestSeq || contextKey !== instanceKey || !active) return;
      stats = null;
      statsError = (error as Error).message || "Failed to load memory stats.";
    } finally {
      if (req === statsRequestSeq && contextKey === instanceKey) {
        statsLoading = false;
      }
    }
  }

  async function loadEntries(force = false) {
    if (!active || !component || !name) return;
    const contextKey = instanceKey;
    const nextKey = `${instanceKey}:${category}:${limit}`;
    if (!force && loadedEntriesKey === nextKey) return;

    const req = ++entriesRequestSeq;
    entriesLoading = true;
    entriesError = null;
    try {
      const result = await api.getMemory(component, name, {
        category: category === "all" ? undefined : category,
        limit: parsedLimit(),
      });
      if (req !== entriesRequestSeq || contextKey !== instanceKey || !active) return;
      if (isInstanceCliError(result)) {
        entries = [];
        entriesError = describeInstanceCliError(result, "Memory entries are unavailable.");
      } else {
        entries = Array.isArray(result) ? result : [];
        entriesError = null;
      }
      loadedEntriesKey = nextKey;
    } catch (error) {
      if (req !== entriesRequestSeq || contextKey !== instanceKey || !active) return;
      entries = [];
      entriesError = (error as Error).message || "Failed to load memory entries.";
    } finally {
      if (req === entriesRequestSeq && contextKey === instanceKey) {
        entriesLoading = false;
      }
    }
  }

  async function runSearch() {
    if (!active || !searchQuery.trim()) return;
    const contextKey = instanceKey;
    const req = ++searchRequestSeq;
    searchLoading = true;
    searchError = null;
    searchSubmittedQuery = searchQuery.trim();
    try {
      const result = await api.getMemory(component, name, {
        query: searchSubmittedQuery,
        limit: parsedLimit(),
      });
      if (req !== searchRequestSeq || contextKey !== instanceKey || !active) return;
      if (isInstanceCliError(result)) {
        searchResults = [];
        searchError = describeInstanceCliError(result, "Memory search is unavailable.");
      } else {
        searchResults = Array.isArray(result) ? result : [];
        searchError = null;
      }
    } catch (error) {
      if (req !== searchRequestSeq || contextKey !== instanceKey || !active) return;
      searchResults = [];
      searchError = (error as Error).message || "Failed to search memory.";
    } finally {
      if (req === searchRequestSeq && contextKey === instanceKey) {
        searchLoading = false;
      }
    }
  }

  function refreshMemory() {
    loadedStatsKey = "";
    loadedEntriesKey = "";
    void loadStats(true);
    void loadEntries(true);
  }

  $effect(() => {
    if (!active || !component || !name) return;
    if (searchContextKey !== instanceKey) {
      searchContextKey = instanceKey;
      searchQuery = "";
      searchResults = [];
      searchLoading = false;
      searchError = null;
      searchSubmittedQuery = "";
    }
    if (loadedStatsKey !== `${instanceKey}:stats`) {
      stats = null;
      statsError = null;
      void loadStats(true);
    }
  });

  $effect(() => {
    if (!active || !component || !name) return;
    const key = `${instanceKey}:${category}:${limit}`;
    if (loadedEntriesKey === key) return;
    entries = [];
    entriesError = null;
    void loadEntries(true);
  });
</script>

<div class="memory-panel">
  <div class="panel-toolbar">
    <div>
      <h2>Memory</h2>
      <p>Backend status, persisted entries, and semantic search results.</p>
    </div>
    <button class="toolbar-btn" onclick={refreshMemory} disabled={statsLoading || entriesLoading}>
      Refresh
    </button>
  </div>

  <div class="stats-grid">
    {#if statsError}
      <div class="panel-state warning">{statsError}</div>
    {:else if statsLoading && !stats}
      <div class="panel-state">Loading memory stats...</div>
    {:else if stats}
      <div class="stat-card">
        <span>Backend</span>
        <strong>{stats.backend || "-"}</strong>
      </div>
      <div class="stat-card">
        <span>Retrieval</span>
        <strong>{stats.retrieval || "-"}</strong>
      </div>
      <div class="stat-card">
        <span>Vector</span>
        <strong>{stats.vector || "-"}</strong>
      </div>
      <div class="stat-card">
        <span>Entries</span>
        <strong>{stats.entries ?? 0}</strong>
      </div>
      <div class="stat-card">
        <span>Vector Entries</span>
        <strong>{stats.vector_entries ?? "-"}</strong>
      </div>
      <div class="stat-card">
        <span>Outbox Pending</span>
        <strong>{stats.outbox_pending ?? "-"}</strong>
      </div>
    {/if}
  </div>

  <section class="memory-section">
    <div class="section-header">
      <h3>Stored Entries</h3>
      <div class="controls">
        <label>
          <span>Category</span>
          <select bind:value={category}>
            <option value="all">All</option>
            <option value="core">Core</option>
            <option value="daily">Daily</option>
            <option value="conversation">Conversation</option>
          </select>
        </label>
        <label>
          <span>Limit</span>
          <select bind:value={limit}>
            <option value="20">20</option>
            <option value="50">50</option>
            <option value="100">100</option>
          </select>
        </label>
      </div>
    </div>

    {#if entriesError}
      <div class="panel-state warning">{entriesError}</div>
    {:else if entriesLoading && entries.length === 0}
      <div class="panel-state">Loading memory entries...</div>
    {:else if entries.length === 0}
      <div class="panel-state">No memory entries for this filter.</div>
    {:else}
      <div class="entry-list">
        {#each entries as entry}
          <article class="entry-card">
            <header>
              <div>
                <div class="entry-key">{entry.key}</div>
                <div class="entry-meta">
                  <span>{entry.category}</span>
                  <span>{entry.timestamp || "-"}</span>
                  {#if entry.session_id}
                    <span class="mono">{entry.session_id}</span>
                  {/if}
                </div>
              </div>
            </header>
            <pre>{entry.content}</pre>
          </article>
        {/each}
      </div>
    {/if}
  </section>

  <section class="memory-section">
    <div class="section-header">
      <h3>Search</h3>
      <form
        class="search-form"
        onsubmit={(event) => {
          event.preventDefault();
          void runSearch();
        }}
      >
        <input bind:value={searchQuery} placeholder="Find facts, snippets, or memory keys" />
        <button class="toolbar-btn" type="submit" disabled={searchLoading || !searchQuery.trim()}>
          {searchLoading ? "Searching..." : "Search"}
        </button>
      </form>
    </div>

    {#if searchError}
      <div class="panel-state warning">{searchError}</div>
    {:else if searchLoading}
      <div class="panel-state">Searching memory...</div>
    {:else if searchSubmittedQuery && searchResults.length === 0}
      <div class="panel-state">No results for "{searchSubmittedQuery}".</div>
    {:else if searchResults.length > 0}
      <div class="search-list">
        {#each searchResults as result}
          <article class="search-card">
            <header>
              <div>
                <div class="entry-key">{result.key}</div>
                <div class="entry-meta">
                  <span>{result.category}</span>
                  <span>{result.source}</span>
                  <span>{result.final_score?.toFixed?.(3) ?? result.final_score}</span>
                </div>
              </div>
              <div class="search-meta">
                <span>{formatSearchTimestamp(result.created_at)}</span>
                <span>{result.start_line}-{result.end_line}</span>
              </div>
            </header>
            <div class="search-path mono">{result.source_path}</div>
            <pre>{result.snippet}</pre>
          </article>
        {/each}
      </div>
    {:else}
      <div class="panel-state">Search memory when you need a specific fact or snippet.</div>
    {/if}
  </section>
</div>

<style>
  .memory-panel {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .panel-toolbar,
  .section-header {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    align-items: flex-start;
  }
  .panel-toolbar h2,
  .section-header h3 {
    margin: 0;
    color: var(--accent);
  }
  .panel-toolbar p {
    margin: 0.25rem 0 0;
    color: var(--fg-dim);
    font-size: 0.875rem;
  }
  .toolbar-btn {
    padding: 0.55rem 0.9rem;
    border: 1px solid var(--accent-dim);
    background: var(--bg-surface);
    color: var(--accent);
    border-radius: 2px;
    font-size: 0.78rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
  }
  .toolbar-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  .panel-state {
    padding: 1.5rem;
    border: 1px dashed color-mix(in srgb, var(--border) 75%, transparent);
    background: color-mix(in srgb, var(--bg-surface) 82%, transparent);
    color: var(--fg-dim);
    border-radius: 4px;
    text-align: center;
  }
  .panel-state.warning {
    border-color: color-mix(in srgb, var(--warning, #f59e0b) 50%, transparent);
    color: var(--warning, #f59e0b);
    background: color-mix(in srgb, var(--warning, #f59e0b) 8%, transparent);
  }
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 0.75rem;
  }
  .stat-card {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    padding: 1rem;
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .stat-card span {
    color: var(--accent-dim);
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .stat-card strong {
    font-size: 0.95rem;
  }
  .memory-section {
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    padding: 1rem;
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .controls,
  .search-form {
    display: flex;
    gap: 0.75rem;
    align-items: end;
  }
  .controls label,
  .search-form {
    color: var(--fg-dim);
    font-size: 0.8rem;
  }
  .controls label {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }
  select,
  input {
    min-width: 120px;
    padding: 0.6rem 0.7rem;
    border: 1px solid color-mix(in srgb, var(--border) 75%, transparent);
    background: color-mix(in srgb, var(--bg-surface) 92%, black 8%);
    color: var(--fg);
    border-radius: 2px;
  }
  .search-form {
    flex: 1;
  }
  .search-form input {
    flex: 1;
  }
  .entry-list,
  .search-list {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }
  .entry-card,
  .search-card {
    padding: 0.95rem 1rem;
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    border-radius: 4px;
    background: color-mix(in srgb, var(--bg-surface) 88%, transparent);
  }
  .entry-card header,
  .search-card header {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 0.65rem;
  }
  .entry-key {
    font-family: var(--font-mono);
    font-size: 0.82rem;
    word-break: break-all;
  }
  .entry-meta,
  .search-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem 0.75rem;
    margin-top: 0.3rem;
    color: var(--fg-dim);
    font-size: 0.75rem;
  }
  .search-path {
    margin-bottom: 0.65rem;
    color: var(--accent-dim);
    font-size: 0.74rem;
    word-break: break-all;
  }
  .mono {
    font-family: var(--font-mono);
  }
  pre {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: var(--font-mono);
    font-size: 0.82rem;
    line-height: 1.55;
  }

  @media (max-width: 900px) {
    .panel-toolbar,
    .section-header,
    .search-form {
      flex-direction: column;
      align-items: stretch;
    }
    .controls {
      flex-wrap: wrap;
      align-items: stretch;
    }
  }
</style>
