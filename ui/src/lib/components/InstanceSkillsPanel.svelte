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

  type CatalogEntry = {
    name: string;
    version: string;
    description: string;
    author?: string;
    recommended: boolean;
    install_kind: string;
    source?: string;
    homepage_url?: string;
    clawhub_slug?: string;
    always?: boolean;
  };

  type InstallResult = {
    status?: string;
    restart_required?: boolean;
  };

  let { component, name, active = false } = $props<{
    component: string;
    name: string;
    active?: boolean;
  }>();

  let skills = $state<Skill[]>([]);
  let catalog = $state<CatalogEntry[]>([]);
  let loading = $state(false);
  let catalogLoading = $state(false);
  let error = $state<string | null>(null);
  let catalogError = $state<string | null>(null);
  let actionError = $state<string | null>(null);
  let actionMessage = $state<string | null>(null);
  let loadedKey = $state("");
  let catalogLoadedKey = $state("");
  let requestSeq = 0;
  let catalogRequestSeq = 0;
  let busyAction = $state<string | null>(null);
  let clawhubSlug = $state("");
  let sourceInput = $state("");

  const instanceKey = $derived(`${component}/${name}`);
  const supportsInstall = $derived(component === "nullclaw");
  const installedSkillNames = $derived(new Set(skills.map((skill) => skill.name)));
  const sortedSkills = $derived(
    [...skills].sort((a, b) => {
      if (a.available !== b.available) return a.available ? -1 : 1;
      if (a.always !== b.always) return a.always ? -1 : 1;
      return a.name.localeCompare(b.name);
    }),
  );
  const sortedCatalog = $derived(
    [...catalog].sort((a, b) => {
      if (a.recommended !== b.recommended) return a.recommended ? -1 : 1;
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

  async function loadCatalog(force = false) {
    if (!active || !supportsInstall || !component || !name) return;
    const contextKey = instanceKey;
    const nextKey = `${contextKey}:skills:catalog`;
    if (!force && catalogLoadedKey === nextKey) return;

    const req = ++catalogRequestSeq;
    catalogLoading = true;
    catalogError = null;
    try {
      const result = await api.getSkillCatalog(component, name);
      if (req !== catalogRequestSeq || contextKey !== instanceKey || !active) return;
      catalog = Array.isArray(result) ? result : [];
      catalogLoadedKey = nextKey;
    } catch (err) {
      if (req !== catalogRequestSeq || contextKey !== instanceKey || !active) return;
      catalog = [];
      catalogError = (err as Error).message || "Failed to load recommended skills.";
    } finally {
      if (req === catalogRequestSeq && contextKey === instanceKey) {
        catalogLoading = false;
      }
    }
  }

  async function refreshAll() {
    loadedKey = "";
    catalogLoadedKey = "";
    await Promise.all([loadSkills(true), loadCatalog(true)]);
  }

  async function installBundled(entry: CatalogEntry) {
    actionError = null;
    actionMessage = null;
    busyAction = `bundled:${entry.name}`;
    try {
      const result = await api.installBundledSkill(component, name, entry.name) as InstallResult;
      if (isInstanceCliError(result)) throw new Error(describeInstanceCliError(result, `Failed to install ${entry.name}.`));
      const baseMessage = result?.status === "updated"
        ? `Updated ${entry.name}.`
        : `Installed ${entry.name}.`;
      actionMessage = result?.restart_required
        ? `${baseMessage} Restart this instance if it is already running to apply nullhub command access.`
        : baseMessage;
      await refreshAll();
    } catch (err) {
      actionError = (err as Error).message || `Failed to install ${entry.name}.`;
    } finally {
      busyAction = null;
    }
  }

  async function installFromClawhub() {
    const slug = clawhubSlug.trim();
    if (!slug) {
      actionError = "Enter a ClawHub slug first.";
      actionMessage = null;
      return;
    }
    actionError = null;
    actionMessage = null;
    busyAction = `clawhub:${slug}`;
    try {
      const result = await api.installSkillFromClawhub(component, name, slug);
      if (isInstanceCliError(result)) throw new Error(describeInstanceCliError(result, `Failed to install ${slug} from ClawHub.`));
      clawhubSlug = "";
      actionMessage = `Installed ${slug} from ClawHub.`;
      await refreshAll();
    } catch (err) {
      actionError = (err as Error).message || `Failed to install ${slug} from ClawHub.`;
    } finally {
      busyAction = null;
    }
  }

  async function installFromSource() {
    const source = sourceInput.trim();
    if (!source) {
      actionError = "Enter a git URL or local path first.";
      actionMessage = null;
      return;
    }
    actionError = null;
    actionMessage = null;
    busyAction = `source:${source}`;
    try {
      const result = await api.installSkillFromSource(component, name, source);
      if (isInstanceCliError(result)) throw new Error(describeInstanceCliError(result, "Failed to install skill from source."));
      sourceInput = "";
      actionMessage = "Installed skill from source.";
      await refreshAll();
    } catch (err) {
      actionError = (err as Error).message || "Failed to install skill from source.";
    } finally {
      busyAction = null;
    }
  }

  async function removeSkill(skillName: string) {
    actionError = null;
    actionMessage = null;
    busyAction = `remove:${skillName}`;
    try {
      const result = await api.removeSkill(component, name, skillName);
      if (isInstanceCliError(result)) throw new Error(describeInstanceCliError(result, `Failed to remove ${skillName}.`));
      actionMessage = `Removed ${skillName}.`;
      await refreshAll();
    } catch (err) {
      actionError = (err as Error).message || `Failed to remove ${skillName}.`;
    } finally {
      busyAction = null;
    }
  }

  function installLabel(entry: CatalogEntry) {
    if (entry.install_kind === "bundled") return "Bundled";
    if (entry.install_kind === "clawhub") return "ClawHub";
    return "Source";
  }

  $effect(() => {
    if (!active || !component || !name) return;
    if (loadedKey === `${instanceKey}:skills` && (!supportsInstall || catalogLoadedKey === `${instanceKey}:skills:catalog`)) return;
    skills = [];
    catalog = [];
    error = null;
    catalogError = null;
    void refreshAll();
  });
</script>

<div class="skills-panel">
  <div class="panel-toolbar">
    <div>
      <h2>Skills</h2>
      <p>Installed prompt skills visible to this instance workspace.</p>
    </div>
    <button class="toolbar-btn" onclick={() => void refreshAll()} disabled={loading || catalogLoading || busyAction !== null}>Refresh</button>
  </div>

  {#if supportsInstall}
    <section class="skill-section">
      <div class="section-header">
        <div>
          <h3>Recommended</h3>
          <p>Install managed skills that teach this nullclaw how to operate sibling tools from the Null ecosystem.</p>
        </div>
      </div>

      {#if actionMessage}
        <div class="panel-state success">{actionMessage}</div>
      {/if}
      {#if actionError}
        <div class="panel-state warning">{actionError}</div>
      {/if}
      {#if catalogError}
        <div class="panel-state warning">{catalogError}</div>
      {:else if catalogLoading && sortedCatalog.length === 0}
        <div class="panel-state">Loading recommended skills...</div>
      {:else if sortedCatalog.length > 0}
        <div class="skill-grid">
          {#each sortedCatalog as entry}
            <article class="skill-card recommended" class:installed={installedSkillNames.has(entry.name)}>
              <header>
                <div>
                  <div class="skill-name">
                    {entry.name}
                    <span class="skill-version">v{entry.version || "-"}</span>
                  </div>
                  {#if entry.description}
                    <div class="skill-description">{entry.description}</div>
                  {/if}
                </div>
                <div class="skill-badges">
                  {#if entry.recommended}
                    <span class="badge accent">recommended</span>
                  {/if}
                  {#if entry.always}
                    <span class="badge accent">always</span>
                  {/if}
                  {#if installedSkillNames.has(entry.name)}
                    <span class="badge ok">installed</span>
                  {/if}
                </div>
              </header>

              <div class="skill-meta">
                <div>
                  <span>Install</span>
                  <strong>{installLabel(entry)}</strong>
                </div>
                <div>
                  <span>Source</span>
                  <strong>{entry.source || entry.clawhub_slug || "nullhub"}</strong>
                </div>
                <div>
                  <span>Homepage</span>
                  <strong>{entry.homepage_url || "-"}</strong>
                </div>
              </div>

              <div class="skill-actions">
                <button
                  class="toolbar-btn"
                  onclick={() => void installBundled(entry)}
                  disabled={busyAction !== null || entry.install_kind !== "bundled"}
                >
                  {installedSkillNames.has(entry.name) ? "Reinstall" : "Install"}
                </button>
                {#if entry.homepage_url}
                  <a class="toolbar-link" href={entry.homepage_url} target="_blank" rel="noreferrer">Browse</a>
                {/if}
              </div>
            </article>
          {/each}
        </div>
      {/if}

      <div class="install-grid">
        <form class="install-card" onsubmit={(event) => {
          event.preventDefault();
          void installFromClawhub();
        }}>
          <div>
            <h4>Install From ClawHub</h4>
            <p>Paste a published ClawHub slug. NullHub will run <code>clawhub install</code> inside this instance workspace.</p>
          </div>
          <input
            bind:value={clawhubSlug}
            type="text"
            placeholder="my-skill"
            disabled={busyAction !== null}
          />
          <div class="skill-actions">
            <button class="toolbar-btn" type="submit" disabled={busyAction !== null}>Install</button>
            <a class="toolbar-link" href="https://clawhub.ai" target="_blank" rel="noreferrer">Browse ClawHub</a>
          </div>
        </form>

        <form class="install-card" onsubmit={(event) => {
          event.preventDefault();
          void installFromSource();
        }}>
          <div>
            <h4>Install From Source</h4>
            <p>Use a git URL or local skill path. This goes through <code>nullclaw skills install</code>.</p>
          </div>
          <input
            bind:value={sourceInput}
            type="text"
            placeholder="https://github.com/owner/repo.git"
            disabled={busyAction !== null}
          />
          <div class="skill-actions">
            <button class="toolbar-btn" type="submit" disabled={busyAction !== null}>Install</button>
          </div>
        </form>
      </div>
    </section>
  {/if}

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

          {#if skill.source === "workspace" && supportsInstall}
            <div class="skill-actions">
              <button class="toolbar-btn danger" onclick={() => void removeSkill(skill.name)} disabled={busyAction !== null}>Remove</button>
            </div>
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
  .skill-section {
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, var(--accent) 25%, var(--border));
    background: color-mix(in srgb, var(--bg-surface) 94%, transparent);
    border-radius: 4px;
  }
  .section-header {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    align-items: flex-start;
  }
  .section-header h3 {
    margin: 0;
    color: var(--accent);
    font-size: 1rem;
  }
  .section-header p {
    margin: 0.25rem 0 0;
    color: var(--fg-dim);
    font-size: 0.84rem;
    line-height: 1.45;
  }
  .install-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 0.9rem;
  }
  .install-card {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1rem;
    border: 1px solid var(--border);
    background: color-mix(in srgb, var(--bg-panel, var(--bg-surface)) 90%, transparent);
    border-radius: 4px;
  }
  .install-card h4 {
    margin: 0;
    font-size: 0.95rem;
  }
  .install-card p {
    margin: 0.25rem 0 0;
    color: var(--fg-dim);
    font-size: 0.82rem;
    line-height: 1.45;
  }
  .install-card input {
    width: 100%;
    padding: 0.7rem 0.8rem;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--fg);
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.82rem;
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
  .toolbar-btn,
  .toolbar-link {
    display: inline-flex;
    align-items: center;
    justify-content: center;
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
    text-decoration: none;
  }
  .toolbar-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  .toolbar-btn.danger {
    border-color: color-mix(in srgb, var(--danger, #ef4444) 50%, transparent);
    color: var(--danger, #ef4444);
  }
  .panel-state {
    padding: 1rem 1.15rem;
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
  .panel-state.success {
    border-color: color-mix(in srgb, var(--success, #22c55e) 50%, transparent);
    color: var(--success, #22c55e);
    background: color-mix(in srgb, var(--success, #22c55e) 8%, transparent);
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
  .skill-card.recommended {
    border-color: color-mix(in srgb, var(--accent) 35%, var(--border));
  }
  .skill-card.installed {
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--success, #22c55e) 28%, transparent);
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
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 0.75rem;
  }
  .skill-meta div {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    min-width: 0;
  }
  .skill-meta span {
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-muted);
  }
  .skill-meta strong {
    font-size: 0.82rem;
    line-height: 1.35;
    word-break: break-word;
  }
  .skill-path,
  .missing-deps {
    font-size: 0.8rem;
    color: var(--fg-dim);
  }
  .skill-path {
    padding: 0.6rem 0.75rem;
    border-radius: 3px;
    background: color-mix(in srgb, var(--bg) 82%, transparent);
    overflow-wrap: anywhere;
  }
  .skill-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
  }
  @media (max-width: 720px) {
    .panel-toolbar,
    .section-header,
    .skill-card header {
      flex-direction: column;
    }
    .skill-meta {
      grid-template-columns: 1fr;
    }
  }
</style>
