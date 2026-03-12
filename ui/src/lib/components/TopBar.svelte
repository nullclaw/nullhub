<script lang="ts">
  import { onMount, tick } from "svelte";
  import { browser } from "$app/environment";
  import { api } from "$lib/api/client";

  let { title = "NullHub" } = $props();
  let hubOk = $state(true);

  let currentTheme = $state("theme-matrix");
  let effectsEnabled = $state(false);
  let initialized = $state(false);

  onMount(() => {
    if (browser) {
      const savedTheme = localStorage.getItem("nullhub-theme");
      const savedEffects = localStorage.getItem("nullhub-effects");
      if (savedTheme) currentTheme = savedTheme;
      if (savedEffects === "true") effectsEnabled = true;
      initialized = true;
    }

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

  $effect(() => {
    if (browser && initialized) {
      localStorage.setItem("nullhub-theme", currentTheme);
      localStorage.setItem("nullhub-effects", effectsEnabled.toString());

      const body = document.body;
      const root = document.documentElement;
      const themeClasses = [
        "theme-matrix",
        "theme-8bit-lobster",
        "theme-8bit-lobster-light",
        "theme-dracula",
        "theme-synthwave",
        "theme-amber",
        "theme-light",
      ];
      body.classList.remove(...themeClasses);
      root.classList.remove(...themeClasses);
      if (currentTheme) {
        body.classList.add(currentTheme);
        root.classList.add(currentTheme);
      }

      if (effectsEnabled) {
        body.classList.remove("effects-disabled");
      } else {
        body.classList.add("effects-disabled");
      }
    }
  });
</script>

<header class="topbar">
  <a href="/" class="brand-link" aria-label="Go to dashboard">
    <h1>{title}</h1>
  </a>
  <div class="topbar-right">
    <div class="theme-controls">
      <label class="effect-toggle" title="Toggle CRT Effects">
        <input type="checkbox" bind:checked={effectsEnabled} />
        CRT FX
      </label>
      <select bind:value={currentTheme} class="theme-select" title="Theme">
        <option value="theme-matrix">Matrix</option>
        <option value="theme-8bit-lobster">Lobster</option>
        <option value="theme-8bit-lobster-light">Lobster Light</option>
        <option value="theme-dracula">Dracula</option>
        <option value="theme-synthwave">Synthwave</option>
        <option value="theme-amber">Amber</option>
        <option value="theme-light">Light</option>
      </select>
    </div>
    <div class="hub-status">
      <span class="status-dot" class:running={hubOk}></span>
      <span>{hubOk ? "Hub Running" : "Hub Unreachable"}</span>
    </div>
  </div>
</header>

<style>
  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.875rem 1.5rem;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
    backdrop-filter: blur(4px);
  }

  .topbar h1 {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
  }

  .brand-link {
    display: inline-flex;
    align-items: center;
  }

  .brand-link:hover {
    text-decoration: none;
  }

  .topbar-right {
    display: flex;
    align-items: center;
    gap: 1.5rem;
  }

  .theme-controls {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding-right: 1.5rem;
    border-right: 1px dashed var(--border);
  }

  :global(body.theme-8bit-lobster) .theme-controls,
  :global(body.theme-8bit-lobster-light) .theme-controls {
    border-right-style: solid;
  }

  .effect-toggle {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
  }

  .effect-toggle input[type="checkbox"] {
    appearance: none;
    width: 14px;
    height: 14px;
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: var(--radius-sm);
    position: relative;
    cursor: pointer;
    margin: 0;
    padding: 0;
  }

  .effect-toggle input[type="checkbox"]:checked {
    background: color-mix(in srgb, var(--fx-accent) 20%, transparent);
    border-color: var(--fx-accent);
    box-shadow: inset 0 0 5px var(--fx-accent);
  }

  .effect-toggle input[type="checkbox"]:checked::after {
    content: "";
    position: absolute;
    top: 2px;
    left: 2px;
    width: 8px;
    height: 8px;
    background: var(--fx-accent);
    border-radius: 1px;
    box-shadow: 0 0 3px var(--fx-accent-glow);
  }

  .theme-select {
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 0.25rem 0.5rem;
    color: var(--accent);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    text-transform: uppercase;
    outline: none;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .theme-select:focus,
  .theme-select:hover {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .theme-select option {
    background: var(--bg);
    color: var(--fg);
  }

  .hub-status {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    font-size: 0.85rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .status-dot {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: var(--radius);
    background: var(--error);
    box-shadow: 0 0 6px var(--error);
    flex-shrink: 0;
  }

  .status-dot.running {
    background: var(--success);
    box-shadow: 0 0 10px var(--success);
  }
</style>
