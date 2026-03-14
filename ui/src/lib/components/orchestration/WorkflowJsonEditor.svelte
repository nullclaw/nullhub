<script lang="ts">
  let { value = $bindable(''), onerror = (_msg: string) => {} } = $props();
  let valid = $state(true);
  let errorMsg = $state('');

  function handleInput(e: Event) {
    const target = e.target as HTMLTextAreaElement;
    value = target.value;
    try {
      JSON.parse(value);
      valid = true;
      errorMsg = '';
      onerror('');
    } catch (err) {
      valid = false;
      errorMsg = (err as Error).message;
      onerror(errorMsg);
    }
  }
</script>

<div class="editor-wrap">
  <textarea
    class="json-editor"
    class:invalid={!valid}
    spellcheck="false"
    {value}
    oninput={handleInput}
  ></textarea>
  {#if !valid}
    <div class="error-line">{errorMsg}</div>
  {/if}
</div>

<style>
  .editor-wrap {
    display: flex;
    flex-direction: column;
    height: 100%;
  }
  .json-editor {
    flex: 1;
    width: 100%;
    min-height: 300px;
    padding: 1rem;
    background: var(--bg-surface);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.6;
    resize: vertical;
    outline: none;
    transition: border-color 0.2s ease;
    tab-size: 2;
  }
  .json-editor:focus {
    border-color: var(--accent-dim);
    box-shadow: 0 0 8px var(--border-glow);
  }
  .json-editor.invalid {
    border-color: var(--error);
    box-shadow: 0 0 8px color-mix(in srgb, var(--error) 30%, transparent);
  }
  .error-line {
    padding: 0.375rem 0.75rem;
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--error);
    background: color-mix(in srgb, var(--error) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--error) 30%, transparent);
    border-top: none;
    border-radius: 0 0 4px 4px;
    text-shadow: 0 0 4px var(--error);
  }
</style>
