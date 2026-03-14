<script lang="ts">
  let { name = '', type = 'task', status = 'pending' } = $props();

  const typeLabels: Record<string, string> = {
    task: 'T',
    route: 'R',
    interrupt: 'I',
    agent: 'A',
    send: 'S',
    transform: 'X',
    subgraph: 'G',
  };

  const statusColors: Record<string, string> = {
    pending: 'var(--fg-dim)',
    running: 'var(--accent)',
    completed: 'var(--success)',
    failed: 'var(--error)',
    interrupted: 'var(--warning)',
  };
</script>

<div
  class="node-card"
  style="--node-color: {statusColors[status] || 'var(--fg-dim)'}"
>
  <span class="type-badge">{typeLabels[type] || '?'}</span>
  <span class="node-name">{name}</span>
</div>

<style>
  .node-card {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.25rem 0.5rem;
    background: color-mix(in srgb, var(--node-color) 10%, var(--bg-surface));
    border: 1px solid color-mix(in srgb, var(--node-color) 40%, transparent);
    border-radius: 4px;
    font-size: 0.6875rem;
    color: var(--fg);
    box-shadow: 0 0 4px color-mix(in srgb, var(--node-color) 15%, transparent);
  }
  .type-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    border-radius: 2px;
    background: color-mix(in srgb, var(--node-color) 25%, transparent);
    color: var(--node-color);
    font-family: var(--font-mono);
    font-size: 0.625rem;
    font-weight: 700;
    text-shadow: 0 0 4px var(--node-color);
  }
  .node-name {
    font-family: var(--font-mono);
    letter-spacing: 0.5px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100px;
  }
</style>
