<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import { api } from "$lib/api/client";
  import { PROVIDER_OPTIONS, OPENAI_COMPATIBLE_VALUE, LOCAL_PROVIDERS, KNOWN_PROVIDER_VALUES } from "$lib/providers";


  let providers = $state<any[]>([]);
  let loading = $state(true);
  let error = $state("");
  let message = $state("");
  let messageTone = $state<"success" | "error">("success");
  let messageTimer: ReturnType<typeof setTimeout> | null = null;

  // Add form state
  let showAddForm = $state(false);
  let addForm = $state({ provider: "openrouter", provider_name: "", api_key: "", model: "", base_url: "" });
  let addValidating = $state(false);
  let addError = $state("");
  let addProbing = $state(false);
  let addProbedModels = $state<string[]>([]);
  let addProbeError = $state("");

  // Edit state
  let editingId = $state<string | null>(null);
  let editForm = $state({ name: "", api_key: "", model: "", base_url: "" });
  let editRealApiKey = $state(""); // revealed key fetched on edit open; used by Fetch Models when form field is blank
  let editValidating = $state(false);
  let editError = $state("");
  let editProbing = $state(false);
  let editProbedModels = $state<string[]>([]);
  let editProbeError = $state("");

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

  onDestroy(() => {
    if (messageTimer) clearTimeout(messageTimer);
  });

  function flashMessage(text: string, tone: "success" | "error" = "success", timeoutMs = 3000) {
    message = text;
    messageTone = tone;
    if (messageTimer) clearTimeout(messageTimer);
    messageTimer = setTimeout(() => {
      message = "";
      messageTimer = null;
    }, timeoutMs);
  }

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

  async function fetchAddModels() {
    addProbing = true;
    addProbeError = "";
    addProbedModels = [];
    try {
      const result = await api.probeProviderModels(addForm.base_url.trim(), addForm.api_key.trim());
      if (result.live_ok) {
        addProbedModels = result.models;
        if (!addProbedModels.length) addProbeError = "Connected, but no models returned.";
      } else {
        addProbeError = result.reason || "Could not reach endpoint.";
      }
    } catch (e) {
      addProbeError = (e as Error).message;
    } finally {
      addProbing = false;
    }
  }

  async function fetchEditModels() {
    editProbing = true;
    editProbeError = "";
    editProbedModels = [];
    try {
      const keyToUse = editForm.api_key.trim() || editRealApiKey;
      const result = await api.probeProviderModels(editForm.base_url.trim(), keyToUse);
      if (result.live_ok) {
        editProbedModels = result.models;
        if (!editProbedModels.length) editProbeError = "Connected, but no models returned.";
      } else {
        editProbeError = result.reason || "Could not reach endpoint.";
      }
    } catch (e) {
      editProbeError = (e as Error).message;
    } finally {
      editProbing = false;
    }
  }

  async function handleAdd() {
    addValidating = true;
    addError = "";
    try {
      const providerValue = addForm.provider === OPENAI_COMPATIBLE_VALUE
        ? addForm.provider_name.trim()
        : addForm.provider;
      if (addForm.provider === OPENAI_COMPATIBLE_VALUE && !providerValue) {
        addError = "Provider name is required for OpenAI Compatible providers.";
        addValidating = false;
        return;
      }
      if (addForm.provider === OPENAI_COMPATIBLE_VALUE && !addForm.base_url.trim()) {
        addError = "Base URL is required for OpenAI Compatible providers.";
        addValidating = false;
        return;
      }
      await api.createSavedProvider({
        provider: providerValue,
        api_key: addForm.api_key,
        model: addForm.model || undefined,
        base_url: addForm.base_url || undefined,
      });
      showAddForm = false;
      addForm = { provider: "openrouter", provider_name: "", api_key: "", model: "", base_url: "" };
      addProbedModels = [];
      addProbeError = "";
      flashMessage("Provider saved");
      await loadProviders();
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addValidating = false;
    }
  }

  function startEdit(p: any) {
    editingId = p.id;
    editForm = { name: p.name, api_key: "", model: p.model, base_url: p.base_url || "" };
    editRealApiKey = "";
    editProbedModels = [];
    editProbeError = "";
    // Fetch the real (revealed) key so Fetch Models works without the user re-entering the key
    api.getSavedProviders(true).then(data => {
      const found = (data.providers || []).find((x: any) => x.id === p.id);
      if (found) editRealApiKey = found.api_key || "";
    }).catch(() => {});
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
      payload.base_url = editForm.base_url;
      await api.updateSavedProvider(id, payload);
      editingId = null;
      flashMessage("Provider updated");
      await loadProviders();
    } catch (e) {
      editError = (e as Error).message;
      await loadProviders();
    } finally {
      editValidating = false;
    }
  }

  async function handleDelete(id: string) {
    try {
      await api.deleteSavedProvider(id);
      flashMessage("Provider deleted");
      await loadProviders();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function handleRevalidate(id: string) {
    revalidatingId = id;
    try {
      await api.revalidateSavedProvider(id);
      flashMessage("Validation passed", "success", 5000);
    } catch (e) {
      flashMessage(`Validation failed: ${(e as Error).message}`, "error", 5000);
    } finally {
      await loadProviders();
      revalidatingId = null;
    }
  }

  function isLocal(provider: string) {
    return LOCAL_PROVIDERS.includes(provider);
  }

  // A provider is "custom" if its type is not one of the built-in nullclaw-known providers.
  // This determines whether the base_url / Fetch Models fields appear in edit form.
  function isCustomProvider(p: any) {
    return !KNOWN_PROVIDER_VALUES.has(p.provider);
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

  function providerIndicatorState(provider: any): "live-ok" | "live-error" | "has-history" | "needs-validation" {
    if (provider.last_validation_at) return provider.last_validation_ok ? "live-ok" : "live-error";
    if (provider.validated_at) return "has-history";
    return "needs-validation";
  }

  function lastValidationAt(provider: any) {
    return provider.last_validation_at || provider.validated_at || "";
  }

  $effect(() => {
    // Clear probed models when the add form's base_url or api_key changes
    addForm.base_url;
    addForm.api_key;
    addProbedModels = [];
    addProbeError = "";
  });
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
    <div class="message" class:success={messageTone === "success"} class:error={messageTone === "error"}>{message}</div>
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
      {#if addForm.provider === OPENAI_COMPATIBLE_VALUE}
        <div class="field">
          <label for="add-provider-name">Provider Name</label>
          <input id="add-provider-name" type="text" bind:value={addForm.provider_name} placeholder="e.g. infini-ai, xiaomi-mimo" />
        </div>
        <div class="field">
          <label for="add-base-url">Base URL</label>
          <input id="add-base-url" type="text" bind:value={addForm.base_url} placeholder="https://api.example.com/v1" />
        </div>
      {/if}
      {#if !isLocal(addForm.provider)}
        <div class="field">
          <label for="add-api-key">API Key</label>
          <input id="add-api-key" type="password" bind:value={addForm.api_key} placeholder="Enter API key..." />
        </div>
      {/if}
      {#if addForm.provider === OPENAI_COMPATIBLE_VALUE}
        <div class="field">
          <label for="add-model">Model</label>
          <div class="model-input-row">
            <input id="add-model" type="text" bind:value={addForm.model} placeholder="e.g. gpt-4" />
            <button
              class="btn fetch-models-btn"
              onclick={fetchAddModels}
              disabled={addProbing || !addForm.base_url.trim() || !addForm.api_key.trim()}
              title="Fetch available models from this endpoint"
            >
              {addProbing ? "Fetching..." : "Fetch Models"}
            </button>
          </div>
          {#if addProbeError}
            <div class="probe-error">{addProbeError}</div>
          {/if}
          {#if addProbedModels.length > 0}
            <div class="model-list">
              {#each addProbedModels as m}
                <button
                  class="model-chip"
                  class:selected={addForm.model === m}
                  onclick={() => { addForm.model = m; }}
                >{m}</button>
              {/each}
            </div>
          {/if}
        </div>
      {:else}
        <div class="field">
          <label for="add-model">Model (optional)</label>
          <input id="add-model" type="text" bind:value={addForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
        </div>
      {/if}
      {#if addError}
        <div class="error-message">{addError}</div>
      {/if}
      <button class="primary-btn" onclick={handleAdd} disabled={addValidating}>
        {addValidating ? "Validating..." : "Save"}
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
              {#if isCustomProvider(p)}
                <div class="field">
                  <label for="edit-base-url-{p.id}">Base URL</label>
                  <input id="edit-base-url-{p.id}" type="text" bind:value={editForm.base_url} placeholder="https://api.example.com/v1" />
                </div>
              {/if}
              {#if !isLocal(p.provider)}
                <div class="field">
                  <label for="edit-key-{p.id}">API Key (leave empty to keep current)</label>
                  <input id="edit-key-{p.id}" type="password" bind:value={editForm.api_key} placeholder="Leave empty to keep current" />
                </div>
              {/if}
              <div class="field">
                <label for="edit-model-{p.id}">Model</label>
                {#if isCustomProvider(p)}
                  <div class="model-input-row">
                    <input id="edit-model-{p.id}" type="text" bind:value={editForm.model} placeholder="e.g. gpt-4" />
                    <button
                      class="btn fetch-models-btn"
                      onclick={fetchEditModels}
                      disabled={editProbing || !editForm.base_url.trim()}
                      title="Fetch available models from this endpoint"
                    >
                      {editProbing ? "Fetching..." : "Fetch Models"}
                    </button>
                  </div>
                  {#if editProbeError}
                    <div class="probe-error">{editProbeError}</div>
                  {/if}
                  {#if editProbedModels.length > 0}
                    <div class="model-list">
                      {#each editProbedModels as m}
                        <button
                          class="model-chip"
                          class:selected={editForm.model === m}
                          onclick={() => { editForm.model = m; }}
                        >{m}</button>
                      {/each}
                    </div>
                  {/if}
                {:else}
                  <input id="edit-model-{p.id}" type="text" bind:value={editForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
                {/if}
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
            {@const indicator = providerIndicatorState(p)}
            <div class="card-header">
              <div class="card-title">
                <span
                  class="status-dot"
                  class:live-ok={indicator === "live-ok"}
                  class:live-error={indicator === "live-error"}
                  class:has-history={indicator === "has-history"}
                  class:needs-validation={indicator === "needs-validation"}
                ></span>
                <h3>{p.name}</h3>
              </div>
              <span class="provider-type">{getProviderLabel(p.provider)}</span>
            </div>
            <div class="card-body">
              <div class="card-field">
                <span class="label">API Key</span>
                <code>{p.api_key}</code>
              </div>
              {#if p.base_url}
                <div class="card-field">
                  <span class="label">Base URL</span>
                  <code>{p.base_url}</code>
                </div>
              {/if}
              <div class="card-field">
                <span class="label">Model</span>
                <code>{p.model || "No default model"}</code>
              </div>
              {#if p.validated_at}
                <div class="card-field">
                  <span class="label">Last Successful Validation</span>
                  <span>{formatDate(p.validated_at)}</span>
                </div>
              {/if}
              <div class="card-field">
                <span class="label">Last Validation</span>
                <span>{formatDate(lastValidationAt(p)) || "Never"}</span>
              </div>
              {#if !lastValidationAt(p)}
                <div class="card-note">Not validated yet. Use Re-validate to run a live auth check.</div>
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

  .status-dot.live-ok {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
  }

  .status-dot.live-error {
    background: var(--error, #e55);
    box-shadow: 0 0 6px var(--error, #e55);
  }

  .status-dot.has-history {
    background: var(--accent, #4af);
    box-shadow: 0 0 6px var(--accent, #4af);
  }

  .status-dot.needs-validation {
    background: var(--warning, #ca0);
    box-shadow: 0 0 6px var(--warning, #ca0);
  }

  :global(body.theme-8bit-lobster) .status-dot,
  :global(body.theme-8bit-lobster-light) .status-dot {
    border-radius: var(--radius) !important;
  }

  :global(body.theme-8bit-lobster) .status-dot.live-ok,
  :global(body.theme-8bit-lobster-light) .status-dot.live-ok {
    background: var(--success) !important;
    box-shadow: 0 0 8px var(--success) !important;
  }

  :global(body.theme-8bit-lobster) .status-dot.live-error,
  :global(body.theme-8bit-lobster-light) .status-dot.live-error {
    background: var(--error) !important;
    box-shadow: 0 0 8px var(--error) !important;
  }

  :global(body.theme-8bit-lobster) .status-dot.has-history,
  :global(body.theme-8bit-lobster-light) .status-dot.has-history {
    background: var(--accent) !important;
    box-shadow: 0 0 8px var(--accent) !important;
  }

  .card-body {
    margin-bottom: 1rem;
  }

  .card-note {
    margin-top: 0.75rem;
    font-size: 0.75rem;
    color: var(--fg-dim);
    line-height: 1.5;
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
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: bold;
    margin-bottom: 1.5rem;
  }

  .message.success {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    border: 1px solid var(--success);
    color: var(--success);
    box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent);
  }

  .message.error {
    background: color-mix(in srgb, var(--error, #e55) 10%, transparent);
    border: 1px solid var(--error, #e55);
    color: var(--error, #e55);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error, #e55) 30%, transparent);
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

  .model-input-row {
    display: flex;
    gap: 0.5rem;
    align-items: stretch;
  }

  .model-input-row input {
    flex: 1;
  }

  .fetch-models-btn {
    flex-shrink: 0;
    white-space: nowrap;
  }

  .model-list {
    display: flex;
    flex-wrap: wrap;
    gap: 0.375rem;
    margin-top: 0.5rem;
  }

  .model-chip {
    padding: 0.25rem 0.625rem;
    background: var(--bg-surface);
    color: var(--fg-dim);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-size: 0.75rem;
    font-family: var(--font-mono);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .model-chip:hover {
    border-color: var(--accent-dim);
    color: var(--fg);
  }

  .model-chip.selected {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    border-color: var(--accent);
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .probe-error {
    margin-top: 0.375rem;
    font-size: 0.75rem;
    color: var(--error, #e55);
  }
</style>
