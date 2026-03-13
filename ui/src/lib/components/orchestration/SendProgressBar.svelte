<script lang="ts">
  let { current = 0, total = 0, label = '' } = $props();
  let pct = $derived(total > 0 ? Math.round((current / total) * 100) : 0);
</script>

<div class="progress-wrap">
  {#if label}
    <span class="progress-label">{label}</span>
  {/if}
  <div class="progress-track">
    <div class="progress-fill" style="width: {pct}%"></div>
  </div>
  <span class="progress-text">{current}/{total}</span>
</div>

<style>
  .progress-wrap {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: var(--fg-dim);
  }
  .progress-label {
    text-transform: uppercase;
    letter-spacing: 0.5px;
    white-space: nowrap;
  }
  .progress-track {
    flex: 1;
    min-width: 40px;
    height: 6px;
    background: var(--bg-hover);
    border-radius: 2px;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  }
  .progress-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 1px;
    transition: width 0.3s ease;
    box-shadow: 0 0 4px var(--accent);
  }
  .progress-text {
    white-space: nowrap;
    min-width: 2.5em;
    text-align: right;
  }
</style>
