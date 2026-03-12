<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";
  import type { LogSource } from "$lib/api/client";

  let { component = "", name = "" } = $props();
  let lines = $state<string[]>([]);
  let container: HTMLElement;
  let autoScroll = $state(true);
  let source = $state<LogSource>("instance");

  const sourceLabels: Record<LogSource, string> = {
    instance: "Instance",
    nullhub: "NullHub",
  };
  const logSources: LogSource[] = ["instance", "nullhub"];

  async function fetchLogs() {
    const requestedSource = source;
    try {
      const data = await api.getLogs(component, name, 200, requestedSource);
      if (requestedSource !== source) return;
      lines = data.lines || [];
      scrollToBottom();
    } catch {
      if (lines.length === 0) lines = ["Failed to load logs"];
    }
  }

  onMount(() => {
    void fetchLogs();
    const interval = setInterval(fetchLogs, 3000);
    return () => clearInterval(interval);
  });

  $effect(() => {
    component;
    name;
    source;
    void fetchLogs();
  });

  function scrollToBottom() {
    if (autoScroll && container) {
      requestAnimationFrame(() => {
        container.scrollTop = container.scrollHeight;
      });
    }
  }

  async function clearLogs() {
    await api.clearLogs(component, name, source);
    lines = [];
  }
</script>

<div class="log-viewer">
  <div class="log-header">
    <div class="log-title-group">
      <span>Logs</span>
      <div class="source-switch" role="tablist" aria-label="Log source">
        {#each logSources as option}
          <button
            type="button"
            class="source-btn"
            class:active={source === option}
            onclick={() => (source = option)}
          >
            {sourceLabels[option]}
          </button>
        {/each}
      </div>
    </div>
    <div class="log-actions">
      <button class="clear-btn" onclick={clearLogs}>Clear</button>
      <label class="auto-scroll">
        <input type="checkbox" bind:checked={autoScroll} />
        Auto-scroll
      </label>
    </div>
  </div>
  <div class="log-content" bind:this={container}>
    {#each lines as line}
      <div class="log-line">{line}</div>
    {/each}
    {#if lines.length === 0}
      <div class="log-empty">No {sourceLabels[source]} logs available</div>
    {/if}
  </div>
</div>

<style>
  .log-viewer {
    display: flex;
    flex-direction: column;
    height: 400px;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    box-shadow: inset 0 0 10px rgba(0, 0, 0, 0.5);
  }
  .log-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    font-size: 0.8125rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }
  .log-title-group {
    display: flex;
    align-items: center;
    gap: 1rem;
    min-width: 0;
  }
  .source-switch {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.1875rem;
    border: 1px solid color-mix(in srgb, var(--border) 60%, transparent);
    border-radius: 2px;
    background: color-mix(in srgb, var(--bg) 55%, transparent);
  }
  .source-btn {
    padding: 0.3rem 0.65rem;
    border: 1px solid transparent;
    border-radius: 2px;
    background: transparent;
    color: var(--fg-dim);
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 0.8px;
    transition: all 0.15s ease;
  }
  .source-btn:hover {
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: none;
    text-shadow: none;
  }
  .source-btn.active {
    color: var(--accent);
    border-color: color-mix(in srgb, var(--accent) 55%, transparent);
    background: color-mix(in srgb, var(--accent) 14%, transparent);
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 8px color-mix(in srgb, var(--accent) 18%, transparent);
  }
  .log-content {
    flex: 1;
    overflow-y: auto;
    padding: 1rem;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.6;
    color: var(--fg);
    text-shadow: 0 0 2px color-mix(in srgb, var(--fg) 50%, transparent);
  }
  .log-line {
    white-space: pre-wrap;
    word-break: break-all;
    margin-bottom: 0.125rem;
  }
  .log-line:hover {
    background: color-mix(in srgb, var(--fg) 5%, transparent);
  }
  .log-empty {
    color: var(--fg-dim);
    text-align: center;
    padding: 3rem;
    font-style: italic;
    opacity: 0.7;
  }
  .log-actions {
    display: flex;
    align-items: center;
    gap: 1rem;
  }
  .clear-btn {
    padding: 0.25rem 0.75rem;
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    color: var(--accent);
    font-size: 0.75rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .clear-btn:hover {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }
  .auto-scroll {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.75rem;
    color: var(--fg-dim);
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  .auto-scroll input[type="checkbox"] {
    appearance: none;
    width: 14px;
    height: 14px;
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 2px;
    position: relative;
    cursor: pointer;
  }
  .auto-scroll input[type="checkbox"]:checked {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: inset 0 0 5px var(--accent);
  }
  .auto-scroll input[type="checkbox"]:checked::after {
    content: "";
    position: absolute;
    top: 2px;
    left: 2px;
    width: 8px;
    height: 8px;
    background: var(--accent);
    border-radius: 1px;
    box-shadow: 0 0 3px var(--border-glow);
  }
  @media (max-width: 760px) {
    .log-header {
      flex-direction: column;
      align-items: stretch;
    }
    .log-title-group {
      justify-content: space-between;
      flex-wrap: wrap;
    }
    .log-actions {
      justify-content: space-between;
    }
  }
</style>
