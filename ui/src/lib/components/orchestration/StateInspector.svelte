<script lang="ts">
  let { currentState = null, previousState = null } = $props<{ currentState: any; previousState?: any }>();

  let diffMode = $state(false);

  function escapeHtml(value: string): string {
    return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  }

  function syntaxHighlight(json: string): string {
    return json.replace(
      /("(\\u[\da-fA-F]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/g,
      (match) => {
        let cls = 'json-number';
        if (/^"/.test(match)) {
          cls = /:$/.test(match) ? 'json-key' : 'json-string';
        } else if (/true|false/.test(match)) {
          cls = 'json-boolean';
        } else if (/null/.test(match)) {
          cls = 'json-null';
        }
        return `<span class="${cls}">${escapeHtml(match)}</span>`;
      }
    );
  }

  function getDiff(curr: any, prev: any): { added: Set<string>; removed: Set<string>; changed: Set<string> } {
    const added = new Set<string>();
    const removed = new Set<string>();
    const changed = new Set<string>();
    if (!curr || !prev) return { added, removed, changed };
    const currKeys = Object.keys(curr);
    const prevKeys = Object.keys(prev);
    for (const k of currKeys) {
      if (!(k in prev)) added.add(k);
      else if (JSON.stringify(curr[k]) !== JSON.stringify(prev[k])) changed.add(k);
    }
    for (const k of prevKeys) {
      if (!(k in curr)) removed.add(k);
    }
    return { added, removed, changed };
  }

  let diff = $derived(getDiff(currentState, previousState));
  let formatted = $derived(currentState ? JSON.stringify(currentState, null, 2) : 'null');
  let highlighted = $derived(syntaxHighlight(formatted));
</script>

<div class="inspector">
  <div class="inspector-header">
    <span>State</span>
    {#if previousState}
      <button
        class="diff-toggle"
        class:active={diffMode}
        onclick={() => diffMode = !diffMode}
      >Diff</button>
    {/if}
  </div>
  <div class="inspector-body">
    {#if diffMode && previousState}
      <div class="diff-view">
        {#if diff.added.size > 0}
          <div class="diff-section added">
            <span class="diff-label">Added</span>
            {#each [...diff.added] as key}
              <div class="diff-line">+ {key}: {JSON.stringify(currentState[key])}</div>
            {/each}
          </div>
        {/if}
        {#if diff.changed.size > 0}
          <div class="diff-section changed">
            <span class="diff-label">Changed</span>
            {#each [...diff.changed] as key}
              <div class="diff-line old">- {key}: {JSON.stringify(previousState[key])}</div>
              <div class="diff-line new">+ {key}: {JSON.stringify(currentState[key])}</div>
            {/each}
          </div>
        {/if}
        {#if diff.removed.size > 0}
          <div class="diff-section removed">
            <span class="diff-label">Removed</span>
            {#each [...diff.removed] as key}
              <div class="diff-line">- {key}: {JSON.stringify(previousState[key])}</div>
            {/each}
          </div>
        {/if}
        {#if diff.added.size === 0 && diff.changed.size === 0 && diff.removed.size === 0}
          <div class="no-diff">No changes</div>
        {/if}
      </div>
    {:else}
      <pre class="json-pre">{@html highlighted}</pre>
    {/if}
  </div>
</div>

<style>
  .inspector {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
  }
  .inspector-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.625rem 1rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    font-size: 0.8125rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }
  .diff-toggle {
    padding: 0.25rem 0.625rem;
    border: 1px solid var(--border);
    border-radius: 2px;
    background: transparent;
    color: var(--fg-dim);
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .diff-toggle:hover {
    background: var(--bg-hover);
    color: var(--fg);
  }
  .diff-toggle.active {
    color: var(--accent);
    border-color: var(--accent-dim);
    background: color-mix(in srgb, var(--accent) 12%, transparent);
    text-shadow: var(--text-glow);
  }
  .inspector-body {
    flex: 1;
    overflow: auto;
    padding: 1rem;
  }
  .json-pre {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-all;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.6;
    color: var(--fg);
  }
  :global(.json-key) { color: var(--accent); }
  :global(.json-string) { color: var(--success); }
  :global(.json-number) { color: var(--warning); }
  :global(.json-boolean) { color: var(--accent); }
  :global(.json-null) { color: var(--fg-dim); }

  .diff-view {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.6;
  }
  .diff-section {
    margin-bottom: 0.75rem;
  }
  .diff-label {
    display: block;
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
    margin-bottom: 0.25rem;
    font-weight: 700;
  }
  .diff-line {
    padding: 0.125rem 0.5rem;
    border-radius: 2px;
  }
  .diff-section.added .diff-line,
  .diff-line.new {
    color: var(--success);
    background: color-mix(in srgb, var(--success) 8%, transparent);
    border-left: 2px solid var(--success);
  }
  .diff-section.removed .diff-line,
  .diff-line.old {
    color: var(--error);
    background: color-mix(in srgb, var(--error) 8%, transparent);
    border-left: 2px solid var(--error);
  }
  .diff-section.changed .diff-label { color: var(--warning); }
  .no-diff {
    color: var(--fg-dim);
    text-align: center;
    padding: 2rem;
    font-style: italic;
  }
</style>
