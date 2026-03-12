<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import { api } from "$lib/api/client";

  let {
    providers = [],
    value = "[]",
    onchange = (v: string) => {},
    component = "",
    validationResults = [] as Array<{ provider: string; live_ok: boolean; reason: string }>,
  } = $props();

  const LOCAL_PROVIDERS = ["ollama", "lm-studio", "claude-cli", "codex-cli", "openai-codex"];
  const MODEL_RESULTS_LIMIT = 80;

  type ProviderOption = {
    value: string;
    label: string;
    recommended?: boolean;
  };

  type ProviderEntry = {
    provider: string;
    api_key: string;
    model: string;
  };

  let savedProviders = $state<any[]>([]);
  let showSavedDropdown = $state(false);
  let savedProvidersRevealed = $state(false);
  let loadingSavedProviders = $state(false);
  let modelDropdownOpen = $state<Record<number, boolean>>({});
  let modelLoadingByKey = $state<Record<string, boolean>>({});
  let modelLoadedByKey = $state<Record<string, boolean>>({});
  let modelOptionsByKey = $state<Record<string, string[]>>({});
  let modelErrorsByKey = $state<Record<string, string>>({});

  const modelBlurTimers = new Map<number, ReturnType<typeof setTimeout>>();

  onMount(async () => {
    try {
      const data = await api.getSavedProviders();
      savedProviders = data.providers || [];
    } catch {}
  });

  onDestroy(() => {
    for (const timer of modelBlurTimers.values()) clearTimeout(timer);
    modelBlurTimers.clear();
  });

  async function toggleSavedDropdown() {
    if (showSavedDropdown) {
      showSavedDropdown = false;
      return;
    }

    if (!savedProvidersRevealed && savedProviders.length > 0) {
      loadingSavedProviders = true;
      try {
        const data = await api.getSavedProviders(true);
        savedProviders = data.providers || [];
        savedProvidersRevealed = true;
      } catch {
        loadingSavedProviders = false;
        return;
      }
      loadingSavedProviders = false;
    }

    showSavedDropdown = true;
  }

  function isPlaceholderEntry(entry: ProviderEntry) {
    return entry.api_key.trim().length === 0 && entry.model.trim().length === 0;
  }

  function useSaved(sp: any) {
    const savedEntry = {
      provider: sp.provider,
      api_key: sp.api_key,
      model: sp.model || "",
    };

    if (entries.length === 1 && isPlaceholderEntry(entries[0])) {
      entries = [savedEntry];
    } else {
      entries = [
        ...entries,
        savedEntry,
      ];
    }
    showSavedDropdown = false;
    emitChange();
  }

  let entries = $state<ProviderEntry[]>([]);

  // Sync entries from value prop
  $effect(() => {
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) {
        entries = parsed;
      }
    } catch {
      entries = [];
    }
  });

  function emitChange() {
    onchange(JSON.stringify(entries));
  }

  function addEntry() {
    // Find recommended provider or first available
    const rec = providers.find((p: any) => p.recommended);
    const defaultProvider = rec?.value || providers[0]?.value || "";
    entries = [
      ...entries,
      { provider: defaultProvider, api_key: "", model: "" },
    ];
    emitChange();
  }

  function removeEntry(index: number) {
    entries = entries.filter((_: any, i: number) => i !== index);
    emitChange();
  }

  function moveUp(index: number) {
    if (index <= 0) return;
    const newEntries = [...entries];
    [newEntries[index - 1], newEntries[index]] = [
      newEntries[index],
      newEntries[index - 1],
    ];
    entries = newEntries;
    emitChange();
  }

  function moveDown(index: number) {
    if (index >= entries.length - 1) return;
    const newEntries = [...entries];
    [newEntries[index], newEntries[index + 1]] = [
      newEntries[index + 1],
      newEntries[index],
    ];
    entries = newEntries;
    emitChange();
  }

  function updateEntry(index: number, field: string, val: string) {
    entries = entries.map((e: any, i: number) =>
      i === index ? { ...e, [field]: val } : e,
    );
    emitChange();
  }

  function isLocal(provider: string) {
    return LOCAL_PROVIDERS.includes(provider);
  }

  function normalizeRecommendedLabel(label: string) {
    return label
      .replace(/\(\s*recommended\s*\)/gi, "")
      .replace(/,\s*recommended/gi, "")
      .replace(/\s+recommended\s*$/gi, "")
      .replace(/\(\s*,/g, "(")
      .replace(/,\s*\)/g, ")")
      .replace(/\(\s*\)/g, "")
      .replace(/\s{2,}/g, " ")
      .trim();
  }

  function formatRecommendedLabel(label: string, recommended = false) {
    const cleaned = recommended ? normalizeRecommendedLabel(label) : label;
    return recommended && !/recommended/i.test(cleaned)
      ? `${cleaned} (recommended)`
      : cleaned;
  }

  function modelKey(entry: ProviderEntry) {
    return `${entry.provider}\u0000${entry.api_key}`;
  }

  function getModelOptions(entry: ProviderEntry) {
    return modelOptionsByKey[modelKey(entry)] || [];
  }

  function getModelError(entry: ProviderEntry) {
    return modelErrorsByKey[modelKey(entry)] || "";
  }

  function isModelLoading(entry: ProviderEntry) {
    return Boolean(modelLoadingByKey[modelKey(entry)]);
  }

  async function ensureModelOptions(entry: ProviderEntry) {
    if (!component || !entry.provider) return;

    const key = modelKey(entry);
    if (modelLoadingByKey[key] || modelLoadedByKey[key]) return;

    modelLoadingByKey = { ...modelLoadingByKey, [key]: true };
    modelErrorsByKey = { ...modelErrorsByKey, [key]: "" };

    try {
      const data = await api.getWizardModels(component, entry.provider, entry.api_key || "");
      const models = Array.isArray(data)
        ? data
        : Array.isArray(data?.models)
          ? data.models
          : [];
      const normalized = models.filter((model): model is string => typeof model === "string");
      modelOptionsByKey = { ...modelOptionsByKey, [key]: normalized };
      modelLoadedByKey = { ...modelLoadedByKey, [key]: true };
    } catch (error) {
      modelErrorsByKey = {
        ...modelErrorsByKey,
        [key]: error instanceof Error ? error.message : "Unable to load models",
      };
    } finally {
      modelLoadingByKey = { ...modelLoadingByKey, [key]: false };
    }
  }

  function openModelDropdown(index: number) {
    const timer = modelBlurTimers.get(index);
    if (timer) {
      clearTimeout(timer);
      modelBlurTimers.delete(index);
    }

    modelDropdownOpen = { ...modelDropdownOpen, [index]: true };
    const entry = entries[index];
    if (entry) void ensureModelOptions(entry);
  }

  function closeModelDropdown(index: number) {
    const timer = modelBlurTimers.get(index);
    if (timer) {
      clearTimeout(timer);
      modelBlurTimers.delete(index);
    }

    modelDropdownOpen = { ...modelDropdownOpen, [index]: false };
  }

  function scheduleModelDropdownClose(index: number) {
    const timer = modelBlurTimers.get(index);
    if (timer) clearTimeout(timer);
    modelBlurTimers.set(
      index,
      setTimeout(() => {
        modelDropdownOpen = { ...modelDropdownOpen, [index]: false };
        modelBlurTimers.delete(index);
      }, 150),
    );
  }

  function handleModelInput(index: number, value: string) {
    updateEntry(index, "model", value);
    modelDropdownOpen = { ...modelDropdownOpen, [index]: true };
    const entry = entries[index];
    if (entry) void ensureModelOptions(entry);
  }

  function selectModel(index: number, model: string) {
    updateEntry(index, "model", model);
    closeModelDropdown(index);
  }

  function getFilteredModels(entry: ProviderEntry) {
    const models = getModelOptions(entry);
    const query = entry.model.trim().toLowerCase();
    if (!query) return models.slice(0, MODEL_RESULTS_LIMIT);

    const startsWith = models.filter((model) => model.toLowerCase().startsWith(query));
    const includes = models.filter(
      (model) => !model.toLowerCase().startsWith(query) && model.toLowerCase().includes(query),
    );
    return [...startsWith, ...includes].slice(0, MODEL_RESULTS_LIMIT);
  }

  function getFilteredModelCount(entry: ProviderEntry) {
    const models = getModelOptions(entry);
    const query = entry.model.trim().toLowerCase();
    if (!query) return models.length;
    return models.filter((model) => model.toLowerCase().includes(query)).length;
  }

  function modelPlaceholder(entry: ProviderEntry) {
    if (entry.provider === "codex-cli" || entry.provider === "openai-codex") {
      return "e.g. gpt-5.4";
    }
    return "e.g. anthropic/claude-sonnet-4";
  }

  function modelFieldHint(entry: ProviderEntry) {
    if (entry.provider === "codex-cli") {
      return "Loads models from your local Codex cache in ~/.codex/models_cache.json.";
    }
    if (entry.provider === "openai-codex") {
      return "Uses ChatGPT/Codex auth from ~/.codex/auth.json. No API key required here.";
    }
    return "Click to load models, then filter as you type.";
  }
</script>

<div class="provider-list">
  <div class="step-title">Providers</div>
  <p class="step-description">
    Configure AI providers in fallback order. First provider is primary.
  </p>

  {#each entries as entry, i}
    <div class="provider-row">
      <div class="provider-row-header">
        <span class="provider-number">{i + 1}.</span>
        {#each [validationResults.find((r: any) => r.provider === entry.provider)] as result}
          {#if result}
            <span class="status-dot" class:ok={result.live_ok} class:error={!result.live_ok}
              title={result.reason}></span>
          {/if}
        {/each}
        <select
          value={entry.provider}
          onchange={(e) => updateEntry(i, "provider", e.currentTarget.value)}
        >
          {#each providers as opt}
            <option value={opt.value}
              >{formatRecommendedLabel(opt.label, opt.recommended)}</option
            >
          {/each}
        </select>
        <div class="provider-row-actions">
          <button
            class="icon-btn"
            onclick={() => moveUp(i)}
            disabled={i === 0}
            title="Move up">&#8593;</button
          >
          <button
            class="icon-btn"
            onclick={() => moveDown(i)}
            disabled={i === entries.length - 1}
            title="Move down">&#8595;</button
          >
          <button
            class="icon-btn remove-btn"
            onclick={() => removeEntry(i)}
            title="Remove">&#215;</button
          >
        </div>
      </div>

      {#if !isLocal(entry.provider)}
        <div class="provider-field">
          <label for={`provider-api-key-${i}`}>API Key</label>
          <input
            id={`provider-api-key-${i}`}
            type="password"
            value={entry.api_key}
            oninput={(e) => updateEntry(i, "api_key", e.currentTarget.value)}
            placeholder="Enter API key..."
          />
        </div>
      {/if}

      <div class="provider-field">
        <label for={`provider-model-${i}`}>Model</label>
        <div class="model-picker">
          <input
            id={`provider-model-${i}`}
            type="text"
            value={entry.model}
            oninput={(e) => handleModelInput(i, e.currentTarget.value)}
            onfocus={() => openModelDropdown(i)}
            onblur={() => scheduleModelDropdownClose(i)}
            placeholder={modelPlaceholder(entry)}
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
          />

          {#if modelDropdownOpen[i]}
            {@const filteredModels = getFilteredModels(entry)}
            {@const totalMatches = getFilteredModelCount(entry)}
            <div class="model-dropdown">
              {#if isModelLoading(entry)}
                <div class="model-empty">Loading models...</div>
              {:else if filteredModels.length > 0}
                {#each filteredModels as model}
                  <button
                    type="button"
                    class="model-option"
                    class:selected={entry.model === model}
                    onmousedown={(event) => {
                      event.preventDefault();
                      selectModel(i, model);
                    }}
                  >
                    <span class="model-value">{model}</span>
                  </button>
                {/each}
                {#if totalMatches > filteredModels.length}
                  <div class="model-summary">
                    Showing {filteredModels.length} of {totalMatches}. Keep typing to narrow.
                  </div>
                {/if}
              {:else if getModelError(entry)}
                <div class="model-empty model-error">
                  {getModelError(entry)}. You can still type a model manually.
                </div>
              {:else if getModelOptions(entry).length > 0}
                <div class="model-empty">No matches for "{entry.model}".</div>
              {:else}
                <div class="model-empty">
                  No model list returned for {entry.provider}. You can still type one manually.
                </div>
              {/if}
            </div>
          {/if}
        </div>
        <div class="provider-field-hint">{modelFieldHint(entry)}</div>
      </div>
    </div>
  {/each}

  <div class="add-row">
    <button class="add-btn" onclick={addEntry}>+ Add Provider</button>
    {#if savedProviders.length > 0}
      <div class="saved-dropdown-container">
        <button class="add-btn saved-btn" onclick={toggleSavedDropdown} disabled={loadingSavedProviders}>
          {loadingSavedProviders ? "Loading..." : "Use Saved"}
        </button>
        {#if showSavedDropdown}
          <div class="saved-dropdown">
            {#each savedProviders as sp}
              <button class="saved-item" onclick={() => useSaved(sp)}>
                <span class="saved-name">{sp.name}</span>
                <span class="saved-detail">{sp.model || "no model"}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .provider-list {
    margin-bottom: 2rem;
  }

  .step-title {
    display: block;
    font-size: 0.9rem;
    font-weight: 700;
    color: var(--accent);
    margin-bottom: 0.25rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: var(--text-glow);
  }

  .step-description {
    font-size: 0.8rem;
    color: var(--fg-dim);
    margin-bottom: 1rem;
    font-family: var(--font-mono);
  }

  .provider-row {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 1rem;
    margin-bottom: 0.75rem;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
    transition: all 0.2s ease;
  }

  .provider-row:hover {
    border-color: color-mix(in srgb, var(--accent) 50%, transparent);
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.2);
  }

  .provider-row-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.75rem;
    min-width: 0;
  }

  .provider-number {
    font-weight: 700;
    font-size: 0.875rem;
    color: var(--accent-dim);
    min-width: 1.5rem;
    font-family: var(--font-mono);
  }

  .provider-row-header select {
    flex: 1;
    min-width: 0;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.5rem 0.75rem;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
  }

  .provider-row-header select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .provider-row-actions {
    display: flex;
    gap: 0.375rem;
    flex: 0 0 auto;
  }

  .icon-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: color-mix(in srgb, var(--bg-surface) 80%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 1rem;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .icon-btn:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    border-color: var(--accent);
    color: var(--accent);
    box-shadow: 0 0 5px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .icon-btn:disabled {
    opacity: 0.3;
    cursor: not-allowed;
  }

  .remove-btn:hover:not(:disabled) {
    background: color-mix(in srgb, var(--error, #e55) 15%, transparent);
    border-color: var(--error, #e55);
    color: var(--error, #e55);
    box-shadow: 0 0 5px color-mix(in srgb, var(--error, #e55) 50%, transparent);
    text-shadow: 0 0 5px var(--error, #e55);
  }

  .provider-field {
    margin-top: 0.75rem;
  }

  .provider-field label {
    display: block;
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-bottom: 0.35rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .provider-field input {
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

  .provider-field input:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .provider-field-hint {
    margin-top: 0.35rem;
    font-size: 0.72rem;
    color: var(--fg-dim);
    font-family: var(--font-mono);
  }

  .model-picker {
    position: relative;
  }

  .model-dropdown {
    position: absolute;
    top: calc(100% + 0.25rem);
    left: 0;
    right: 0;
    max-height: 280px;
    overflow-y: auto;
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    background: color-mix(in srgb, var(--bg-surface) 94%, transparent);
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.35);
    z-index: 20;
  }

  .model-option {
    display: block;
    width: 100%;
    padding: 0.625rem 0.75rem;
    background: none;
    border: none;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 70%, transparent);
    color: var(--fg);
    text-align: left;
    font-family: var(--font-mono);
    font-size: 0.82rem;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }

  .model-option:last-child {
    border-bottom: none;
  }

  .model-option:hover,
  .model-option.selected {
    background: color-mix(in srgb, var(--accent) 12%, transparent);
    color: var(--accent);
  }

  .model-value {
    word-break: break-all;
  }

  .model-empty,
  .model-summary {
    padding: 0.75rem;
    font-size: 0.78rem;
    color: var(--fg-dim);
    font-family: var(--font-mono);
  }

  .model-error {
    color: var(--error, #e55);
  }

  .add-btn {
    width: 100%;
    padding: 0.75rem;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px dashed color-mix(in srgb, var(--border) 60%, transparent);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .status-dot {
    width: 10px;
    height: 10px;
    border-radius: var(--radius);
    flex-shrink: 0;
  }
  .status-dot.ok {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
  }
  .status-dot.error {
    background: var(--error, #e55);
    box-shadow: 0 0 6px var(--error, #e55);
  }

  .add-btn:hover {
    border-color: var(--accent);
    border-style: solid;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .add-row {
    display: flex;
    gap: 0.5rem;
  }

  .add-row .add-btn {
    flex: 1;
  }

  .saved-dropdown-container {
    position: relative;
    flex: 0 0 auto;
  }

  .saved-btn {
    border-style: solid !important;
    border-color: var(--accent-dim) !important;
    color: var(--accent) !important;
    width: auto !important;
    padding: 0.75rem 1.25rem !important;
  }

  .saved-dropdown {
    position: absolute;
    bottom: 100%;
    right: 0;
    min-width: 220px;
    background: var(--bg-surface);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    margin-bottom: 0.25rem;
    box-shadow: 0 0 15px rgba(0, 0, 0, 0.4);
    z-index: 10;
    max-height: 200px;
    overflow-y: auto;
  }

  .saved-item {
    display: flex;
    flex-direction: column;
    width: 100%;
    padding: 0.625rem 1rem;
    background: none;
    border: none;
    border-bottom: 1px solid var(--border);
    color: var(--fg);
    cursor: pointer;
    text-align: left;
    font-family: var(--font-mono);
    transition: all 0.15s ease;
  }

  .saved-item:last-child {
    border-bottom: none;
  }

  .saved-item:hover {
    background: var(--bg-hover);
    color: var(--accent);
  }

  .saved-name {
    font-size: 0.875rem;
    font-weight: 700;
  }

  .saved-detail {
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-top: 0.125rem;
  }
</style>
