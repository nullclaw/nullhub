<script lang="ts">
  import { page } from "$app/stores";
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";

  let instances = $state<Record<string, any>>({});
  let currentPath = $derived($page.url.pathname);

  async function loadInstances() {
    try {
      const status = await api.getStatus();
      instances = status.instances || {};
    } catch {}
  }

  onMount(() => {
    loadInstances();
    const interval = setInterval(loadInstances, 5000);
    return () => clearInterval(interval);
  });
</script>

<nav class="sidebar">
  <div class="logo">
    <h2>NullHub</h2>
  </div>

  <div class="nav-section">
    <a href="/" class:active={currentPath === "/"}>System Status</a>
    <a href="/dashboard" class:active={currentPath === "/dashboard"}>Dashboard</a>
    <a href="/install" class:active={currentPath === "/install"}
      >Install Component</a
    >
  </div>

  <div class="nav-section">
    <h3>Instances</h3>
    {#each Object.entries(instances) as [component, items]}
      <div class="component-group">
        <span class="component-name">{component}</span>
        {#each Object.entries(items as Record<string, any>) as [name, info]}
          <a
            href="/instances/{component}/{name}"
            class:active={currentPath === `/instances/${component}/${name}`}
          >
            <span class="status-dot" class:running={info.status === "running"}
            ></span>
            {name}
          </a>
        {/each}
      </div>
    {/each}
  </div>

  <div class="nav-section">
    <a href="/providers" class:active={currentPath === "/providers"}>Providers</a>
  </div>

  <div class="nav-section">
    <a href="/channels" class:active={currentPath === "/channels"}>Channels</a>
  </div>

  <div class="nav-bottom">
    <a href="/settings" class:active={currentPath === "/settings"}>Settings</a>
  </div>
</nav>

<style>
  .sidebar {
    width: 250px;
    min-width: 250px;
    height: 100vh;
    background: var(--bg-surface);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    backdrop-filter: blur(4px);
    z-index: 20;
  }

  .logo {
    padding: 1.5rem 1.25rem;
    border-bottom: 1px solid var(--border);
    text-align: center;
  }

  .logo h2 {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--accent);
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
    text-transform: uppercase;
  }

  .nav-section {
    padding: 1rem 0;
    border-bottom: 1px solid var(--border);
  }

  .nav-section h3 {
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent-dim);
    padding: 0.5rem 1.25rem;
    text-shadow: 0 0 2px var(--accent-dim);
  }

  .nav-section a {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.625rem 1.25rem;
    color: var(--fg-dim);
    font-size: 0.875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    border-left: 3px solid transparent;
  }

  .nav-section a:hover {
    text-decoration: none;
    background: var(--bg-hover);
    color: var(--fg);
    border-left-color: var(--accent-dim);
    text-shadow: var(--text-glow);
  }

  .nav-section a.active {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    color: var(--accent);
    border-left: 3px solid var(--accent);
    text-shadow: var(--text-glow);
    box-shadow: inset 20px 0 20px -20px var(--accent);
  }

  .component-group {
    margin-bottom: 0.5rem;
  }

  .component-name {
    display: block;
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--fg-dim);
    padding: 0.375rem 1.25rem 0.125rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    opacity: 0.7;
  }

  .component-group a {
    padding-left: 1.75rem;
    font-size: 0.8rem;
  }

  .status-dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--error);
    box-shadow: 0 0 5px var(--error);
    flex-shrink: 0;
  }

  .status-dot.running {
    background: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .nav-bottom {
    margin-top: auto;
    padding: 1rem 0;
    border-top: 1px solid var(--border);
  }

  .nav-bottom a {
    display: block;
    padding: 0.75rem 1.25rem;
    color: var(--fg-dim);
    font-size: 0.875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    border-left: 3px solid transparent;
  }

  .nav-bottom a:hover {
    text-decoration: none;
    background: var(--bg-hover);
    color: var(--fg);
    border-left-color: var(--accent-dim);
    text-shadow: var(--text-glow);
  }

  .nav-bottom a.active {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    color: var(--accent);
    border-left: 3px solid var(--accent);
    text-shadow: var(--text-glow);
    box-shadow: inset 20px 0 20px -20px var(--accent);
  }
</style>
