<script lang="ts">
  import { api } from "$lib/api/client";

  let {
    providers = [],
    value = "[]",
    onchange = (v: string) => {},
    component = "",
    validationResults = [] as Array<{ provider: string; live_ok: boolean; reason: string }>,
  } = $props();

  const LOCAL_PROVIDERS = ["ollama", "lm-studio", "claude-cli", "codex-cli"];

  let entries = $state<
    Array<{ provider: string; api_key: string; model: string }>
  >([]);

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

  function getProviderLabel(providerValue: string) {
    return (
      providers.find((p: any) => p.value === providerValue)?.label ||
      providerValue
    );
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
              >{opt.label}{opt.recommended ? " (recommended)" : ""}</option
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
        <input
          id={`provider-model-${i}`}
          type="text"
          value={entry.model}
          oninput={(e) => updateEntry(i, "model", e.currentTarget.value)}
          placeholder="e.g. anthropic/claude-sonnet-4"
        />
      </div>
    </div>
  {/each}

  <button class="add-btn" onclick={addEntry}>+ Add Provider</button>
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
    border-radius: 50%;
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
</style>
