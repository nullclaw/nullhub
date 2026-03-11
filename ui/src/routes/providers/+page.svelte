<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";

  const PROVIDER_OPTIONS = [
    { value: "openrouter", label: "OpenRouter (multi-provider, recommended)", recommended: true },
    { value: "anthropic", label: "Anthropic" },
    { value: "openai", label: "OpenAI" },
    { value: "google", label: "Google AI" },
    { value: "mistral", label: "Mistral" },
    { value: "groq", label: "Groq" },
    { value: "deepseek", label: "DeepSeek" },
    { value: "cohere", label: "Cohere" },
    { value: "together", label: "Together AI" },
    { value: "fireworks", label: "Fireworks AI" },
    { value: "perplexity", label: "Perplexity" },
    { value: "xai", label: "xAI" },
    { value: "ollama", label: "Ollama (local)" },
    { value: "lm-studio", label: "LM Studio (local)" },
    { value: "claude-cli", label: "Claude CLI (local)" },
    { value: "codex-cli", label: "Codex CLI (local)" },
  ];
  const LOCAL_PROVIDERS = ["ollama", "lm-studio", "claude-cli", "codex-cli"];

  let providers = $state<any[]>([]);
  let loading = $state(true);
  let error = $state("");
  let message = $state("");

  // Add form state
  let showAddForm = $state(false);
  let addForm = $state({ provider: "openrouter", api_key: "", model: "" });
  let addValidating = $state(false);
  let addError = $state("");

  // Edit state
  let editingId = $state<string | null>(null);
  let editForm = $state({ name: "", api_key: "", model: "" });
  let editValidating = $state(false);
  let editError = $state("");

  // Re-validate state
  let revalidatingId = $state<string | null>(null);

  let hasComponents = $state(false);

  onMount(async () => {
    await loadProviders();
    try {
      const status = await api.getStatus();
      hasComponents = Object.keys(status.instances || {}).length > 0;
    } catch {}
  });

  async function loadProviders() {
    loading = true;
    error = "";
    try {
      const data = await api.getSavedProviders();
      providers = data.providers || [];
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function handleAdd() {
    addValidating = true;
    addError = "";
    try {
      await api.createSavedProvider({
        provider: addForm.provider,
        api_key: addForm.api_key,
        model: addForm.model || undefined,
      });
      showAddForm = false;
      addForm = { provider: "openrouter", api_key: "", model: "" };
      message = "Provider saved";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addValidating = false;
    }
  }

  function startEdit(p: any) {
    editingId = p.id;
    editForm = { name: p.name, api_key: "", model: p.model };
  }

  function cancelEdit() {
    editingId = null;
  }

  async function saveEdit(id: string) {
    editValidating = true;
    editError = "";
    try {
      const payload: any = {};
      if (editForm.name) payload.name = editForm.name;
      if (editForm.api_key) payload.api_key = editForm.api_key;
      payload.model = editForm.model;
      await api.updateSavedProvider(id, payload);
      editingId = null;
      message = "Provider updated";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      editError = (e as Error).message;
    } finally {
      editValidating = false;
    }
  }

  async function handleDelete(id: string) {
    try {
      await api.deleteSavedProvider(id);
      message = "Provider deleted";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function handleRevalidate(id: string) {
    revalidatingId = id;
    try {
      const result = await api.revalidateSavedProvider(id);
      if (result.live_ok) {
        message = "Validation passed";
      } else {
        message = `Validation failed: ${result.reason || "unknown error"}`;
      }
      setTimeout(() => (message = ""), 5000);
      await loadProviders();
    } catch (e) {
      message = `Validation failed: ${(e as Error).message}`;
      setTimeout(() => (message = ""), 5000);
    } finally {
      revalidatingId = null;
    }
  }

  function isLocal(provider: string) {
    return LOCAL_PROVIDERS.includes(provider);
  }

  function getProviderLabel(value: string) {
    return PROVIDER_OPTIONS.find((p) => p.value === value)?.label || value;
  }

  function formatDate(iso: string) {
    if (!iso) return "";
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        year: "numeric", month: "short", day: "numeric",
        hour: "2-digit", minute: "2-digit",
      });
    } catch { return iso; }
  }
</script>

<div class="providers-page">
  <div class="page-header">
    <h1>Providers</h1>
    {#if hasComponents}
      <button class="primary-btn" onclick={() => (showAddForm = !showAddForm)}>
        {showAddForm ? "Cancel" : "+ Add Provider"}
      </button>
    {/if}
  </div>

  {#if message}
    <div class="message">{message}</div>
  {/if}

  {#if error}
    <div class="error-message">{error}</div>
  {/if}

  {#if !hasComponents}
    <div class="empty-state">
      <p>Install a component first to add providers.</p>
      <a href="/install" class="link-btn">Install Component</a>
    </div>
  {:else if showAddForm}
    <div class="add-form">
      <h2>Add Provider</h2>
      <div class="field">
        <label for="add-provider">Provider</label>
        <select id="add-provider" bind:value={addForm.provider}>
          {#each PROVIDER_OPTIONS as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>
      {#if !isLocal(addForm.provider)}
        <div class="field">
          <label for="add-api-key">API Key</label>
          <input id="add-api-key" type="password" bind:value={addForm.api_key} placeholder="Enter API key..." />
        </div>
      {/if}
      <div class="field">
        <label for="add-model">Model (optional)</label>
        <input id="add-model" type="text" bind:value={addForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
      </div>
      {#if addError}
        <div class="error-message">{addError}</div>
      {/if}
      <button class="primary-btn" onclick={handleAdd} disabled={addValidating}>
        {addValidating ? "Validating..." : "Validate & Save"}
      </button>
    </div>
  {/if}

  {#if loading}
    <p class="loading">Loading providers...</p>
  {:else if providers.length === 0 && hasComponents}
    <div class="empty-state">
      <p>No saved providers yet. Add one above or install a component — providers are saved automatically during setup.</p>
    </div>
  {:else}
    <div class="provider-grid">
      {#each providers as p}
        <div class="provider-card">
          {#if editingId === p.id}
            <div class="edit-form">
              <div class="field">
                <label for="edit-name-{p.id}">Name</label>
                <input id="edit-name-{p.id}" type="text" bind:value={editForm.name} />
              </div>
              {#if !isLocal(p.provider)}
                <div class="field">
                  <label for="edit-key-{p.id}">API Key (leave empty to keep current)</label>
                  <input id="edit-key-{p.id}" type="password" bind:value={editForm.api_key} placeholder="Leave empty to keep current" />
                </div>
              {/if}
              <div class="field">
                <label for="edit-model-{p.id}">Model</label>
                <input id="edit-model-{p.id}" type="text" bind:value={editForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
              </div>
              {#if editError}
                <div class="error-message">{editError}</div>
              {/if}
              <div class="edit-actions">
                <button class="primary-btn" onclick={() => saveEdit(p.id)} disabled={editValidating}>
                  {editValidating ? "Saving..." : "Save"}
                </button>
                <button class="btn" onclick={cancelEdit}>Cancel</button>
              </div>
            </div>
          {:else}
            <div class="card-header">
              <div class="card-title">
                <span class="status-dot" class:validated={!!p.validated_at} class:not-validated={!p.validated_at}></span>
                <h3>{p.name}</h3>
              </div>
              <span class="provider-type">{getProviderLabel(p.provider)}</span>
            </div>
            <div class="card-body">
              <div class="card-field">
                <span class="label">API Key</span>
                <code>{p.api_key}</code>
              </div>
              <div class="card-field">
                <span class="label">Model</span>
                <code>{p.model || "No default model"}</code>
              </div>
              {#if p.validated_at}
                <div class="card-field">
                  <span class="label">Validated</span>
                  <span>{formatDate(p.validated_at)}</span>
                </div>
              {/if}
            </div>
            <div class="card-actions">
              <button class="btn" onclick={() => handleRevalidate(p.id)} disabled={revalidatingId === p.id}>
                {revalidatingId === p.id ? "Validating..." : "Re-validate"}
              </button>
              <button class="btn" onclick={() => startEdit(p)}>Edit</button>
              <button class="btn danger" onclick={() => handleDelete(p.id)}>Delete</button>
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .providers-page {
    max-width: 800px;
    margin: 0 auto;
    padding: 2rem;
  }

  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 2rem;
  }

  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  h2 {
    font-size: 1.125rem;
    font-weight: 700;
    margin-bottom: 1rem;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .add-form, .provider-card {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 1.25rem;
    margin-bottom: 1rem;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .add-form {
    margin-bottom: 2rem;
  }

  .field {
    margin-bottom: 1rem;
  }

  .field label {
    display: block;
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-bottom: 0.35rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .field input, .field select {
    width: 100%;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.5rem 0.75rem;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .field input:focus, .field select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1rem;
  }

  .card-title {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .card-title h3 {
    font-size: 1rem;
    font-weight: 700;
    color: var(--fg);
  }

  .provider-type {
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.validated {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
  }

  .status-dot.not-validated {
    background: var(--warning, #ca0);
    box-shadow: 0 0 6px var(--warning, #ca0);
  }

  .card-body {
    margin-bottom: 1rem;
  }

  .card-field {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.375rem 0;
    border-bottom: 1px dashed color-mix(in srgb, var(--border) 40%, transparent);
  }

  .card-field:last-child {
    border-bottom: none;
  }

  .card-field .label {
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .card-field code {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
  }

  .card-actions, .edit-actions {
    display: flex;
    gap: 0.5rem;
  }

  .btn {
    padding: 0.375rem 0.875rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }

  .btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
  }

  .btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn.danger {
    color: var(--error, #e55);
    border-color: color-mix(in srgb, var(--error, #e55) 50%, transparent);
  }

  .btn.danger:hover:not(:disabled) {
    border-color: var(--error, #e55);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error, #e55) 30%, transparent);
  }

  .primary-btn {
    padding: 0.5rem 1.25rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    box-shadow: 0 0 15px var(--border-glow);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .message {
    padding: 0.875rem 1.25rem;
    background: color-mix(in srgb, var(--success) 10%, transparent);
    border: 1px solid var(--success);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: bold;
    color: var(--success);
    margin-bottom: 1.5rem;
    box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent);
  }

  .error-message {
    padding: 0.875rem 1.25rem;
    background: color-mix(in srgb, var(--error, #e55) 10%, transparent);
    border: 1px solid var(--error, #e55);
    border-radius: 2px;
    font-size: 0.875rem;
    color: var(--error, #e55);
    margin-bottom: 1rem;
  }

  .empty-state {
    text-align: center;
    padding: 3rem;
    color: var(--fg-dim);
  }

  .empty-state p {
    margin-bottom: 1rem;
    font-family: var(--font-mono);
  }

  .link-btn {
    color: var(--accent);
    text-decoration: none;
    border: 1px solid var(--accent);
    padding: 0.5rem 1.25rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-size: 0.875rem;
    transition: all 0.2s ease;
  }

  .link-btn:hover {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    box-shadow: 0 0 10px var(--border-glow);
  }

  .loading {
    color: var(--fg-dim);
    font-family: var(--font-mono);
    text-align: center;
    padding: 2rem;
  }

  .provider-grid {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .edit-form {
    padding: 0.5rem 0;
  }
</style>
