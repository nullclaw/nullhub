<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';

  let settings = $state<any>({
    port: 9800,
    host: '127.0.0.1',
    auth_token: null,
    auto_update_check: true
  });
  let saving = $state(false);
  let serviceLoading = $state(false);
  let message = $state('');

  onMount(async () => {
    try {
      settings = await api.getSettings();
    } catch (e) {
      console.error(e);
    }
  });

  async function save() {
    saving = true;
    try {
      await api.putSettings(settings);
      message = 'Settings saved';
    } catch (e) {
      message = `Error: ${(e as Error).message}`;
    } finally {
      saving = false;
    }
  }
</script>

<div class="settings-page">
  <h1>Settings</h1>

  <div class="settings-section">
    <h2>Server</h2>
    <div class="field">
      <label>Port</label>
      <input type="number" bind:value={settings.port} />
    </div>
    <div class="field">
      <label>Host</label>
      <input type="text" bind:value={settings.host} />
    </div>
  </div>

  <div class="settings-section">
    <h2>Security</h2>
    <div class="field">
      <label>Auth Token</label>
      <input type="password" bind:value={settings.auth_token} placeholder="Leave empty to disable" />
      <p class="hint">Set a token to enable remote access authentication</p>
    </div>
  </div>

  <div class="settings-section">
    <h2>Updates</h2>
    <div class="field">
      <label class="toggle-field">
        <input type="checkbox" bind:checked={settings.auto_update_check} />
        <span>Auto-check for updates</span>
      </label>
    </div>
  </div>

  <div class="settings-section">
    <h2>Service</h2>
    <p class="hint">Register NullHub as a system service for automatic startup</p>
    <button class="btn" disabled={serviceLoading} onclick={async () => {
      serviceLoading = true;
      try {
        const data = await api.serviceInstall();
        message = data.message;
      } catch (e) { message = 'Failed to register service'; }
      finally { serviceLoading = false; }
    }}>{serviceLoading ? 'Installing...' : 'Enable Autostart'}</button>
  </div>

  {#if message}
    <div class="message">{message}</div>
  {/if}

  <div class="actions">
    <button class="primary-btn" onclick={save} disabled={saving}>
      {saving ? 'Saving...' : 'Save Settings'}
    </button>
  </div>
</div>

<style>
  .settings-page {
    max-width: 640px;
    margin: 0 auto;
    padding: 2rem;
  }

  h1 {
    font-size: 1.75rem;
    font-weight: 600;
    margin-bottom: 2rem;
  }

  .settings-section {
    padding-bottom: 1.5rem;
    margin-bottom: 1.5rem;
    border-bottom: 1px solid var(--border);
  }

  .settings-section:last-of-type {
    border-bottom: none;
  }

  h2 {
    font-size: 1.125rem;
    font-weight: 500;
    margin-bottom: 1rem;
    color: var(--text-primary);
  }

  .field {
    margin-bottom: 1rem;
  }

  .field label {
    display: block;
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin-bottom: 0.375rem;
  }

  .field input[type='text'],
  .field input[type='number'],
  .field input[type='password'] {
    width: 100%;
    padding: 0.5rem 0.75rem;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: border-color 0.15s;
  }

  .field input[type='text']:focus,
  .field input[type='number']:focus,
  .field input[type='password']:focus {
    border-color: var(--accent);
  }

  .toggle-field {
    display: flex !important;
    align-items: center;
    gap: 0.5rem;
    cursor: pointer;
    font-size: 0.875rem;
    color: var(--text-primary) !important;
  }

  .toggle-field input[type='checkbox'] {
    width: 1rem;
    height: 1rem;
    accent-color: var(--accent);
    cursor: pointer;
  }

  .hint {
    font-size: 0.8125rem;
    color: var(--text-muted);
    margin-top: 0.375rem;
    line-height: 1.4;
  }

  .btn {
    padding: 0.5rem 1rem;
    background: var(--bg-tertiary);
    color: var(--text-primary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 0.875rem;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    margin-top: 0.5rem;
  }

  .btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
  }

  .message {
    padding: 0.75rem 1rem;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent);
    border-radius: var(--radius);
    font-size: 0.875rem;
    color: var(--text-primary);
    margin-bottom: 1.5rem;
  }

  .actions {
    padding-top: 0.5rem;
  }

  .primary-btn {
    padding: 0.625rem 1.5rem;
    background: var(--accent);
    color: white;
    border: none;
    border-radius: var(--radius);
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .primary-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }
</style>
