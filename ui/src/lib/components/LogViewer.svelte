<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { api } from '$lib/api/client';

  let { component = '', name = '' } = $props();
  let lines = $state<string[]>([]);
  let container: HTMLElement;
  let autoScroll = $state(true);

  onMount(async () => {
    try {
      const data = await api.getLogs(component, name, 200);
      lines = data.lines || [];
      scrollToBottom();
    } catch (e) {
      lines = ['Failed to load logs'];
    }
  });

  function scrollToBottom() {
    if (autoScroll && container) {
      requestAnimationFrame(() => {
        container.scrollTop = container.scrollHeight;
      });
    }
  }
</script>

<div class="log-viewer">
  <div class="log-header">
    <span>Logs</span>
    <label class="auto-scroll">
      <input type="checkbox" bind:checked={autoScroll} />
      Auto-scroll
    </label>
  </div>
  <div class="log-content" bind:this={container}>
    {#each lines as line}
      <div class="log-line">{line}</div>
    {/each}
    {#if lines.length === 0}
      <div class="log-empty">No logs available</div>
    {/if}
  </div>
</div>

<style>
  .log-viewer {
    display: flex;
    flex-direction: column;
    height: 400px;
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }
  .log-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem 1rem;
    border-bottom: 1px solid var(--border);
    font-size: 0.875rem;
    color: var(--text-secondary);
  }
  .log-content {
    flex: 1;
    overflow-y: auto;
    padding: 0.75rem;
    font-family: var(--font-mono);
    font-size: 0.8rem;
    line-height: 1.5;
  }
  .log-line {
    white-space: pre-wrap;
    word-break: break-all;
  }
  .log-empty {
    color: var(--text-muted);
    text-align: center;
    padding: 2rem;
  }
  .auto-scroll {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    font-size: 0.75rem;
    cursor: pointer;
  }
</style>
