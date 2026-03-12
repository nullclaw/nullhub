<script lang="ts">
  import StatusBadge from "./StatusBadge.svelte";
  import { api } from "$lib/api/client";

  let {
    component = "",
    name = "",
    version = "",
    status = "stopped",
    autoStart = false,
    port = 0,
    onAction = () => {},
  } = $props();
  let loading = $state(false);
  let localStatus = $state("stopped");
  let displayVersion = $derived(
    !version ? "-" : version.startsWith("v") || version.startsWith("dev-") ? version : `v${version}`,
  );

  // Sync localStatus when prop changes (from poll)
  $effect(() => {
    localStatus = status || "stopped";
  });

  async function start(e: Event) {
    e.preventDefault();
    e.stopPropagation();
    loading = true;
    localStatus = "starting";
    try {
      await api.startInstance(component, name);
      onAction();
    } catch {
      localStatus = "stopped";
    } finally {
      loading = false;
    }
  }

  async function stop(e: Event) {
    e.preventDefault();
    e.stopPropagation();
    loading = true;
    localStatus = "stopping";
    try {
      await api.stopInstance(component, name);
      onAction();
    } catch {
      localStatus = "running";
    } finally {
      loading = false;
    }
  }
</script>

<a href="/instances/{component}/{name}" class="card">
  <div class="card-header">
    <span class="card-name">{name}</span>
    <StatusBadge status={localStatus} />
  </div>
  <div class="card-meta">
    <span class="component-tag">{component}</span>
    <span class="version">{displayVersion}</span>
  </div>
  {#if localStatus === "running" && port > 0}
    <div class="gateway-addr">
      <span class="gateway-label">Gateway:</span>
      <code>127.0.0.1:{port}</code>
    </div>
  {/if}
  <div class="card-actions">
    {#if localStatus === "running" || localStatus === "stopping"}
      <button onclick={stop} disabled={loading}>
        {loading ? "Stopping..." : "Stop"}
      </button>
    {:else}
      <button onclick={start} disabled={loading}>
        {loading ? "Starting..." : "Start"}
      </button>
    {/if}
  </div>
</a>

<style>
  .card {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    padding: 1.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    color: var(--fg);
    transition: all 0.2s ease;
    backdrop-filter: blur(4px);
  }
  .card:hover {
    text-decoration: none;
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 15px var(--border-glow);
    transform: translateY(-2px);
  }
  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    padding-bottom: 0.75rem;
  }
  .card-name {
    font-weight: 700;
    font-size: 1.125rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
    color: var(--accent);
  }
  .card-meta {
    display: flex;
    align-items: center;
    gap: 1rem;
    font-size: 0.8125rem;
    color: var(--fg-dim);
  }
  .component-tag {
    padding: 0.25rem 0.5rem;
    background: color-mix(in srgb, var(--border) 20%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .version {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    opacity: 0.8;
  }
  .card-actions {
    display: flex;
    gap: 0.75rem;
    margin-top: 0.5rem;
  }
  .card-actions button {
    padding: 0.5rem 1rem;
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    background: var(--bg-surface);
    color: var(--accent);
    font-size: 0.8125rem;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .card-actions button:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .gateway-addr {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8125rem;
    padding: 0.5rem;
    background: color-mix(in srgb, var(--bg-surface) 84%, var(--accent) 8%);
    border: 1px solid var(--border);
    border-radius: 2px;
  }
  .gateway-label {
    color: var(--fg-dim);
    font-size: 0.75rem;
    text-transform: uppercase;
  }
  .gateway-addr code {
    font-family: var(--font-mono);
    font-size: 0.8rem;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }
</style>
