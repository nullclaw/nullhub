<script lang="ts">
  import ModuleFrame from "./ModuleFrame.svelte";

  let { port = 0, moduleName = "", moduleVersion = "", instanceKey = "" } = $props();

  const wsUrl = $derived(port > 0 ? `ws://127.0.0.1:${port}/ws` : "");
  const hasModule = $derived(moduleName.length > 0 && moduleVersion.length > 0);
  const mountKey = $derived(`${instanceKey}:${moduleName}:${moduleVersion}:${wsUrl}`);
</script>

<div class="chat-panel">
  {#if hasModule && wsUrl}
    {#key mountKey}
      <ModuleFrame
        {moduleName}
        {moduleVersion}
        instanceUrl={wsUrl}
        moduleProps={{ wsUrl, pairingCode: "123456" }}
      />
    {/key}
  {:else if !hasModule}
    <div class="chat-unavailable">
      Chat UI module not installed. Reinstall this instance to add it.
    </div>
  {:else}
    <div class="chat-unavailable">Waiting for web channel port...</div>
  {/if}
</div>

<style>
  .chat-panel {
    height: 600px;
    border: 1px solid var(--border);
    border-radius: 2px;
    overflow: hidden;
    background: var(--bg-surface);
    box-shadow: inset 0 0 10px rgba(0, 0, 0, 0.5);
  }
  .chat-unavailable {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: var(--warning, #f59e0b);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 1px;
    padding: 2rem;
    text-align: center;
    border: 1px dashed
      color-mix(in srgb, var(--warning, #f59e0b) 50%, transparent);
    background: color-mix(in srgb, var(--warning, #f59e0b) 5%, transparent);
    text-shadow: 0 0 5px
      color-mix(in srgb, var(--warning, #f59e0b) 50%, transparent);
  }
</style>
