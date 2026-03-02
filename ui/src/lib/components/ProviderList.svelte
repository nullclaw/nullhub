<script lang="ts">
  import { api } from '$lib/api/client';

  let { providers = [], value = '[]', onchange = (v: string) => {}, component = '' } = $props();

  const LOCAL_PROVIDERS = ['ollama', 'lm-studio', 'claude-cli', 'codex-cli'];

  let entries = $state<Array<{provider: string, api_key: string, model: string}>>([]);

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
    const defaultProvider = rec?.value || providers[0]?.value || '';
    entries = [...entries, { provider: defaultProvider, api_key: '', model: '' }];
    emitChange();
  }

  function removeEntry(index: number) {
    entries = entries.filter((_: any, i: number) => i !== index);
    emitChange();
  }

  function moveUp(index: number) {
    if (index <= 0) return;
    const newEntries = [...entries];
    [newEntries[index - 1], newEntries[index]] = [newEntries[index], newEntries[index - 1]];
    entries = newEntries;
    emitChange();
  }

  function moveDown(index: number) {
    if (index >= entries.length - 1) return;
    const newEntries = [...entries];
    [newEntries[index], newEntries[index + 1]] = [newEntries[index + 1], newEntries[index]];
    entries = newEntries;
    emitChange();
  }

  function updateEntry(index: number, field: string, val: string) {
    entries = entries.map((e: any, i: number) => i === index ? { ...e, [field]: val } : e);
    emitChange();
  }

  function isLocal(provider: string) {
    return LOCAL_PROVIDERS.includes(provider);
  }

  function getProviderLabel(providerValue: string) {
    return providers.find((p: any) => p.value === providerValue)?.label || providerValue;
  }
</script>

<div class="provider-list">
  <label class="step-title">Providers</label>
  <p class="step-description">Configure AI providers in fallback order. First provider is primary.</p>

  {#each entries as entry, i}
    <div class="provider-row">
      <div class="provider-row-header">
        <span class="provider-number">{i + 1}.</span>
        <select
          value={entry.provider}
          onchange={(e) => updateEntry(i, 'provider', e.currentTarget.value)}
        >
          {#each providers as opt}
            <option value={opt.value}>{opt.label}{opt.recommended ? ' (recommended)' : ''}</option>
          {/each}
        </select>
        <div class="provider-row-actions">
          <button class="icon-btn" onclick={() => moveUp(i)} disabled={i === 0} title="Move up">&#8593;</button>
          <button class="icon-btn" onclick={() => moveDown(i)} disabled={i === entries.length - 1} title="Move down">&#8595;</button>
          <button class="icon-btn remove-btn" onclick={() => removeEntry(i)} title="Remove">&#215;</button>
        </div>
      </div>

      {#if !isLocal(entry.provider)}
        <div class="provider-field">
          <label>API Key</label>
          <input
            type="password"
            value={entry.api_key}
            oninput={(e) => updateEntry(i, 'api_key', e.currentTarget.value)}
            placeholder="Enter API key..."
          />
        </div>
      {/if}

      <div class="provider-field">
        <label>Model</label>
        <input
          type="text"
          value={entry.model}
          oninput={(e) => updateEntry(i, 'model', e.currentTarget.value)}
          placeholder="e.g. anthropic/claude-sonnet-4"
        />
      </div>
    </div>
  {/each}

  <button class="add-btn" onclick={addEntry}>+ Add Provider</button>
</div>

<style>
  .provider-list {
    margin-bottom: 1.5rem;
  }

  .step-title {
    display: block;
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 0.25rem;
  }

  .step-description {
    font-size: 0.8rem;
    color: var(--text-secondary);
    margin-bottom: 0.75rem;
  }

  .provider-row {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.75rem;
    margin-bottom: 0.5rem;
  }

  .provider-row-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 0.5rem;
  }

  .provider-number {
    font-weight: 600;
    font-size: 0.85rem;
    color: var(--text-secondary);
    min-width: 1.5rem;
  }

  .provider-row-header select {
    flex: 1;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 0.4rem 0.5rem;
    color: var(--text-primary);
    font-size: 0.85rem;
    font-family: var(--font-sans);
  }

  .provider-row-actions {
    display: flex;
    gap: 0.25rem;
  }

  .icon-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: 0.85rem;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }

  .icon-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    color: var(--text-primary);
  }

  .icon-btn:disabled {
    opacity: 0.3;
    cursor: not-allowed;
  }

  .remove-btn:hover:not(:disabled) {
    border-color: var(--error, #e55);
    color: var(--error, #e55);
  }

  .provider-field {
    margin-top: 0.5rem;
  }

  .provider-field label {
    display: block;
    font-size: 0.75rem;
    color: var(--text-secondary);
    margin-bottom: 0.2rem;
  }

  .provider-field input {
    width: 100%;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 0.4rem 0.5rem;
    color: var(--text-primary);
    font-size: 0.85rem;
    font-family: var(--font-sans);
    outline: none;
    transition: border-color 0.15s;
  }

  .provider-field input:focus {
    border-color: var(--accent);
  }

  .add-btn {
    width: 100%;
    padding: 0.5rem;
    background: none;
    border: 1px dashed var(--border);
    border-radius: var(--radius);
    color: var(--text-secondary);
    font-size: 0.85rem;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s;
  }

  .add-btn:hover {
    border-color: var(--accent);
    color: var(--accent);
  }
</style>
