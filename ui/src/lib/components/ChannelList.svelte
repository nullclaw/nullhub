<script lang="ts">
  import { channelSchemas } from './configSchemas';

  let {
    value = {} as Record<string, Record<string, Record<string, any>>>,
    onchange = (v: Record<string, Record<string, Record<string, any>>>) => {},
    validationResults = [] as Array<{ channel: string; account: string; live_ok: boolean; reason: string }>,
  } = $props();

  const DEFAULT_CHANNELS = ['web', 'cli'];

  let addedChannels = $state<Array<{ type: string; account: string }>>([]);
  let showAddPicker = $state(false);

  $effect(() => {
    const entries: Array<{ type: string; account: string }> = [];
    for (const [type, accounts] of Object.entries(value)) {
      if (DEFAULT_CHANNELS.includes(type)) continue;
      for (const account of Object.keys(accounts)) {
        entries.push({ type, account });
      }
    }
    if (entries.length > 0 && addedChannels.length === 0) {
      addedChannels = entries;
    }
  });

  let availableChannelTypes = $derived(
    Object.entries(channelSchemas)
      .filter(([key]) => !DEFAULT_CHANNELS.includes(key))
      .map(([key, schema]) => ({ key, label: schema.label }))
  );

  function addChannel(type: string) {
    const schema = channelSchemas[type];
    const account = schema?.hasAccounts ? 'default' : type;
    addedChannels = [...addedChannels, { type, account }];
    const newValue = { ...value };
    if (!newValue[type]) newValue[type] = {};
    if (!newValue[type][account]) {
      const defaults: Record<string, any> = {};
      for (const field of schema?.fields || []) {
        if (field.default !== undefined) defaults[field.key] = field.default;
      }
      newValue[type][account] = defaults;
    }
    onchange(newValue);
    showAddPicker = false;
  }

  function removeChannel(index: number) {
    const entry = addedChannels[index];
    addedChannels = addedChannels.filter((_, i) => i !== index);
    const newValue = { ...value };
    if (newValue[entry.type]?.[entry.account]) {
      delete newValue[entry.type][entry.account];
      if (Object.keys(newValue[entry.type]).length === 0) {
        delete newValue[entry.type];
      }
    }
    onchange(newValue);
  }

  function updateField(type: string, account: string, key: string, val: any) {
    const newValue = { ...value };
    if (!newValue[type]) newValue[type] = {};
    if (!newValue[type][account]) newValue[type][account] = {};
    newValue[type][account] = { ...newValue[type][account], [key]: val };
    onchange(newValue);
  }

  function getFieldValue(type: string, account: string, key: string, def: any): any {
    return value[type]?.[account]?.[key] ?? def ?? '';
  }

  function getValidationResult(type: string, account: string) {
    return validationResults.find((r: any) => r.channel === type && r.account === account);
  }
</script>

<div class="channel-list">
  <div class="step-title">Channels</div>
  <p class="step-description">
    Where would you like to talk to your bot? Web and CLI are available by default.
  </p>

  {#each DEFAULT_CHANNELS as ch}
    <div class="channel-default">
      <label class="toggle-row">
        <input type="checkbox" checked disabled />
        <span class="channel-label">{channelSchemas[ch]?.label || ch.toUpperCase()}</span>
        <span class="default-badge">default</span>
      </label>
    </div>
  {/each}

  {#each addedChannels as entry, i}
    {@const schema = channelSchemas[entry.type]}
    {@const result = getValidationResult(entry.type, entry.account)}
    <div class="channel-row">
      <div class="channel-row-header">
        {#if result}
          <span class="status-dot" class:ok={result.live_ok} class:error={!result.live_ok}
            title={result.reason}></span>
        {/if}
        <span class="channel-name">{schema?.label || entry.type}</span>
        {#if schema?.hasAccounts}
          <span class="account-name">{entry.account}</span>
        {/if}
        <button class="icon-btn remove-btn" onclick={() => removeChannel(i)} title="Remove">&#215;</button>
      </div>

      <div class="channel-fields">
        {#each schema?.fields || [] as field}
          <div class="channel-field">
            <label for={`ch-${entry.type}-${entry.account}-${field.key}`}>
              {field.label}
              {#if field.hint}
                <span class="field-hint">{field.hint}</span>
              {/if}
            </label>

            {#if field.type === 'password'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="password"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
                placeholder="Enter value..."
              />
            {:else if field.type === 'number'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="number"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, Number(e.currentTarget.value))}
              />
            {:else if field.type === 'toggle'}
              <label class="toggle">
                <input
                  type="checkbox"
                  checked={getFieldValue(entry.type, entry.account, field.key, field.default) === true}
                  onchange={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.checked)}
                />
                <span class="toggle-slider"></span>
              </label>
            {:else if field.type === 'select'}
              <select
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                onchange={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
              >
                {#each field.options || [] as opt}
                  <option value={opt}>{opt}</option>
                {/each}
              </select>
            {:else if field.type === 'list'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="text"
                value={(getFieldValue(entry.type, entry.account, field.key, field.default) || []).join(', ')}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean))}
                placeholder={field.hint || "Comma-separated values..."}
              />
            {:else}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="text"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
                placeholder={field.hint || "Enter value..."}
              />
            {/if}
          </div>
        {/each}
      </div>
    </div>
  {/each}

  {#if showAddPicker}
    <div class="add-picker">
      {#each availableChannelTypes as ct}
        <button class="picker-option" onclick={() => addChannel(ct.key)}>
          {ct.label}
        </button>
      {/each}
      <button class="picker-cancel" onclick={() => (showAddPicker = false)}>Cancel</button>
    </div>
  {:else}
    <button class="add-btn" onclick={() => (showAddPicker = true)}>+ Add Channel</button>
  {/if}
</div>

<style>
  .channel-list { margin-bottom: 2rem; }

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

  .channel-default {
    padding: 0.75rem 1rem;
    margin-bottom: 0.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    display: flex;
    align-items: center;
    opacity: 0.7;
  }

  .toggle-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    cursor: default;
  }

  .toggle-row input[type="checkbox"] { accent-color: var(--accent); }

  .channel-label {
    font-size: 0.875rem;
    font-weight: 700;
    color: var(--fg);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .default-badge {
    font-size: 0.65rem;
    font-weight: 700;
    background: color-mix(in srgb, var(--fg-dim) 20%, transparent);
    color: var(--fg-dim);
    border: 1px solid var(--border);
    padding: 0.1rem 0.35rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .channel-row {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 1rem;
    margin-bottom: 0.75rem;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
    transition: all 0.2s ease;
  }

  .channel-row:hover {
    border-color: color-mix(in srgb, var(--accent) 50%, transparent);
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.2);
  }

  .channel-row-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.75rem;
  }

  .channel-name {
    font-weight: 700;
    font-size: 0.875rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: var(--text-glow);
    flex: 1;
  }

  .account-name {
    font-size: 0.75rem;
    color: var(--fg-dim);
    font-family: var(--font-mono);
  }

  .channel-fields { display: flex; flex-direction: column; gap: 0.75rem; }

  .channel-field label {
    display: block;
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-bottom: 0.35rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .field-hint {
    font-weight: 400;
    font-size: 0.65rem;
    color: color-mix(in srgb, var(--fg-dim) 70%, transparent);
    letter-spacing: 0;
    text-transform: none;
    margin-left: 0.5rem;
  }

  .channel-field input,
  .channel-field select {
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

  .channel-field input:focus,
  .channel-field select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
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
  .remove-btn:hover {
    background: color-mix(in srgb, var(--error, #e55) 15%, transparent);
    border-color: var(--error, #e55);
    color: var(--error, #e55);
    box-shadow: 0 0 5px color-mix(in srgb, var(--error, #e55) 50%, transparent);
  }

  .add-picker {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    padding: 1rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
  }

  .picker-option {
    padding: 0.5rem 0.75rem;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.8rem;
    font-family: var(--font-mono);
    cursor: pointer;
    transition: all 0.2s ease;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .picker-option:hover {
    border-color: var(--accent);
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .picker-cancel {
    padding: 0.5rem 0.75rem;
    background: none;
    border: 1px dashed var(--border);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 0.8rem;
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .picker-cancel:hover { border-color: var(--fg-dim); color: var(--fg); }

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
  .add-btn:hover {
    border-color: var(--accent);
    border-style: solid;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
    cursor: pointer;
  }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .toggle-slider {
    position: absolute;
    inset: 0;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.5);
  }
  .toggle-slider::before {
    content: "";
    position: absolute;
    width: 16px;
    height: 16px;
    left: 4px;
    top: 3px;
    background: var(--fg-dim);
    border-radius: 2px;
    transition: all 0.2s ease;
  }
  .toggle input:checked + .toggle-slider {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  .toggle input:checked + .toggle-slider::before {
    transform: translateX(18px);
    background: var(--accent);
    box-shadow: 0 0 5px var(--border-glow);
  }
</style>
