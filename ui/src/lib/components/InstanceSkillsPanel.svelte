<script lang="ts">
  import { api } from "$lib/api/client";
  import {
    describeInstanceCliError,
    isInstanceCliError,
  } from "$lib/instanceCli";

  type Skill = {
    name: string;
    version: string;
    description: string;
    author: string;
    enabled: boolean;
    always: boolean;
    available: boolean;
    missing_deps: string;
    path: string;
    source: string;
    instructions_bytes: number;
  };

  let { component, name, active = false } = $props<{
    component: string;
    name: string;
    active?: boolean;
  }>();

  let skills = $state<Skill[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let loadedKey = $state("");
  let requestSeq = 0;

  const instanceKey = $derived(`${component}/${name}`);
  const sortedSkills = $derived(
    [...skills].sort((a, b) => {
      if (a.available !== b.available) return a.available ? -1 : 1;
      if (a.always !== b.always) return a.always ? -1 : 1;
      return a.name.localeCompare(b.name);
    }),
  );

  async function loadSkills(force = false) {
    if (!active || !component || !name) return;
    const contextKey = instanceKey;
    const nextKey = `${contextKey}:skills`;
    if (!force && loadedKey === nextKey) return;

    const req = ++requestSeq;
    loading = true;
    error = null;
    try {
      const result = await api.getSkills(component, name);
      if (req !== requestSeq || contextKey !== instanceKey || !active) return;
      if (isInstanceCliError(result)) {
        skills = [];
        error = describeInstanceCliError(result, "Skills are unavailable.");
      } else {
        skills = Array.isArray(result) ? result : [];
        error = null;
      }
      loadedKey = nextKey;
    } catch (err) {
      if (req !== requestSeq || contextKey !== instanceKey || !active) return;
      skills = [];
      error = (err as Error).message || "Failed to load skills.";
    } finally {
      if (req === requestSeq && contextKey === instanceKey) {
        loading = false;
      }
    }
  }

  function refreshSkills() {
    loadedKey = "";
    void loadSkills(true);
  }

  $effect(() => {
    if (!active || !component || !name) return;
    if (loadedKey === `${instanceKey}:skills`) return;
    skills = [];
    error = null;
    void loadSkills(true);
  });
</script>

<div class="skills-panel">
  <div class="panel-toolbar">
    <div>
      <h2>Skills</h2>
      <p>Installed prompt skills visible to this instance workspace.</p>
    </div>
    <button class="toolbar-btn" onclick={refreshSkills} disabled={loading}>Refresh</button>
  </div>

  {#if error}
    <div class="panel-state warning">{error}</div>
  {:else if loading && skills.length === 0}
    <div class="panel-state">Loading skills...</div>
  {:else if sortedSkills.length === 0}
    <div class="panel-state">No skills found for this instance.</div>
  {:else}
    <div class="skill-grid">
      {#each sortedSkills as skill}
        <article class="skill-card" class:missing={!skill.available}>
          <header>
            <div>
              <div class="skill-name">
                {skill.name}
                <span class="skill-version">v{skill.version || "-"}</span>
              </div>
              {#if skill.description}
                <div class="skill-description">{skill.description}</div>
              {/if}
            </div>
            <div class="skill-badges">
              <span class:ok={skill.available} class="badge">{skill.available ? "available" : "missing deps"}</span>
              {#if skill.always}
                <span class="badge accent">always</span>
              {/if}
              {#if skill.enabled}
                <span class="badge">enabled</span>
              {/if}
            </div>
          </header>

          <div class="skill-meta">
            <div>
              <span>Source</span>
              <strong>{skill.source || "-"}</strong>
            </div>
            <div>
              <span>Author</span>
              <strong>{skill.author || "-"}</strong>
            </div>
            <div>
              <span>Instructions</span>
              <strong>{skill.instructions_bytes ?? 0} bytes</strong>
            </div>
          </div>

          <div class="skill-path mono">{skill.path || "-"}</div>

          {#if skill.missing_deps}
            <div class="missing-deps">Missing deps: {skill.missing_deps}</div>
          {/if}
        </article>
      {/each}
    </div>
  {/if}
</div>

<style>
  .skills-panel {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .panel-toolbar {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    align-items: flex-start;
  }
  .panel-toolbar h2 {
    margin: 0;
    color: var(--accent);
    font-size: 1.1rem;
  }
  .panel-toolbar p {
    margin: 0.25rem 0 0;
    color: var(--fg-dim);
    font-size: 0.875rem;
  }
  .toolbar-btn {
    padding: 0.55rem 0.9rem;
    border: 1px solid var(--accent-dim);
    background: var(--bg-surface);
    color: var(--accent);
    border-radius: 2px;
    font-size: 0.78rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
  }
  .toolbar-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  .panel-state {
    padding: 1.5rem;
    border: 1px dashed color-mix(in srgb, var(--border) 75%, transparent);
    background: color-mix(in srgb, var(--bg-surface) 82%, transparent);
    color: var(--fg-dim);
    border-radius: 4px;
    text-align: center;
  }
  .panel-state.warning {
    border-color: color-mix(in srgb, var(--warning, #f59e0b) 50%, transparent);
    color: var(--warning, #f59e0b);
    background: color-mix(in srgb, var(--warning, #f59e0b) 8%, transparent);
  }
  .skill-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 0.9rem;
  }
  .skill-card {
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    padding: 1rem;
    border: 1px solid var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .skill-card.missing {
    border-color: color-mix(in srgb, var(--warning, #f59e0b) 45%, transparent);
  }
  .skill-card header {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
  }
  .skill-name {
    font-size: 0.95rem;
    font-weight: 700;
  }
  .skill-version {
    margin-left: 0.35rem;
    color: var(--accent-dim);
    font-family: var(--font-mono);
    font-size: 0.78rem;
  }
  .skill-description {
    margin-top: 0.35rem;
    color: var(--fg-dim);
    font-size: 0.82rem;
    line-height: 1.45;
  }
  .skill-badges {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
    justify-content: flex-end;
  }
  .badge {
    padding: 0.18rem 0.45rem;
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    border-radius: 999px;
    color: var(--fg-dim);
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .badge.ok {
    border-color: color-mix(in srgb, var(--success, #22c55e) 45%, transparent);
    color: var(--success, #22c55e);
  }
  .badge.accent {
    border-color: color-mix(in srgb, var(--accent) 45%, transparent);
    color: var(--accent);
  }
  .skill-meta {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 0.75rem;
  }
  .skill-meta div {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    padding: 0.75rem;
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    border-radius: 4px;
  }
  .skill-meta span {
    color: var(--accent-dim);
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .skill-path,
  .missing-deps {
    word-break: break-all;
    font-size: 0.78rem;
  }
  .skill-path {
    color: var(--fg-dim);
  }
  .missing-deps {
    color: var(--warning, #f59e0b);
  }
  .mono {
    font-family: var(--font-mono);
  }

  @media (max-width: 900px) {
    .panel-toolbar,
    .skill-card header {
      flex-direction: column;
      align-items: stretch;
    }
    .skill-badges {
      justify-content: flex-start;
    }
  }
</style>
