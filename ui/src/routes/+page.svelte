<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import InstanceCard from "$lib/components/InstanceCard.svelte";
  import { api } from "$lib/api/client";

  let status = $state<any>(null);
  let error = $state<string | null>(null);
  let interval: ReturnType<typeof setInterval>;

  async function refresh() {
    try {
      status = await api.getStatus();
      error = null;
    } catch (e) {
      error = (e as Error).message;
    }
  }

  onMount(() => {
    refresh();
    interval = setInterval(refresh, 5000);
  });

  onDestroy(() => clearInterval(interval));
</script>

<div class="dashboard">
  <div class="header">
    <h1>System Status</h1>
    <a href="/install" class="install-btn">+ Install Component</a>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  {#if status}
    <div class="instance-grid">
      {#each Object.entries(status.instances || {}) as [component, instances]}
        {#each Object.entries(instances as Record<string, any>) as [name, info]}
          <InstanceCard
            {component}
            {name}
            version={info.version}
            status={info.status || "stopped"}
            autoStart={info.auto_start}
            port={info.port || 0}
            onAction={refresh}
          />
        {/each}
      {/each}
    </div>

    {#if Object.keys(status.instances || {}).length === 0}
      <div class="empty-state">
        <p>> No instances installed yet.</p>
        <a href="/install" class="btn">INITIALIZE FIRST COMPONENT</a>
      </div>
    {/if}
  {/if}
</div>

<style>
  .dashboard {
    padding: 2rem;
    max-width: 1200px;
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
  .install-btn {
    padding: 0.5rem 1rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius);
    font-size: 0.875rem;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .install-btn:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .error-banner {
    padding: 0.75rem 1rem;
    background: rgba(255, 0, 0, 0.1);
    color: var(--error);
    border: 1px solid var(--error);
    border-radius: var(--radius);
    margin-bottom: 1.5rem;
    font-size: 0.875rem;
    font-weight: bold;
    text-shadow: 0 0 5px var(--error);
    box-shadow: 0 0 10px rgba(255, 0, 0, 0.2);
    animation: glitch 3s infinite;
  }
  .instance-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 1.5rem;
  }
  .empty-state {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
    border: 1px dashed var(--border);
    background: var(--bg-surface);
    border-radius: var(--radius);
  }

  :global(body.theme-8bit-lobster) .empty-state,
  :global(body.theme-8bit-lobster-light) .empty-state {
    border-style: solid;
  }
  .empty-state p {
    margin-bottom: 1.5rem;
    font-size: 1.125rem;
    font-family: var(--font-mono);
  }
  .empty-state .btn {
    display: inline-block;
    padding: 0.75rem 1.5rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius);
    font-size: 0.875rem;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }

  :global(body.theme-8bit-lobster:not(.effects-disabled)) .empty-state .btn,
  :global(body.theme-8bit-lobster-light:not(.effects-disabled)) .empty-state .btn {
    animation: lobsterPulse 1.5s steps(6, end) infinite;
  }

  @keyframes lobsterPulse {
    0%,
    100% {
      box-shadow: 0 0 4px transparent;
      border-color: var(--accent-dim);
    }

    50% {
      box-shadow: 0 0 12px var(--border-glow);
      border-color: var(--accent);
    }
  }
  .empty-state .btn:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
</style>
