<script lang="ts">
  import { page } from "$app/stores";
  import { onMount } from "svelte";
  import StatusBadge from "$lib/components/StatusBadge.svelte";
  import LogViewer from "$lib/components/LogViewer.svelte";
  import ConfigEditor from "$lib/components/ConfigEditor.svelte";
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import { api } from "$lib/api/client";

  let component = $derived($page.params.component);
  let name = $derived($page.params.name);
  let instance = $state<any>(null);
  let config = $state<any>(null);
  let uiModules = $state<Record<string, string>>({});
  let activeTab = $state("overview");
  let loading = $state(false);
  let providerHealth = $state<any>(null);
  let providerHealthLoading = $state(false);
  let lastProviderProbeAt = $state(0);
  type UsageWindow = "24h" | "7d" | "30d" | "all";
  let usageWindow = $state<UsageWindow>("24h");
  let usageData = $state<any>(null);
  let usageLoading = $state(false);

  let modelName = $derived(extractModel(config));
  let webPort = $derived(extractWebPort(config));
  let providerStatus = $derived(extractProviderStatus(config));
  let providerDotOk = $derived(Boolean(providerStatus.provider) && Boolean(providerHealth?.live_ok));
  let providerCardWarn = $derived(!providerDotOk);
  let providerHintText = $derived(
    buildProviderHint(providerStatus, providerHealth, providerHealthLoading),
  );
  let chatModuleName = $derived(
    uiModules["nullclaw-chat-ui"] ? "nullclaw-chat-ui" : "",
  );
  let chatModuleVersion = $derived(uiModules["nullclaw-chat-ui"] || "");
  let chatReady = $derived(
    instance?.status === "running" &&
      (instance?.launch_mode || "gateway") === "gateway" &&
      chatModuleName !== "" &&
      webPort != null &&
      providerStatus.configured,
  );

  function extractModel(cfg: any): string | null {
    if (!cfg) return null;
    try {
      if (cfg.channels?.gateway?.model) return cfg.channels.gateway.model;
      if (cfg.model) return cfg.model;
      if (cfg.channels?.web?.model) return cfg.channels.web.model;
    } catch {
      /* ignore */
    }
    return null;
  }

  function extractProviderStatus(cfg: any): {
    provider: string;
    model: string;
    configured: boolean;
  } {
    const none = { provider: "", model: "", configured: false };
    if (!cfg) return none;
    try {
      const primary = cfg.agents?.defaults?.model?.primary || "";
      if (!primary) return none;
      const parts = primary.split("/");
      const provider = parts.length > 1 ? parts[0] : primary;
      const model = parts.length > 1 ? parts.slice(1).join("/") : primary;
      const providers = cfg.models?.providers || {};
      // Check if the specific provider has an api_key
      if (providers[provider]?.api_key) {
        return { provider, model, configured: true };
      }
      // Check if any provider has an api_key set
      for (const [name, prov] of Object.entries(providers)) {
        if ((prov as any)?.api_key) {
          return { provider: name, model, configured: true };
        }
      }
      return { provider, model, configured: false };
    } catch {
      return none;
    }
  }

  function extractWebPort(cfg: any): number | null {
    if (!cfg) return null;
    try {
      if (cfg.channels?.web?.accounts?.default?.port)
        return cfg.channels.web.accounts.default.port;
      if (cfg.channels?.web?.port) return cfg.channels.web.port;
      if (cfg.web_port) return cfg.web_port;
    } catch {
      /* ignore */
    }
    return null;
  }

  function formatUptime(seconds: number | undefined): string {
    if (!seconds && seconds !== 0) return "-";
    if (seconds < 60) return `${seconds}s`;
    const m = Math.floor(seconds / 60);
    if (m < 60) return `${m}m ${seconds % 60}s`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ${m % 60}m`;
    const d = Math.floor(h / 24);
    return `${d}d ${h % 24}h`;
  }

  function formatTokens(value: number | undefined): string {
    const v = value ?? 0;
    return v.toLocaleString();
  }

  function formatLastUsed(ts: number | undefined): string {
    if (!ts) return "-";
    try {
      return new Date(ts * 1000).toLocaleString();
    } catch {
      return "-";
    }
  }

  function buildProviderHint(
    status: { provider: string; configured: boolean },
    probe: any,
    probeLoading: boolean,
  ): string {
    if (!status.provider) return "";
    if (probeLoading) return "Checking live auth...";
    if (!status.configured) return "No API key";
    if (!probe) return "Waiting for live check";
    if (probe.live_ok) {
      return probe.status_code ? `Live check OK (HTTP ${probe.status_code})` : "Live check OK";
    }
    const code = probe.status_code ? ` (HTTP ${probe.status_code})` : "";
    switch (probe.reason) {
      case "invalid_api_key":
        return "Invalid API key (401)";
      case "missing_api_key":
        return "No API key";
      case "instance_not_running":
        return "Instance is not running";
      case "rate_limited":
        return "Rate limited (429)";
      case "forbidden":
        return "Forbidden (403)";
      case "provider_unavailable":
        return `Provider unavailable${code}`;
      case "network_error":
        return "Network error during auth check";
      case "probe_exec_failed":
      case "probe_request_failed":
        return "Probe request failed";
      case "component_binary_missing":
        return "Component binary missing for probe";
      case "invalid_probe_response":
        return "Probe returned invalid response";
      default:
        return `Auth check failed${code}`;
    }
  }

  async function refreshProviderHealth(force = false, cfgOverride: any = config) {
    const status = extractProviderStatus(cfgOverride);
    if (!status.provider) {
      providerHealthLoading = false;
      providerHealth = null;
      return;
    }
    if (!status.configured) {
      providerHealthLoading = false;
      providerHealth = {
        provider: status.provider,
        configured: false,
        running: instance?.status === "running",
        live_ok: false,
        status: "error",
        reason: "missing_api_key",
      };
      return;
    }

    const now = Date.now();
    if (!force && now - lastProviderProbeAt < 15_000) return;
    lastProviderProbeAt = now;
    providerHealthLoading = true;
    try {
      providerHealth = await api.getProviderHealth(component, name);
    } catch {
      providerHealth = {
        provider: status.provider,
        configured: true,
        running: instance?.status === "running",
        live_ok: false,
        status: "error",
        reason: "probe_request_failed",
      };
    } finally {
      providerHealthLoading = false;
    }
  }

  async function refreshUsage() {
    usageLoading = true;
    try {
      usageData = await api.getUsage(component, name, usageWindow);
    } catch {
      usageData = {
        window: usageWindow,
        rows: [],
        totals: {
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          requests: 0,
        },
      };
    } finally {
      usageLoading = false;
    }
  }

  async function refresh() {
    try {
      const status = await api.getStatus();
      const instances = status.instances || {};
      if (instances[component] && instances[component][name]) {
        instance = instances[component][name];
      }
    } catch (e) {
      console.error(e);
    }
    // Fetch config (best-effort)
    let loadedConfig: any = null;
    try {
      loadedConfig = await api.getConfig(component, name);
      config = loadedConfig;
    } catch {
      config = null;
      providerHealth = null;
    }
    await refreshProviderHealth(false, loadedConfig);
    await refreshUsage();
    // Fetch installed UI modules (best-effort)
    try {
      const res = await api.getUiModules();
      uiModules = res.modules || {};
    } catch {
      /* ignore */
    }
  }

  $effect(() => {
    usageWindow;
    if (!component || !name) return;
    void refreshUsage();
  });

  onMount(() => {
    refresh();
    const interval = setInterval(refresh, 3000);
    return () => clearInterval(interval);
  });

  async function start() {
    loading = true;
    instance = { ...instance, status: "starting" };
    try {
      await api.startInstance(component, name);
      await refresh();
      await refreshProviderHealth(true);
    } catch {
      instance = { ...instance, status: "stopped" };
    } finally {
      loading = false;
    }
  }
  async function stop() {
    loading = true;
    instance = { ...instance, status: "stopping" };
    try {
      await api.stopInstance(component, name);
      await refresh();
      await refreshProviderHealth(true);
    } catch {
      instance = { ...instance, status: "running" };
    } finally {
      loading = false;
    }
  }
  async function restart() {
    loading = true;
    instance = { ...instance, status: "restarting" };
    try {
      await api.restartInstance(component, name);
      await refresh();
      await refreshProviderHealth(true);
    } catch {
    } finally {
      loading = false;
    }
  }
  async function remove() {
    if (confirm("Are you sure you want to delete this instance?")) {
      loading = true;
      try {
        await api.deleteInstance(component, name);
        window.location.href = "/";
      } catch (e) {
        console.error(e);
      } finally {
        loading = false;
      }
    }
  }
  async function setMode(mode: string) {
    await api.patchInstance(component, name, { launch_mode: mode });
    await refresh();
  }
  async function toggleAutoStart() {
    await api.patchInstance(component, name, {
      auto_start: !instance?.auto_start,
    });
    await refresh();
  }
</script>

<div class="instance-detail">
  <div class="detail-header">
    <div>
      <h1>{name}</h1>
      <span class="component-tag">{component}</span>
    </div>
    <div class="actions">
      <button class="btn" onclick={start} disabled={loading}>Start</button>
      <button class="btn" onclick={stop} disabled={loading}>Stop</button>
      <button class="btn" onclick={restart} disabled={loading}>Restart</button>
      <button class="btn danger" onclick={remove} disabled={loading}
        >Delete</button
      >
    </div>
  </div>

  <div class="tabs">
    <button
      class:active={activeTab === "overview"}
      onclick={() => (activeTab = "overview")}>Overview</button
    >
    <button
      class:active={activeTab === "config"}
      onclick={() => (activeTab = "config")}>Config</button
    >
    <button
      class:active={activeTab === "logs"}
      onclick={() => (activeTab = "logs")}>Logs</button
    >
    {#if (instance?.launch_mode || "gateway") === "gateway" && instance?.status === "running" && chatModuleName}
      <button
        class:active={activeTab === "chat"}
        class:disabled-tab={!chatReady}
        onclick={() => (activeTab = "chat")}
        >Chat{#if !providerStatus.configured}<span class="tab-warn">!</span
          >{/if}</button
      >
    {/if}
  </div>

  <div class="tab-content">
    {#if activeTab === "overview"}
      <div class="overview-grid">
        <div class="info-card">
          <span class="label">Status</span>
          <StatusBadge status={instance?.status || "stopped"} />
        </div>
        <div class="info-card">
          <span class="label">Version</span>
          <span>{instance?.version || "-"}</span>
        </div>
        <div class="info-card">
          <span class="label">Launch Mode</span>
          <div class="mode-selector">
            <button
              class="mode-btn"
              class:active={(instance?.launch_mode || "gateway") === "gateway"}
              onclick={() => setMode("gateway")}>Gateway</button
            >
            <button
              class="mode-btn"
              class:active={instance?.launch_mode === "agent"}
              onclick={() => setMode("agent")}>Agent</button
            >
          </div>
        </div>
        <div class="info-card">
          <span class="label">Auto Start</span>
          <button
            class="toggle-btn"
            class:on={instance?.auto_start}
            onclick={toggleAutoStart}
          >
            <span class="toggle-track"><span class="toggle-thumb"></span></span>
            {instance?.auto_start ? "On" : "Off"}
          </button>
        </div>
        {#if instance?.pid}
          <div class="info-card">
            <span class="label">PID</span>
            <span class="mono">{instance.pid}</span>
          </div>
        {/if}
        {#if instance?.status === "running" && instance?.uptime_seconds != null}
          <div class="info-card">
            <span class="label">Uptime</span>
            <span>{formatUptime(instance.uptime_seconds)}</span>
          </div>
        {/if}
        {#if instance?.port}
          <div class="info-card">
            <span class="label">Port</span>
            <span class="mono">{instance.port}</span>
          </div>
        {/if}
        {#if instance?.restart_count}
          <div class="info-card">
            <span class="label">Restart Count</span>
            <span>{instance.restart_count}</span>
          </div>
        {/if}
        {#if providerStatus.provider}
          <div class="info-card" class:card-warn={providerCardWarn}>
            <span class="label">Provider</span>
            <div class="provider-status">
              <span
                class="status-dot"
                class:ok={providerDotOk}
                class:err={!providerDotOk}
              ></span>
              <span>{providerStatus.provider}</span>
            </div>
            {#if providerHintText}
              <span class="provider-hint">{providerHintText}</span>
            {/if}
          </div>
        {/if}
        {#if providerStatus.model}
          <div class="info-card">
            <span class="label">Model</span>
            <span>{providerStatus.model}</span>
          </div>
        {/if}
        {#if webPort}
          <div class="info-card">
            <span class="label">Web Channel Port</span>
            <span class="mono">{webPort}</span>
          </div>
        {/if}
        <div class="info-card usage-card">
          <div class="usage-header">
            <span class="label">LLM Usage</span>
            <select class="usage-window" bind:value={usageWindow}>
              <option value="24h">24h</option>
              <option value="7d">7d</option>
              <option value="30d">30d</option>
              <option value="all">All</option>
            </select>
          </div>
          {#if usageLoading}
            <span class="usage-empty">Loading usage...</span>
          {:else if !usageData?.rows || usageData.rows.length === 0}
            <span class="usage-empty">No usage data for selected window.</span>
          {:else}
            <div class="usage-table-wrap">
              <table class="usage-table">
                <thead>
                  <tr>
                    <th>Provider</th>
                    <th>Model</th>
                    <th>To provider (prompt)</th>
                    <th>From provider (completion)</th>
                    <th>Total</th>
                    <th>Requests</th>
                    <th>Last used</th>
                  </tr>
                </thead>
                <tbody>
                  {#each [...usageData.rows].sort((a, b) => (b.total_tokens || 0) - (a.total_tokens || 0)) as row}
                    <tr>
                      <td>{row.provider}</td>
                      <td class="mono">{row.model}</td>
                      <td>{formatTokens(row.prompt_tokens)}</td>
                      <td>{formatTokens(row.completion_tokens)}</td>
                      <td>{formatTokens(row.total_tokens)}</td>
                      <td>{row.requests || 0}</td>
                      <td>{formatLastUsed(row.last_used)}</td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}
          {#if usageData?.totals}
            <div class="usage-total">
              Total: {formatTokens(usageData.totals.total_tokens)} tokens in {usageData.totals.requests || 0} request(s)
            </div>
          {/if}
        </div>
      </div>
    {:else if activeTab === "config"}
      <ConfigEditor {component} {name} />
    {:else if activeTab === "logs"}
      <LogViewer {component} {name} />
    {:else if activeTab === "chat"}
      {#if !providerStatus.configured}
        <div class="chat-blocked">
          <div class="chat-blocked-icon">!</div>
          <div class="chat-blocked-title">LLM Provider Not Configured</div>
          <div class="chat-blocked-desc">
            No API key found for provider <code
              >{providerStatus.provider || "unknown"}</code
            >. Set up a provider API key in the
            <button class="link-btn" onclick={() => (activeTab = "config")}
              >Config</button
            > tab to use chat.
          </div>
          {#if providerStatus.model}
            <div class="chat-blocked-model">
              Model: <code
                >{providerStatus.provider}/{providerStatus.model}</code
              >
            </div>
          {/if}
        </div>
      {:else if !webPort}
        <div class="chat-unavailable">
          Web channel not configured for this instance.
        </div>
      {:else}
        <ChatPanel
          port={webPort}
          moduleName={chatModuleName}
          moduleVersion={chatModuleVersion}
        />
      {/if}
    {/if}
  </div>
</div>

<style>
  .instance-detail {
    padding: 2rem;
    max-width: 1200px;
    margin: 0 auto;
  }
  .detail-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 2rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    padding-bottom: 1rem;
  }
  .detail-header h1 {
    font-size: 2rem;
    font-weight: 700;
    margin-bottom: 0.5rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
  }
  .component-tag {
    padding: 0.25rem 0.5rem;
    background: color-mix(in srgb, var(--border) 20%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .actions {
    display: flex;
    gap: 0.75rem;
  }
  .btn {
    padding: 0.5rem 1rem;
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    background: var(--bg-surface);
    color: var(--accent);
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }
  .btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
    text-shadow: 0 0 8px var(--accent);
  }
  .btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    box-shadow: none;
    text-shadow: none;
  }
  .btn.danger {
    color: var(--error);
    border-color: color-mix(in srgb, var(--error) 50%, transparent);
    text-shadow: 0 0 5px var(--error);
  }
  .btn.danger:hover {
    background: color-mix(in srgb, var(--error) 15%, transparent);
    border-color: var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 50%, transparent);
  }
  .tabs {
    display: flex;
    gap: 0;
    border-bottom: 1px solid var(--border);
    margin-bottom: 1.5rem;
  }
  .tabs button {
    padding: 0.75rem 1.5rem;
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    color: var(--fg-dim);
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .tabs button:hover {
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 5%, transparent);
  }
  .tabs button.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    text-shadow: var(--text-glow);
  }
  .tab-content {
    min-height: 400px;
  }
  .overview-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
    gap: 1.5rem;
  }
  .info-card {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    backdrop-filter: blur(4px);
    transition: all 0.2s ease;
  }
  .info-card:hover {
    border-color: color-mix(in srgb, var(--accent) 50%, transparent);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
  }
  .usage-card {
    grid-column: 1 / -1;
  }
  .usage-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
  }
  .usage-window {
    min-width: 90px;
    padding: 0.25rem 0.5rem;
    background: var(--bg-surface);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }
  .usage-window:focus {
    outline: none;
    border-color: var(--accent);
  }
  .usage-table-wrap {
    overflow-x: auto;
  }
  .usage-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }
  .usage-table th,
  .usage-table td {
    text-align: left;
    padding: 0.5rem 0.625rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 70%, transparent);
    white-space: nowrap;
  }
  .usage-table th {
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-size: 0.6875rem;
  }
  .usage-table td {
    color: var(--fg);
  }
  .usage-empty {
    color: var(--fg-dim);
    font-size: 0.8125rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .usage-total {
    margin-top: 0.5rem;
    color: var(--fg-dim);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .label {
    font-size: 0.75rem;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }
  .mode-selector {
    display: flex;
    gap: 0.5rem;
  }
  .mode-btn {
    padding: 0.375rem 0.75rem;
    border: 1px solid var(--border);
    border-radius: 2px;
    background: var(--bg-surface);
    color: var(--fg-dim);
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .mode-btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent-dim);
    color: var(--fg);
  }
  .mode-btn.active {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    border-color: var(--accent);
    color: var(--accent);
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 5px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  .toggle-btn {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    background: none;
    border: none;
    color: var(--fg);
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    padding: 0;
  }
  .toggle-track {
    position: relative;
    width: 36px;
    height: 20px;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.5);
  }
  .toggle-thumb {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    background: var(--fg-dim);
    border-radius: 2px;
    transition: all 0.2s ease;
  }
  .toggle-btn.on .toggle-track {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: inset 0 0 8px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  .toggle-btn.on .toggle-thumb {
    transform: translateX(16px);
    background: var(--accent);
    box-shadow: 0 0 5px var(--border-glow);
  }
  .mono {
    font-family: var(--font-mono);
    color: var(--accent);
    text-shadow: var(--text-glow);
    font-size: 0.875rem;
  }
  .chat-unavailable {
    color: var(--fg-dim);
    text-align: center;
    padding: 4rem;
    font-size: 1rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    border: 1px dashed var(--border);
    background: var(--bg-surface);
    border-radius: 4px;
  }
  .tab-warn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    border-radius: 2px;
    background: color-mix(in srgb, var(--warning, #f59e0b) 20%, transparent);
    color: var(--warning, #f59e0b);
    border: 1px solid var(--warning, #f59e0b);
    font-size: 0.7rem;
    font-weight: 700;
    margin-left: 0.5rem;
    vertical-align: middle;
    box-shadow: 0 0 5px var(--warning, #f59e0b);
  }
  .disabled-tab {
    opacity: 0.5;
  }
  .chat-blocked {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 4rem 2rem;
    gap: 1rem;
    text-align: center;
    border: 1px dashed var(--warning, #f59e0b);
    background: color-mix(in srgb, var(--warning, #f59e0b) 5%, transparent);
    border-radius: 4px;
  }
  .chat-blocked-icon {
    width: 64px;
    height: 64px;
    border-radius: 4px;
    background: color-mix(in srgb, var(--warning, #f59e0b) 15%, transparent);
    border: 1px solid var(--warning, #f59e0b);
    color: var(--warning, #f59e0b);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 2rem;
    font-weight: 700;
    text-shadow: 0 0 8px var(--warning, #f59e0b);
    box-shadow: 0 0 15px
      color-mix(in srgb, var(--warning, #f59e0b) 30%, transparent);
  }
  .chat-blocked-title {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--warning, #f59e0b);
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: 0 0 5px var(--warning, #f59e0b);
  }
  .chat-blocked-desc {
    color: var(--fg);
    font-size: 0.9rem;
    max-width: 450px;
    line-height: 1.6;
  }
  .chat-blocked-desc code {
    padding: 0.125rem 0.375rem;
    background: color-mix(in srgb, var(--warning, #f59e0b) 10%, transparent);
    border: 1px solid
      color-mix(in srgb, var(--warning, #f59e0b) 30%, transparent);
    border-radius: 2px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--warning, #f59e0b);
  }
  .chat-blocked-model {
    color: var(--fg-dim);
    font-size: 0.8125rem;
    margin-top: 0.5rem;
  }
  .chat-blocked-model code {
    padding: 0.125rem 0.375rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--accent);
  }
  .link-btn {
    background: none;
    border: none;
    color: var(--warning, #f59e0b);
    cursor: pointer;
    font-size: inherit;
    text-decoration: underline;
    font-weight: 700;
    padding: 0;
  }
  .link-btn:hover {
    text-shadow: 0 0 5px var(--warning, #f59e0b);
  }
  .card-warn {
    border-color: color-mix(in srgb, var(--warning, #f59e0b) 40%, transparent);
    background: color-mix(in srgb, var(--warning, #f59e0b) 5%, transparent);
  }
  .provider-status {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-family: var(--font-mono);
    font-size: 0.875rem;
  }
  .status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }
  .status-dot.ok {
    background: var(--success, #22c55e);
    box-shadow: 0 0 8px var(--success, #22c55e);
  }
  .status-dot.err {
    background: var(--warning, #f59e0b);
    box-shadow: 0 0 8px var(--warning, #f59e0b);
  }
  .provider-hint {
    font-size: 0.75rem;
    color: var(--warning, #f59e0b);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
    margin-top: 0.25rem;
  }
</style>
