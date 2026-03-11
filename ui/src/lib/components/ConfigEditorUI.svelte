<script lang="ts">
  import { channelSchemas, staticSections, type FieldDef } from './configSchemas';

  let { config = $bindable({}), onchange = () => {} }: {
    config: any;
    onchange: () => void;
  } = $props();

  let openSections = $state<Record<string, boolean>>({});
  let addChannelOpen = $state(false);

  function toggle(key: string) {
    openSections[key] = !openSections[key];
  }

  function getPath(obj: any, path: string): any {
    return path.split('.').reduce((o, k) => o?.[k], obj);
  }

  function setPath(obj: any, path: string, value: any): any {
    const clone = JSON.parse(JSON.stringify(obj));
    const keys = path.split('.');
    let cur = clone;
    for (let i = 0; i < keys.length - 1; i++) {
      if (cur[keys[i]] === undefined || cur[keys[i]] === null) cur[keys[i]] = {};
      cur = cur[keys[i]];
    }
    cur[keys[keys.length - 1]] = value;
    return clone;
  }

  function updateField(path: string, value: any) {
    config = setPath(config, path, value);
    onchange();
  }

  let providers = $derived(Object.keys(config?.models?.providers || {}));

  let modelFallbacks = $derived((config?.reliability?.model_fallbacks || []) as string[]);
  let fallbackProviders = $derived((config?.reliability?.fallback_providers || []) as string[]);

  let configuredChannels = $derived(Object.keys(config?.channels || {}));

  function getChannelAccounts(channelType: string): string[] {
    const ch = config?.channels?.[channelType];
    if (!ch) return [];
    if (ch.accounts) return Object.keys(ch.accounts);
    return [];
  }

  function addChannel(type: string) {
    const schema = channelSchemas[type];
    if (!schema) return;
    if (type === 'cli') {
      updateField('channels.cli', true);
    } else if (schema.hasAccounts) {
      const defaults: Record<string, any> = { account_id: 'default' };
      for (const f of schema.fields) {
        if (f.default !== undefined) {
          const parts = f.key.split('.');
          if (parts.length === 1) {
            defaults[f.key] = f.default;
          } else {
            let cur: any = defaults;
            for (let i = 0; i < parts.length - 1; i++) {
              if (!cur[parts[i]]) cur[parts[i]] = {};
              cur = cur[parts[i]];
            }
            cur[parts[parts.length - 1]] = f.default;
          }
        }
      }
      updateField(`channels.${type}`, { accounts: { default: defaults } });
    } else {
      const defaults: Record<string, any> = {};
      for (const f of schema.fields) {
        if (f.default !== undefined) defaults[f.key] = f.default;
      }
      updateField(`channels.${type}`, defaults);
    }
    addChannelOpen = false;
    openSections[`channel-${type}`] = true;
  }

  function removeChannel(type: string) {
    const clone = JSON.parse(JSON.stringify(config));
    if (clone.channels) delete clone.channels[type];
    config = clone;
    onchange();
  }

  function parseList(value: any): string {
    if (Array.isArray(value)) return value.join('\n');
    return '';
  }

  function toList(text: string): string[] {
    return text.split('\n').map(s => s.trim()).filter(Boolean);
  }

  function fieldId(path: string): string {
    return `cfg-${path.replace(/[^a-zA-Z0-9_-]/g, '-')}`;
  }

  let availableChannels = $derived(
    Object.entries(channelSchemas)
      .filter(([key]) => !configuredChannels.includes(key))
      .map(([key, schema]) => ({ key, label: schema.label }))
  );
</script>

<div class="config-ui">
  <!-- Models & Providers section (staticSections[0]) -->
  <div class="section">
    <button class="accordion-header" onclick={() => toggle('models')}>
      <span class="accordion-arrow" class:open={openSections['models']}>&#9654;</span>
      <span>{staticSections[0].label}</span>
    </button>
    {#if openSections['models']}
      <div class="accordion-body">
        {#each staticSections[0].fields as field}
          {@const inputId = fieldId(field.key)}
          {#if field.type === 'number'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="number"
                value={getPath(config, field.key) ?? field.default ?? ''}
                step={field.step}
                min={field.min}
                max={field.max}
                oninput={(e) => updateField(field.key, Number(e.currentTarget.value))}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'text'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="text"
                value={getPath(config, field.key) ?? ''}
                oninput={(e) => updateField(field.key, e.currentTarget.value)}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {/if}
        {/each}

        <!-- Dynamic provider API keys -->
        {#each providers as provider}
          {@const apiKeyId = fieldId(`models.providers.${provider}.api_key`)}
          <div class="provider-row">
            <div class="provider-name">{provider}</div>
            <div class="field">
              <label for={apiKeyId}>API Key</label>
              <input
                id={apiKeyId}
                type="password"
                value={getPath(config, `models.providers.${provider}.api_key`) ?? ''}
                oninput={(e) => updateField(`models.providers.${provider}.api_key`, e.currentTarget.value)}
              />
            </div>
          </div>
        {/each}

        <!-- Model Fallbacks -->
        <div class="field">
          <label for={fieldId('reliability.model_fallbacks')}>Model Fallbacks</label>
          <textarea
            id={fieldId('reliability.model_fallbacks')}
            value={parseList(modelFallbacks)}
            oninput={(e) => updateField('reliability.model_fallbacks', toList(e.currentTarget.value))}
            rows="3"
          ></textarea>
          <p class="hint">One model per line</p>
        </div>

        <!-- Fallback Providers -->
        <div class="field">
          <label for={fieldId('reliability.fallback_providers')}>Fallback Providers</label>
          <textarea
            id={fieldId('reliability.fallback_providers')}
            value={parseList(fallbackProviders)}
            oninput={(e) => updateField('reliability.fallback_providers', toList(e.currentTarget.value))}
            rows="3"
          ></textarea>
          <p class="hint">One provider per line</p>
        </div>
      </div>
    {/if}
  </div>

  <!-- Channels heading -->
  <div class="channels-heading">Channels</div>

  <!-- Configured channels -->
  {#each configuredChannels as channelType}
    {@const schema = channelSchemas[channelType]}
    {#if schema}
      <div class="section">
        <div class="accordion-header channel-header" role="button" tabindex="0" onclick={() => toggle(`channel-${channelType}`)} onkeydown={(e) => { if (e.key === 'Enter' || e.key === ' ') toggle(`channel-${channelType}`); }}>
          <div class="accordion-left">
            <span class="accordion-arrow" class:open={openSections[`channel-${channelType}`]}>&#9654;</span>
            <span>{schema.label}</span>
          </div>
          <button
            class="remove-btn"
            onclick={(e) => { e.stopPropagation(); removeChannel(channelType); }}
          >&#10005;</button>
        </div>
        {#if openSections[`channel-${channelType}`]}
          <div class="accordion-body">
            {#if channelType === 'cli'}
              <p class="cli-note">CLI channel enabled</p>
            {:else if schema.hasAccounts}
              {#each getChannelAccounts(channelType) as accountId}
                <div class="account-label">Account: {accountId}</div>
                {#each schema.fields as field}
                  {@const path = `channels.${channelType}.accounts.${accountId}.${field.key}`}
                  {@const value = getPath(config, path)}
                  {@const inputId = fieldId(path)}
                  {#if field.type === 'toggle'}
                    <label class="toggle-field">
                      <input
                        type="checkbox"
                        checked={!!value}
                        onchange={(e) => updateField(path, e.currentTarget.checked)}
                      />
                      <span>{field.label}</span>
                    </label>
                  {:else if field.type === 'number'}
                    <div class="field">
                      <label for={inputId}>{field.label}</label>
                      <input
                        id={inputId}
                        type="number"
                        value={value ?? field.default ?? ''}
                        step={field.step}
                        min={field.min}
                        max={field.max}
                        oninput={(e) => updateField(path, Number(e.currentTarget.value))}
                      />
                      {#if field.hint}
                        <p class="hint">{field.hint}</p>
                      {/if}
                    </div>
                  {:else if field.type === 'text'}
                    <div class="field">
                      <label for={inputId}>{field.label}</label>
                      <input
                        id={inputId}
                        type="text"
                        value={value ?? ''}
                        oninput={(e) => updateField(path, e.currentTarget.value)}
                      />
                      {#if field.hint}
                        <p class="hint">{field.hint}</p>
                      {/if}
                    </div>
                  {:else if field.type === 'password'}
                    <div class="field">
                      <label for={inputId}>{field.label}</label>
                      <input
                        id={inputId}
                        type="password"
                        value={value ?? ''}
                        oninput={(e) => updateField(path, e.currentTarget.value)}
                      />
                      {#if field.hint}
                        <p class="hint">{field.hint}</p>
                      {/if}
                    </div>
                  {:else if field.type === 'select'}
                    <div class="field">
                      <label for={inputId}>{field.label}</label>
                      <select id={inputId} onchange={(e) => updateField(path, e.currentTarget.value)}>
                        {#each field.options ?? [] as opt}
                          <option value={opt} selected={value === opt}>{opt}</option>
                        {/each}
                      </select>
                      {#if field.hint}
                        <p class="hint">{field.hint}</p>
                      {/if}
                    </div>
                  {:else if field.type === 'list'}
                    <div class="field">
                      <label for={inputId}>{field.label}</label>
                      <textarea
                        id={inputId}
                        value={parseList(value)}
                        oninput={(e) => updateField(path, toList(e.currentTarget.value))}
                        rows="3"
                      ></textarea>
                      {#if field.hint}
                        <p class="hint">{field.hint}</p>
                      {/if}
                    </div>
                  {/if}
                {/each}
              {/each}
            {:else}
              {#each schema.fields as field}
                {@const path = `channels.${channelType}.${field.key}`}
                {@const value = getPath(config, path)}
                {@const inputId = fieldId(path)}
                {#if field.type === 'toggle'}
                  <label class="toggle-field">
                    <input
                      type="checkbox"
                      checked={!!value}
                      onchange={(e) => updateField(path, e.currentTarget.checked)}
                    />
                    <span>{field.label}</span>
                  </label>
                {:else if field.type === 'number'}
                  <div class="field">
                    <label for={inputId}>{field.label}</label>
                    <input
                      id={inputId}
                      type="number"
                      value={value ?? field.default ?? ''}
                      step={field.step}
                      min={field.min}
                      max={field.max}
                      oninput={(e) => updateField(path, Number(e.currentTarget.value))}
                    />
                    {#if field.hint}
                      <p class="hint">{field.hint}</p>
                    {/if}
                  </div>
                {:else if field.type === 'text'}
                  <div class="field">
                    <label for={inputId}>{field.label}</label>
                    <input
                      id={inputId}
                      type="text"
                      value={value ?? ''}
                      oninput={(e) => updateField(path, e.currentTarget.value)}
                    />
                    {#if field.hint}
                      <p class="hint">{field.hint}</p>
                    {/if}
                  </div>
                {:else if field.type === 'password'}
                  <div class="field">
                    <label for={inputId}>{field.label}</label>
                    <input
                      id={inputId}
                      type="password"
                      value={value ?? ''}
                      oninput={(e) => updateField(path, e.currentTarget.value)}
                    />
                    {#if field.hint}
                      <p class="hint">{field.hint}</p>
                    {/if}
                  </div>
                {:else if field.type === 'select'}
                  <div class="field">
                    <label for={inputId}>{field.label}</label>
                    <select id={inputId} onchange={(e) => updateField(path, e.currentTarget.value)}>
                      {#each field.options ?? [] as opt}
                        <option value={opt} selected={value === opt}>{opt}</option>
                      {/each}
                    </select>
                    {#if field.hint}
                      <p class="hint">{field.hint}</p>
                    {/if}
                  </div>
                {:else if field.type === 'list'}
                  <div class="field">
                    <label for={inputId}>{field.label}</label>
                    <textarea
                      id={inputId}
                      value={parseList(value)}
                      oninput={(e) => updateField(path, toList(e.currentTarget.value))}
                      rows="3"
                    ></textarea>
                    {#if field.hint}
                      <p class="hint">{field.hint}</p>
                    {/if}
                  </div>
                {/if}
              {/each}
            {/if}
          </div>
        {/if}
      </div>
    {/if}
  {/each}

  <!-- Add Channel button + dropdown -->
  <div class="add-channel">
    <button class="add-channel-btn" onclick={() => addChannelOpen = !addChannelOpen}>
      + Add Channel
    </button>
    {#if addChannelOpen}
      <div class="add-channel-dropdown">
        {#each availableChannels as ch}
          <button onclick={() => addChannel(ch.key)}>{ch.label}</button>
        {/each}
        {#if availableChannels.length === 0}
          <button disabled>All channels configured</button>
        {/if}
      </div>
    {/if}
  </div>

  <!-- Agent section (staticSections[1]) -->
  <div class="section">
    <button class="accordion-header" onclick={() => toggle('agent')}>
      <span class="accordion-arrow" class:open={openSections['agent']}>&#9654;</span>
      <span>{staticSections[1].label}</span>
    </button>
    {#if openSections['agent']}
      <div class="accordion-body">
        {#each staticSections[1].fields as field}
          {@const value = getPath(config, field.key)}
          {@const inputId = fieldId(field.key)}
          {#if field.type === 'toggle'}
            <label class="toggle-field">
              <input
                type="checkbox"
                checked={!!value}
                onchange={(e) => updateField(field.key, e.currentTarget.checked)}
              />
              <span>{field.label}</span>
            </label>
          {:else if field.type === 'number'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="number"
                value={value ?? field.default ?? ''}
                step={field.step}
                min={field.min}
                max={field.max}
                oninput={(e) => updateField(field.key, Number(e.currentTarget.value))}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'text'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="text"
                value={value ?? ''}
                oninput={(e) => updateField(field.key, e.currentTarget.value)}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'select'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <select id={inputId} onchange={(e) => updateField(field.key, e.currentTarget.value)}>
                {#each field.options ?? [] as opt}
                  <option value={opt} selected={value === opt}>{opt}</option>
                {/each}
              </select>
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  </div>

  <!-- Autonomy section (staticSections[2]) -->
  <div class="section">
    <button class="accordion-header" onclick={() => toggle('autonomy')}>
      <span class="accordion-arrow" class:open={openSections['autonomy']}>&#9654;</span>
      <span>{staticSections[2].label}</span>
    </button>
    {#if openSections['autonomy']}
      <div class="accordion-body">
        {#each staticSections[2].fields as field}
          {@const value = getPath(config, field.key)}
          {@const inputId = fieldId(field.key)}
          {#if field.type === 'toggle'}
            <label class="toggle-field">
              <input
                type="checkbox"
                checked={!!value}
                onchange={(e) => updateField(field.key, e.currentTarget.checked)}
              />
              <span>{field.label}</span>
            </label>
          {:else if field.type === 'number'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="number"
                value={value ?? field.default ?? ''}
                step={field.step}
                min={field.min}
                max={field.max}
                oninput={(e) => updateField(field.key, Number(e.currentTarget.value))}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'text'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="text"
                value={value ?? ''}
                oninput={(e) => updateField(field.key, e.currentTarget.value)}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'select'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <select id={inputId} onchange={(e) => updateField(field.key, e.currentTarget.value)}>
                {#each field.options ?? [] as opt}
                  <option value={opt} selected={value === opt}>{opt}</option>
                {/each}
              </select>
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  </div>

  <!-- Diagnostics section (staticSections[3]) -->
  <div class="section">
    <button class="accordion-header" onclick={() => toggle('diagnostics')}>
      <span class="accordion-arrow" class:open={openSections['diagnostics']}>&#9654;</span>
      <span>{staticSections[3].label}</span>
    </button>
    {#if openSections['diagnostics']}
      <div class="accordion-body">
        {#each staticSections[3].fields as field}
          {@const value = getPath(config, field.key)}
          {@const inputId = fieldId(field.key)}
          {#if field.type === 'toggle'}
            <label class="toggle-field">
              <input
                type="checkbox"
                checked={!!value}
                onchange={(e) => updateField(field.key, e.currentTarget.checked)}
              />
              <span>{field.label}</span>
            </label>
          {:else if field.type === 'number'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="number"
                value={value ?? field.default ?? ''}
                step={field.step}
                min={field.min}
                max={field.max}
                oninput={(e) => updateField(field.key, Number(e.currentTarget.value))}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'text'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <input
                id={inputId}
                type="text"
                value={value ?? ''}
                oninput={(e) => updateField(field.key, e.currentTarget.value)}
              />
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {:else if field.type === 'select'}
            <div class="field">
              <label for={inputId}>{field.label}</label>
              <select id={inputId} onchange={(e) => updateField(field.key, e.currentTarget.value)}>
                {#each field.options ?? [] as opt}
                  <option value={opt} selected={value === opt}>{opt}</option>
                {/each}
              </select>
              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .config-ui {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .section {
    border: 1px solid var(--border);
    border-radius: 2px;
    background: var(--bg-surface);
  }

  .accordion-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    width: 100%;
    padding: 0.875rem 1rem;
    background: none;
    border: none;
    cursor: pointer;
    color: var(--accent);
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
  }
  .accordion-header:hover {
    background: color-mix(in srgb, var(--accent) 5%, transparent);
    text-shadow: var(--text-glow);
  }

  .accordion-arrow {
    font-size: 0.625rem;
    transition: transform 0.2s ease;
    color: var(--accent-dim);
  }
  .accordion-arrow.open {
    transform: rotate(90deg);
  }

  .accordion-body {
    padding: 0 1rem 1rem;
    border-top: 1px dashed color-mix(in srgb, var(--border) 50%, transparent);
  }

  .field {
    margin-bottom: 1rem;
  }
  .field label {
    display: block;
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--fg-dim);
    margin-bottom: 0.375rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .field input[type="text"],
  .field input[type="number"],
  .field input[type="password"],
  .field select,
  .field textarea {
    width: 100%;
    padding: 0.5rem 0.75rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
    box-sizing: border-box;
  }
  .field input:focus,
  .field select:focus,
  .field textarea:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }
  .field textarea {
    resize: vertical;
    min-height: 60px;
    line-height: 1.5;
  }
  .field select {
    cursor: pointer;
  }

  .toggle-field {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    cursor: pointer;
    margin-bottom: 0.75rem;
  }
  .toggle-field input[type="checkbox"] {
    width: 1.25rem;
    height: 1.25rem;
    accent-color: var(--accent);
    cursor: pointer;
    filter: drop-shadow(0 0 4px var(--accent-dim));
  }
  .toggle-field span {
    font-size: 0.8125rem;
    color: var(--fg);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .hint {
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-top: 0.25rem;
    font-family: var(--font-mono);
  }

  .channel-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    width: 100%;
  }
  .channel-header .accordion-left {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .remove-btn {
    padding: 0.25rem 0.5rem;
    background: none;
    border: 1px solid color-mix(in srgb, var(--error) 30%, transparent);
    border-radius: 2px;
    color: var(--error);
    font-size: 0.75rem;
    cursor: pointer;
    opacity: 0.6;
    transition: all 0.2s ease;
  }
  .remove-btn:hover {
    opacity: 1;
    background: color-mix(in srgb, var(--error) 10%, transparent);
    box-shadow: 0 0 5px var(--error);
  }

  .channels-heading {
    font-size: 0.875rem;
    font-weight: 700;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 1rem 0 0.5rem;
  }

  .add-channel {
    position: relative;
    margin-top: 0.5rem;
  }
  .add-channel-btn {
    padding: 0.5rem 1rem;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    color: var(--accent);
    border: 1px dashed var(--accent-dim);
    border-radius: 2px;
    cursor: pointer;
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
    width: 100%;
  }
  .add-channel-btn:hover {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .add-channel-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    z-index: 10;
    background: var(--bg-surface);
    border: 1px solid var(--accent);
    border-radius: 2px;
    max-height: 300px;
    overflow-y: auto;
    margin-top: 0.25rem;
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5), 0 0 15px var(--border-glow);
  }
  .add-channel-dropdown button {
    display: block;
    width: 100%;
    padding: 0.625rem 1rem;
    background: none;
    border: none;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 30%, transparent);
    color: var(--fg);
    font-size: 0.8125rem;
    text-align: left;
    cursor: pointer;
    font-family: var(--font-mono);
    transition: all 0.15s ease;
  }
  .add-channel-dropdown button:hover {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    color: var(--accent);
  }
  .add-channel-dropdown button:last-child {
    border-bottom: none;
  }

  .account-label {
    font-size: 0.6875rem;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 0.75rem 0 0.5rem;
    padding-bottom: 0.25rem;
    border-bottom: 1px dashed color-mix(in srgb, var(--border) 30%, transparent);
  }

  .provider-row {
    margin-bottom: 0.75rem;
  }
  .provider-name {
    font-size: 0.75rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-bottom: 0.25rem;
    font-weight: 700;
  }

  .cli-note {
    font-size: 0.8125rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    padding: 0.5rem 0;
  }
</style>
