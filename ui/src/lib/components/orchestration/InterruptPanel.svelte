<script lang="ts">
  let {
    message = '',
    onResume = (_updates: any) => {},
    onCancel = () => {},
  } = $props();

  let stateJson = $state('{}');
  let jsonValid = $state(true);

  function handleInput(e: Event) {
    stateJson = (e.target as HTMLTextAreaElement).value;
    try {
      JSON.parse(stateJson);
      jsonValid = true;
    } catch {
      jsonValid = false;
    }
  }

  function approve() {
    try {
      const updates = JSON.parse(stateJson);
      onResume(updates);
    } catch { /* ignore */ }
  }

  function reject() {
    onCancel();
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<div class="overlay" role="button" tabindex="-1" onclick={reject}>
  <div class="panel" role="dialog" aria-label="Run interrupted" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={(e) => { if (e.key === 'Escape') reject(); }}>
    <div class="panel-header">
      <span class="panel-title">Run Interrupted</span>
    </div>

    <div class="panel-body">
      <div class="message">
        <span class="msg-label">Message:</span>
        <p>{message || 'This run requires approval to continue.'}</p>
      </div>

      <div class="state-section">
        <label class="state-label" for="state-updates">State Updates (JSON)</label>
        <textarea
          id="state-updates"
          class="state-editor"
          class:invalid={!jsonValid}
          spellcheck="false"
          value={stateJson}
          oninput={handleInput}
        ></textarea>
        {#if !jsonValid}
          <span class="json-err">Invalid JSON</span>
        {/if}
      </div>
    </div>

    <div class="panel-actions">
      <button class="btn-reject" onclick={reject}>Reject</button>
      <button class="btn-approve" onclick={approve} disabled={!jsonValid}>Approve & Resume</button>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    backdrop-filter: blur(2px);
  }
  .panel {
    background: var(--bg-surface);
    border: 1px solid var(--warning);
    border-radius: 4px;
    width: 90%;
    max-width: 520px;
    box-shadow: 0 0 30px color-mix(in srgb, var(--warning) 20%, transparent);
  }
  .panel-header {
    padding: 1rem 1.25rem;
    border-bottom: 1px solid var(--border);
  }
  .panel-title {
    font-size: 1rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--warning);
    text-shadow: 0 0 6px var(--warning);
  }
  .panel-body {
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .message {
    padding: 0.75rem;
    background: color-mix(in srgb, var(--warning) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--warning) 30%, transparent);
    border-radius: 4px;
  }
  .msg-label {
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
    display: block;
    margin-bottom: 0.375rem;
  }
  .message p {
    font-size: 0.875rem;
    color: var(--fg);
    margin: 0;
  }
  .state-section {
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
  }
  .state-label {
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--fg-dim);
  }
  .state-editor {
    width: 100%;
    min-height: 100px;
    padding: 0.75rem;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.5;
    resize: vertical;
    outline: none;
  }
  .state-editor:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 6px var(--border-glow);
  }
  .state-editor.invalid {
    border-color: var(--error);
  }
  .json-err {
    font-size: 0.6875rem;
    color: var(--error);
    font-family: var(--font-mono);
  }
  .panel-actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.75rem;
    padding: 1rem 1.25rem;
    border-top: 1px solid var(--border);
  }
  .btn-reject,
  .btn-approve {
    padding: 0.5rem 1rem;
    border-radius: 2px;
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .btn-reject {
    background: color-mix(in srgb, var(--error) 10%, transparent);
    color: var(--error);
    border: 1px solid color-mix(in srgb, var(--error) 40%, transparent);
  }
  .btn-reject:hover {
    background: color-mix(in srgb, var(--error) 20%, transparent);
    border-color: var(--error);
    box-shadow: 0 0 8px color-mix(in srgb, var(--error) 30%, transparent);
    text-shadow: 0 0 4px var(--error);
  }
  .btn-approve {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    color: var(--success);
    border: 1px solid color-mix(in srgb, var(--success) 40%, transparent);
  }
  .btn-approve:hover:not(:disabled) {
    background: color-mix(in srgb, var(--success) 20%, transparent);
    border-color: var(--success);
    box-shadow: 0 0 8px color-mix(in srgb, var(--success) 30%, transparent);
    text-shadow: 0 0 4px var(--success);
  }
  .btn-approve:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
</style>
