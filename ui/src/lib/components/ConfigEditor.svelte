<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';

  let { component = '', name = '' } = $props();
  let configText = $state('');
  let saving = $state(false);
  let message = $state('');
  let error = $state(false);
  let loaded = $state(false);

  async function load() {
    try {
      const data = await api.getConfig(component, name);
      configText = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
      message = '';
      error = false;
    } catch (e) {
      configText = '{}';
      message = 'No config found, starting with empty object';
      error = false;
    }
    loaded = true;
  }

  async function save() {
    saving = true;
    try {
      JSON.parse(configText); // validate
      await api.putConfig(component, name, JSON.parse(configText));
      message = 'Config saved';
      error = false;
    } catch (e) {
      message = `Error: ${(e as Error).message}`;
      error = true;
    } finally {
      saving = false;
    }
  }

  onMount(() => { load(); });
</script>

<div class="config-editor">
  <div class="editor-header">
    <span>Configuration</span>
    <button onclick={save} disabled={saving}>
      {saving ? 'Saving...' : 'Save'}
    </button>
  </div>
  {#if message}
    <div class="message" class:error>{message}</div>
  {/if}
  <textarea bind:value={configText} spellcheck="false"></textarea>
</div>

<style>
  .config-editor {
    display: flex;
    flex-direction: column;
    height: 400px;
  }
  .editor-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem 0;
    font-size: 0.875rem;
    color: var(--text-secondary);
  }
  .editor-header button {
    padding: 0.375rem 1rem;
    background: var(--accent);
    color: white;
    border: none;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.8rem;
  }
  .editor-header button:hover {
    background: var(--accent-hover);
  }
  .editor-header button:disabled {
    opacity: 0.5;
  }
  textarea {
    flex: 1;
    background: var(--bg-primary);
    color: var(--text-primary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.75rem;
    font-family: var(--font-mono);
    font-size: 0.8rem;
    resize: none;
    line-height: 1.5;
  }
  .message {
    padding: 0.5rem;
    border-radius: var(--radius-sm);
    font-size: 0.8rem;
    background: color-mix(in srgb, var(--success) 15%, transparent);
    color: var(--success);
  }
  .message.error {
    background: color-mix(in srgb, var(--error) 15%, transparent);
    color: var(--error);
  }
</style>
