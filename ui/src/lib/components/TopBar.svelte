<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';

  let { title = 'Dashboard' } = $props();
  let hubOk = $state(true);

  onMount(() => {
    async function check() {
      try {
        await api.getStatus();
        hubOk = true;
      } catch {
        hubOk = false;
      }
    }
    check();
    const interval = setInterval(check, 10000);
    return () => clearInterval(interval);
  });
</script>

<header class="topbar">
  <h1>{title}</h1>
  <div class="hub-status">
    <span class="status-dot" class:running={hubOk}></span>
    <span>{hubOk ? 'Hub Running' : 'Hub Unreachable'}</span>
  </div>
</header>

<style>
  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.875rem 1.5rem;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }

  .topbar h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary);
  }

  .hub-status {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8rem;
    color: var(--text-secondary);
  }

  .status-dot {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--text-muted);
    flex-shrink: 0;
  }

  .status-dot.running {
    background: var(--success);
    box-shadow: 0 0 6px var(--success);
  }
</style>
