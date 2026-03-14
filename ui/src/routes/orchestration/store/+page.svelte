<script lang="ts">
  import { api } from '$lib/api/client';

  let namespace = $state('');
  let browsedNamespace = $state('');
  let entries = $state<any[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);

  // Selected entry detail modal
  let selectedEntry = $state<{ key: string; value: any } | null>(null);

  // Add entry form
  let addNamespace = $state('');
  let addKey = $state('');
  let addValue = $state('');
  let addError = $state<string | null>(null);
  let addSuccess = $state(false);
  let addLoading = $state(false);

  async function browse() {
    if (!namespace.trim()) return;
    browsedNamespace = namespace.trim();
    loading = true;
    error = null;
    entries = [];
    try {
      const result = await api.storeList(browsedNamespace);
      entries = result || [];
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function deleteEntry(key: string) {
    if (!confirm(`Delete key "${key}" from namespace "${browsedNamespace}"?`)) return;
    try {
      await api.storeDelete(browsedNamespace, key);
      entries = entries.filter((e) => e.key !== key);
      if (selectedEntry?.key === key) selectedEntry = null;
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function viewEntry(entry: any) {
    try {
      const full = await api.storeGet(browsedNamespace, entry.key);
      selectedEntry = { key: entry.key, value: full };
    } catch (e) {
      // fall back to inline value
      selectedEntry = { key: entry.key, value: entry.value ?? entry };
    }
  }

  async function saveEntry() {
    addError = null;
    addSuccess = false;
    if (!addNamespace.trim() || !addKey.trim() || !addValue.trim()) {
      addError = 'All fields are required.';
      return;
    }
    let parsed: any;
    try {
      parsed = JSON.parse(addValue);
    } catch {
      addError = 'Value must be valid JSON.';
      return;
    }
    addLoading = true;
    try {
      await api.storePut(addNamespace.trim(), addKey.trim(), parsed);
      addSuccess = true;
      addKey = '';
      addValue = '';
      // Refresh if we browsed the same namespace
      if (browsedNamespace === addNamespace.trim()) {
        await browse();
      }
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addLoading = false;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) browse();
  }

  function closeModal() {
    selectedEntry = null;
  }

  function formatValue(val: any): string {
    try {
      return JSON.stringify(val, null, 2);
    } catch {
      return String(val);
    }
  }
</script>

<div class="page">
  <div class="header">
    <h1>Store</h1>
  </div>

  {#if error}
    <div class="error-banner">ERR: {error}</div>
  {/if}

  <div class="layout">
    <!-- Left panel: namespace browser -->
    <div class="left-panel">
      <div class="panel-section">
        <h2 class="panel-title">Browse Namespace</h2>
        <div class="input-row">
          <input
            class="ns-input"
            type="text"
            placeholder="namespace"
            bind:value={namespace}
            onkeydown={handleKeydown}
          />
          <button class="btn-primary" onclick={browse} disabled={loading || !namespace.trim()}>
            {loading ? '...' : 'Browse'}
          </button>
        </div>
      </div>

      <div class="panel-section add-section">
        <h2 class="panel-title">Add Entry</h2>
        <div class="form-field">
          <label class="form-label" for="add-ns">Namespace</label>
          <input
            id="add-ns"
            class="form-input"
            type="text"
            placeholder="namespace"
            bind:value={addNamespace}
          />
        </div>
        <div class="form-field">
          <label class="form-label" for="add-key">Key</label>
          <input
            id="add-key"
            class="form-input"
            type="text"
            placeholder="key"
            bind:value={addKey}
          />
        </div>
        <div class="form-field">
          <label class="form-label" for="add-value">Value (JSON)</label>
          <textarea
            id="add-value"
            class="form-textarea"
            placeholder="JSON value"
            bind:value={addValue}
            rows={5}
          ></textarea>
        </div>
        {#if addError}
          <div class="form-error">{addError}</div>
        {/if}
        {#if addSuccess}
          <div class="form-success">Saved.</div>
        {/if}
        <button class="btn-primary" onclick={saveEntry} disabled={addLoading}>
          {addLoading ? 'Saving...' : 'Save'}
        </button>
      </div>
    </div>

    <!-- Main area: entries table -->
    <div class="main-area">
      {#if !browsedNamespace}
        <div class="empty-state">
          <p>> Enter a namespace and press Browse.</p>
        </div>
      {:else if loading}
        <div class="loading">Loading entries...</div>
      {:else if entries.length === 0}
        <div class="empty-state">
          <p>> No entries in namespace "{browsedNamespace}".</p>
        </div>
      {:else}
        <div class="table-section">
          <div class="table-header">
            <span class="ns-label">/{browsedNamespace}</span>
            <span class="entry-count">{entries.length} entries</span>
          </div>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Key</th>
                  <th>Value Preview</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {#each entries as entry}
                  <tr class="clickable" onclick={() => viewEntry(entry)}>
                    <td class="mono">{entry.key ?? entry}</td>
                    <td class="mono value-preview">
                      {#if entry.value !== undefined}
                        {typeof entry.value === 'string'
                          ? entry.value.slice(0, 80)
                          : JSON.stringify(entry.value).slice(0, 80)}
                      {:else}
                        -
                      {/if}
                    </td>
                    <td class="actions-cell" onclick={(e) => e.stopPropagation()}>
                      <button
                        class="btn-danger-sm"
                        onclick={() => deleteEntry(entry.key ?? entry)}
                      >Delete</button>
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>
      {/if}
    </div>
  </div>
</div>

<!-- Entry detail modal -->
{#if selectedEntry}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="modal-backdrop" role="button" tabindex="-1" onclick={closeModal}>
    <div class="modal" role="dialog" aria-label="Entry detail" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={(e) => { if (e.key === 'Escape') closeModal(); }}>
      <div class="modal-header">
        <span class="modal-title mono">{selectedEntry.key}</span>
        <button class="modal-close" onclick={closeModal} aria-label="Close">&#x2715;</button>
      </div>
      <div class="modal-body">
        <pre class="json-view">{formatValue(selectedEntry.value)}</pre>
      </div>
    </div>
  </div>
{/if}

<style>
  .page {
    padding: 2rem;
    max-width: 1400px;
    margin: 0 auto;
  }
  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 2rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid var(--border);
  }
  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    text-shadow: var(--text-glow);
    text-transform: uppercase;
    letter-spacing: 2px;
  }
  .layout {
    display: flex;
    gap: 1.5rem;
    align-items: flex-start;
  }
  .left-panel {
    width: 280px;
    min-width: 240px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .panel-section {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1rem;
  }
  .panel-title {
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.5px;
    color: var(--fg-dim);
    margin-bottom: 0.75rem;
  }
  .input-row {
    display: flex;
    gap: 0.5rem;
  }
  .ns-input {
    flex: 1;
    padding: 0.4rem 0.6rem;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    outline: none;
    min-width: 0;
  }
  .ns-input:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 4px var(--border-glow);
  }
  .btn-primary {
    padding: 0.4rem 0.875rem;
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    white-space: nowrap;
    transition: all 0.15s ease;
  }
  .btn-primary:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 25%, transparent);
    box-shadow: 0 0 6px var(--accent-dim);
  }
  .btn-primary:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .add-section {
    display: flex;
    flex-direction: column;
    gap: 0.625rem;
  }
  .form-field {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .form-label {
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
  }
  .form-input,
  .form-textarea {
    padding: 0.375rem 0.5rem;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    outline: none;
    resize: vertical;
  }
  .form-input:focus,
  .form-textarea:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 4px var(--border-glow);
  }
  .form-error {
    font-size: 0.75rem;
    color: var(--error);
    text-shadow: 0 0 4px var(--error);
  }
  .form-success {
    font-size: 0.75rem;
    color: var(--success);
    text-shadow: 0 0 4px var(--success);
  }
  .main-area {
    flex: 1;
    min-width: 0;
  }
  .table-section {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1rem;
  }
  .table-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 0.75rem;
    padding-bottom: 0.5rem;
    border-bottom: 1px solid var(--border);
  }
  .ns-label {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }
  .entry-count {
    font-size: 0.6875rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .table-wrap {
    overflow-x: auto;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }
  th {
    text-align: left;
    padding: 0.625rem 0.75rem;
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
  }
  td {
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    color: var(--fg);
  }
  td.mono {
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }
  td.value-preview {
    max-width: 400px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--fg-dim);
  }
  td.actions-cell {
    white-space: nowrap;
    width: 80px;
  }
  tr.clickable {
    cursor: pointer;
    transition: background 0.15s ease;
  }
  tr.clickable:hover td {
    background: var(--bg-hover);
  }
  .btn-danger-sm {
    padding: 0.25rem 0.5rem;
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid color-mix(in srgb, var(--error) 40%, transparent);
    border-radius: 2px;
    font-size: 0.6875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .btn-danger-sm:hover {
    background: color-mix(in srgb, var(--error) 20%, transparent);
    box-shadow: 0 0 5px color-mix(in srgb, var(--error) 30%, transparent);
  }
  .error-banner {
    padding: 0.75rem 1rem;
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid var(--error);
    border-radius: 4px;
    margin-bottom: 1.5rem;
    font-size: 0.875rem;
    font-weight: bold;
    text-shadow: 0 0 5px var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 20%, transparent);
  }
  .loading {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
  }
  .empty-state {
    text-align: center;
    padding: 4rem 2rem;
    color: var(--fg-dim);
    border: 1px dashed var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .empty-state p {
    font-family: var(--font-mono);
  }

  /* Modal */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.65);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    backdrop-filter: blur(2px);
  }
  .modal {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    width: 640px;
    max-width: 90vw;
    max-height: 80vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 0 30px color-mix(in srgb, var(--accent) 15%, transparent);
  }
  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.875rem 1rem;
    border-bottom: 1px solid var(--border);
  }
  .modal-title {
    font-size: 0.875rem;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }
  .modal-close {
    background: none;
    border: none;
    color: var(--fg-dim);
    font-size: 1rem;
    cursor: pointer;
    padding: 0.25rem;
    line-height: 1;
    transition: color 0.15s ease;
  }
  .modal-close:hover {
    color: var(--fg);
  }
  .modal-body {
    padding: 1rem;
    overflow-y: auto;
    flex: 1;
  }
  .json-view {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
    white-space: pre-wrap;
    word-break: break-all;
  }
</style>
