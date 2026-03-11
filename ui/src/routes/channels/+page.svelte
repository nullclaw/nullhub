<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";
  import { channelSchemas } from "$lib/components/configSchemas";

  const DEFAULT_CHANNELS = ['web', 'cli'];
  const CHANNEL_OPTIONS = Object.entries(channelSchemas)
    .filter(([key]) => !DEFAULT_CHANNELS.includes(key))
    .map(([key, schema]) => ({ value: key, label: schema.label }));

  let channels = $state<any[]>([]);
  let loading = $state(true);
  let error = $state("");
  let message = $state("");

  // Add form state
  let showAddForm = $state(false);
  let addForm = $state<{ channel_type: string; account: string; config: Record<string, any> }>({
    channel_type: "telegram",
    account: "default",
    config: {},
  });
  let addValidating = $state(false);
  let addError = $state("");

  // Edit state
  let editingId = $state<string | null>(null);
  let editForm = $state<{ name: string; account: string; config: Record<string, any> }>({
    name: "",
    account: "",
    config: {},
  });
  let editOriginalAccount = $state("");
  let editOriginalConfig = $state<Record<string, any>>({});
  let editValidating = $state(false);
  let editError = $state("");
  let editChannelType = $state("");

  // Re-validate state
  let revalidatingId = $state<string | null>(null);

  let hasNullclaw = $state(false);

  let addSchema = $derived(channelSchemas[addForm.channel_type]);

  onMount(async () => {
    await loadChannels();
    try {
      const status = await api.getStatus();
      hasNullclaw = Object.keys(status.instances?.nullclaw || {}).length > 0;
    } catch {}
  });

  async function loadChannels() {
    loading = true;
    error = "";
    try {
      const data = await api.getSavedChannels();
      channels = data.channels || [];
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function resetAddConfig(type: string) {
    const schema = channelSchemas[type];
    const defaults: Record<string, any> = {};
    for (const field of schema?.fields || []) {
      if (field.default !== undefined) defaults[field.key] = field.default;
    }
    addForm = {
      channel_type: type,
      account: schema?.hasAccounts ? "default" : type,
      config: defaults,
    };
  }

  async function handleAdd() {
    addValidating = true;
    addError = "";
    try {
      await api.createSavedChannel({
        channel_type: addForm.channel_type,
        account: addForm.account,
        config: addForm.config,
      });
      showAddForm = false;
      resetAddConfig("telegram");
      message = "Channel saved";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addValidating = false;
    }
  }

  async function startEdit(c: any) {
    editChannelType = c.channel_type;
    editError = "";
    error = "";
    try {
      const data = await api.getSavedChannels(true);
      const revealed = (data.channels || []).find((ch: any) => ch.id === c.id);
      if (revealed) {
        editingId = c.id;
        editOriginalAccount = revealed.account || "";
        editOriginalConfig = { ...(revealed.config || {}) };
        editForm = {
          name: revealed.name || "",
          account: revealed.account || "",
          config: { ...(revealed.config || {}) },
        };
      } else {
        error = "Channel could not be loaded for editing";
      }
    } catch (e) {
      const message = (e as Error).message;
      editError = message;
      error = message;
    }
  }

  function cancelEdit() {
    editingId = null;
    editError = "";
  }

  async function saveEdit(id: string) {
    editValidating = true;
    editError = "";
    try {
      const payload: any = {};
      if (editForm.name) payload.name = editForm.name;
      if (editForm.account && editForm.account !== editOriginalAccount) payload.account = editForm.account;
      const configChanged = JSON.stringify(editForm.config, Object.keys(editForm.config).sort())
        !== JSON.stringify(editOriginalConfig, Object.keys(editOriginalConfig).sort());
      if (configChanged) payload.config = editForm.config;
      await api.updateSavedChannel(id, payload);
      editingId = null;
      message = "Channel updated";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      editError = (e as Error).message;
    } finally {
      editValidating = false;
    }
  }

  async function handleDelete(id: string) {
    try {
      await api.deleteSavedChannel(id);
      message = "Channel deleted";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function handleRevalidate(id: string) {
    revalidatingId = id;
    try {
      const result = await api.revalidateSavedChannel(id);
      if (result.live_ok) {
        message = "Validation passed";
      } else {
        message = `Validation failed: ${result.reason || "unknown error"}`;
      }
      setTimeout(() => (message = ""), 5000);
      await loadChannels();
    } catch (e) {
      message = `Validation failed: ${(e as Error).message}`;
      setTimeout(() => (message = ""), 5000);
    } finally {
      revalidatingId = null;
    }
  }

  function getChannelLabel(type: string) {
    return channelSchemas[type]?.label || type;
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

  function displayConfigValue(val: any): string {
    if (val === undefined || val === null || val === "") return "-";
    if (Array.isArray(val)) return val.length > 0 ? val.join(", ") : "-";
    if (typeof val === "boolean") return val ? "Yes" : "No";
    return String(val);
  }
</script>

<div class="channels-page">
  <div class="page-header">
    <h1>Channels</h1>
    {#if hasNullclaw}
      <button class="primary-btn" onclick={() => {
        if (!showAddForm) resetAddConfig(addForm.channel_type || "telegram");
        showAddForm = !showAddForm;
      }}>
        {showAddForm ? "Cancel" : "+ Add Channel"}
      </button>
    {/if}
  </div>

  {#if message}
    <div class="message">{message}</div>
  {/if}

  {#if error}
    <div class="error-message">{error}</div>
  {/if}

  {#if !hasNullclaw && channels.length > 0}
    <div class="warning-message">
      Install a nullclaw instance to add new channels or re-validate saved ones.
    </div>
  {/if}

  {#if hasNullclaw && showAddForm}
    <div class="add-form">
      <h2>Add Channel</h2>
      <div class="field">
        <label for="add-channel-type">Channel Type</label>
        <select id="add-channel-type" bind:value={addForm.channel_type} onchange={(e) => resetAddConfig(e.currentTarget.value)}>
          {#each CHANNEL_OPTIONS as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>
      {#if addSchema?.hasAccounts}
        <div class="field">
          <label for="add-account">Account Name</label>
          <input id="add-account" type="text" bind:value={addForm.account} placeholder="default" />
        </div>
      {/if}
      {#each addSchema?.fields || [] as field}
        <div class="field">
          <label for={`add-${field.key}`}>
            {field.label}
            {#if field.hint}
              <span class="field-hint">{field.hint}</span>
            {/if}
          </label>
          {#if field.type === 'password'}
            <input
              id={`add-${field.key}`}
              type="password"
              value={addForm.config[field.key] ?? field.default ?? ""}
              oninput={(e) => { addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }; }}
              placeholder="Enter value..."
            />
          {:else if field.type === 'number'}
            <input
              id={`add-${field.key}`}
              type="number"
              value={addForm.config[field.key] ?? field.default ?? ""}
              min={field.min}
              max={field.max}
              step={field.step}
              oninput={(e) => { addForm.config = { ...addForm.config, [field.key]: Number(e.currentTarget.value) }; }}
            />
          {:else if field.type === 'toggle'}
            <label class="toggle">
              <input
                type="checkbox"
                checked={(addForm.config[field.key] ?? field.default ?? false) === true}
                onchange={(e) => { addForm.config = { ...addForm.config, [field.key]: e.currentTarget.checked }; }}
              />
              <span class="toggle-slider"></span>
            </label>
          {:else if field.type === 'select'}
            <select
              id={`add-${field.key}`}
              value={addForm.config[field.key] ?? field.default ?? ""}
              onchange={(e) => { addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }; }}
            >
              {#each field.options || [] as opt}
                <option value={opt}>{opt}</option>
              {/each}
            </select>
          {:else if field.type === 'list'}
            <input
              id={`add-${field.key}`}
              type="text"
              value={(addForm.config[field.key] ?? field.default ?? []).join(', ')}
              oninput={(e) => { addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean) }; }}
              placeholder={field.hint || "Comma-separated values..."}
            />
          {:else}
            <input
              id={`add-${field.key}`}
              type="text"
              value={addForm.config[field.key] ?? field.default ?? ""}
              oninput={(e) => { addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }; }}
              placeholder={field.hint || "Enter value..."}
            />
          {/if}
        </div>
      {/each}
      {#if addError}
        <div class="error-message">{addError}</div>
      {/if}
      <button class="primary-btn" onclick={handleAdd} disabled={addValidating}>
        {addValidating ? "Validating..." : "Validate & Save"}
      </button>
    </div>
  {/if}

  {#if loading}
    <p class="loading">Loading channels...</p>
  {:else}
    {#if channels.length === 0}
      <div class="empty-state">
        {#if hasNullclaw}
          <p>No saved channels yet. Add one above or install a component — channels are saved automatically during setup.</p>
        {:else}
          <p>Install a nullclaw instance first to add and validate channels.</p>
          <a href="/install" class="link-btn">Install NullClaw</a>
        {/if}
      </div>
    {:else}
      <div class="channel-grid">
        {#each channels as c}
          <div class="channel-card">
            {#if editingId === c.id}
              {@const editSchema = channelSchemas[editChannelType]}
              <div class="edit-form">
                <div class="field">
                  <label for="edit-name-{c.id}">Name</label>
                  <input id="edit-name-{c.id}" type="text" bind:value={editForm.name} />
                </div>
                {#if editSchema?.hasAccounts}
                  <div class="field">
                    <label for="edit-account-{c.id}">Account</label>
                    <input id="edit-account-{c.id}" type="text" bind:value={editForm.account} />
                  </div>
                {/if}
                {#each editSchema?.fields || [] as field}
                  <div class="field">
                    <label for={`edit-${c.id}-${field.key}`}>
                      {field.label}
                      {#if field.hint}
                        <span class="field-hint">{field.hint}</span>
                      {/if}
                    </label>
                    {#if field.type === 'password'}
                      <input
                        id={`edit-${c.id}-${field.key}`}
                        type="password"
                        value={editForm.config[field.key] ?? ""}
                        oninput={(e) => { editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }; }}
                        placeholder="Leave empty to keep current"
                      />
                    {:else if field.type === 'number'}
                      <input
                        id={`edit-${c.id}-${field.key}`}
                        type="number"
                        value={editForm.config[field.key] ?? field.default ?? ""}
                        min={field.min}
                        max={field.max}
                        step={field.step}
                        oninput={(e) => { editForm.config = { ...editForm.config, [field.key]: Number(e.currentTarget.value) }; }}
                      />
                    {:else if field.type === 'toggle'}
                      <label class="toggle">
                        <input
                          type="checkbox"
                          checked={(editForm.config[field.key] ?? field.default ?? false) === true}
                          onchange={(e) => { editForm.config = { ...editForm.config, [field.key]: e.currentTarget.checked }; }}
                        />
                        <span class="toggle-slider"></span>
                      </label>
                    {:else if field.type === 'select'}
                      <select
                        id={`edit-${c.id}-${field.key}`}
                        value={editForm.config[field.key] ?? field.default ?? ""}
                        onchange={(e) => { editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }; }}
                      >
                        {#each field.options || [] as opt}
                          <option value={opt}>{opt}</option>
                        {/each}
                      </select>
                    {:else if field.type === 'list'}
                      <input
                        id={`edit-${c.id}-${field.key}`}
                        type="text"
                        value={(editForm.config[field.key] ?? field.default ?? []).join(', ')}
                        oninput={(e) => { editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean) }; }}
                        placeholder={field.hint || "Comma-separated values..."}
                      />
                    {:else}
                      <input
                        id={`edit-${c.id}-${field.key}`}
                        type="text"
                        value={editForm.config[field.key] ?? ""}
                        oninput={(e) => { editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }; }}
                        placeholder={field.hint || "Enter value..."}
                      />
                    {/if}
                  </div>
                {/each}
                {#if editError}
                  <div class="error-message">{editError}</div>
                {/if}
                <div class="edit-actions">
                  <button class="primary-btn" onclick={() => saveEdit(c.id)} disabled={editValidating}>
                    {editValidating ? "Saving..." : "Save"}
                  </button>
                  <button class="btn" onclick={cancelEdit}>Cancel</button>
                </div>
              </div>
            {:else}
              <div class="card-header">
                <div class="card-title">
                  <span class="status-dot" class:validated={!!c.validated_at} class:not-validated={!c.validated_at}></span>
                  <h3>{c.name}</h3>
                </div>
                <span class="channel-type">{getChannelLabel(c.channel_type)}</span>
              </div>
              <div class="card-body">
                {#if c.account}
                  <div class="card-field">
                    <span class="label">Account</span>
                    <code>{c.account}</code>
                  </div>
                {/if}
                {#each Object.entries(c.config || {}) as [key, val]}
                  <div class="card-field">
                    <span class="label">{key}</span>
                    <code>{displayConfigValue(val)}</code>
                  </div>
                {/each}
                {#if c.validated_at}
                  <div class="card-field">
                    <span class="label">Validated</span>
                    <span>{formatDate(c.validated_at)}</span>
                  </div>
                {/if}
              </div>
              <div class="card-actions">
                <button
                  class="btn"
                  onclick={() => handleRevalidate(c.id)}
                  disabled={revalidatingId === c.id || !hasNullclaw}
                  title={hasNullclaw ? "Re-validate" : "Install nullclaw to re-validate"}
                >
                  {revalidatingId === c.id ? "Validating..." : "Re-validate"}
                </button>
                <button class="btn" onclick={() => startEdit(c)}>Edit</button>
                <button class="btn danger" onclick={() => handleDelete(c.id)}>Delete</button>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {/if}
</div>

<style>
  .channels-page {
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

  .add-form, .channel-card {
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

  .field-hint {
    font-weight: 400;
    font-size: 0.65rem;
    color: color-mix(in srgb, var(--fg-dim) 70%, transparent);
    letter-spacing: 0;
    text-transform: none;
    margin-left: 0.5rem;
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

  .channel-type {
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

  .warning-message {
    padding: 0.875rem 1.25rem;
    background: color-mix(in srgb, var(--warning, #ca0) 10%, transparent);
    border: 1px solid var(--warning, #ca0);
    border-radius: 2px;
    font-size: 0.875rem;
    color: var(--warning, #ca0);
    margin-bottom: 1rem;
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

  .channel-grid {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .edit-form {
    padding: 0.5rem 0;
  }

  /* Toggle styles */
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
