<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";

  type ServiceInfo = {
    status: string;
    message: string;
    registered: boolean;
    running: boolean;
    service_type: string;
    unit_path: string;
  };

  let settings = $state<any>({
    port: 19800,
    host: "127.0.0.1",
    auth_token: null,
    auto_update_check: true,
    access: null,
  });
  let saving = $state(false);
  let serviceLoading = $state(false);
  let serviceAction = $state<"status" | "install" | "uninstall" | null>(null);
  let messageTone = $state<"success" | "error">("success");
  let message = $state("");
  let service = $state<ServiceInfo>({
    status: "ok",
    message: "",
    registered: false,
    running: false,
    service_type: "",
    unit_path: "",
  });

  const serviceButtonLabel = $derived.by(() => {
    if (serviceLoading) {
      if (serviceAction === "install") return "Enabling...";
      if (serviceAction === "uninstall") return "Disabling...";
      return "Checking...";
    }
    return service.registered ? "Disable Autostart" : "Enable Autostart";
  });

  onMount(async () => {
    try {
      settings = await api.getSettings();
    } catch (e) {
      console.error(e);
    }

    await refreshServiceStatus();
  });

  function setMessage(text: string, tone: "success" | "error" = "success") {
    message = text;
    messageTone = tone;
  }

  function applyServiceStatus(data: any) {
    service = {
      status: typeof data?.status === "string" ? data.status : "ok",
      message: typeof data?.message === "string" ? data.message : "",
      registered: !!data?.registered,
      running: !!data?.running,
      service_type: typeof data?.service_type === "string" ? data.service_type : "",
      unit_path: typeof data?.unit_path === "string" ? data.unit_path : "",
    };
  }

  async function refreshServiceStatus(showErrorMessage = true) {
    serviceLoading = true;
    serviceAction = "status";
    try {
      const data = await api.serviceStatus();
      applyServiceStatus(data);
      if (data?.status === "error" && showErrorMessage) {
        setMessage(data?.message || "Failed to load service status", "error");
      }
    } catch (e) {
      applyServiceStatus({
        status: "error",
        message: (e as Error).message || "Failed to load service status",
      });
      if (showErrorMessage) {
        setMessage(`Error: ${(e as Error).message}`, "error");
      }
    } finally {
      serviceLoading = false;
      serviceAction = null;
    }
  }

  async function toggleService() {
    const enabling = !service.registered;
    serviceLoading = true;
    serviceAction = enabling ? "install" : "uninstall";
    try {
      const data = enabling ? await api.serviceInstall() : await api.serviceUninstall();
      applyServiceStatus(data);
      if (data?.status === "error") {
        setMessage(data?.message || "Failed to update service", "error");
        return;
      }

      await refreshServiceStatus(false);
      setMessage(data?.message || (enabling ? "Service enabled" : "Service disabled"));
    } catch (e) {
      setMessage(`Error: ${(e as Error).message}`, "error");
    } finally {
      serviceLoading = false;
      serviceAction = null;
    }
  }

  async function save() {
    saving = true;
    try {
      const { access, ...payload } = settings;
      await api.putSettings(payload);
      setMessage("Settings saved");
    } catch (e) {
      setMessage(`Error: ${(e as Error).message}`, "error");
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
      <label for="settings-port">Port</label>
      <input id="settings-port" type="number" bind:value={settings.port} />
    </div>
    <div class="field">
      <label for="settings-host">Host</label>
      <input id="settings-host" type="text" bind:value={settings.host} />
    </div>
  </div>

  <div class="settings-section">
    <h2>Security</h2>
    <div class="field">
      <label for="settings-auth-token">Auth Token</label>
      <input
        id="settings-auth-token"
        type="password"
        bind:value={settings.auth_token}
        placeholder="Leave empty to disable"
      />
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
    <p class="hint">
      Register NullHub as a system service for automatic startup
    </p>
    <div class="service-panel">
      <div class="service-status-grid">
        <div class="service-status-row">
          <span class="service-status-label">Autostart</span>
          <span class="service-pill" class:active={service.registered} class:inactive={!service.registered}>
            {service.registered ? "Enabled" : "Disabled"}
          </span>
        </div>
        <div class="service-status-row">
          <span class="service-status-label">Runtime</span>
          <span class="service-pill" class:active={service.running} class:inactive={!service.running}>
            {service.running ? "Running" : "Stopped"}
          </span>
        </div>
        {#if service.service_type}
          <div class="service-detail">
            <span class="service-status-label">Service Type</span>
            <code>{service.service_type}</code>
          </div>
        {/if}
        {#if service.unit_path}
          <div class="service-detail">
            <span class="service-status-label">Unit Path</span>
            <code>{service.unit_path}</code>
          </div>
        {/if}
      </div>
      <div class="service-actions">
        <button class="btn" disabled={serviceLoading} onclick={toggleService}>
          {serviceButtonLabel}
        </button>
        <button class="btn secondary-btn" disabled={serviceLoading} onclick={() => refreshServiceStatus()}>
          Refresh Status
        </button>
      </div>
    </div>
  </div>

  {#if message}
    <div class="message" class:message-error={messageTone === "error"}>{message}</div>
  {/if}

  <div class="actions">
    <button class="primary-btn" onclick={save} disabled={saving}>
      {saving ? "Saving..." : "Save Settings"}
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
    font-weight: 700;
    margin-bottom: 2rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .settings-section {
    padding-bottom: 1.5rem;
    margin-bottom: 1.5rem;
    border-bottom: 1px dashed color-mix(in srgb, var(--border) 50%, transparent);
  }

  .settings-section:last-of-type {
    border-bottom: none;
  }

  h2 {
    font-size: 1.125rem;
    font-weight: 700;
    margin-bottom: 1rem;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: 0 0 2px var(--accent-dim);
  }

  .field {
    margin-bottom: 1.25rem;
  }

  .field label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 700;
    color: var(--fg-dim);
    margin-bottom: 0.5rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .field input[type="text"],
  .field input[type="number"],
  .field input[type="password"] {
    width: 100%;
    padding: 0.625rem 0.875rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .field input[type="text"]:focus,
  .field input[type="number"]:focus,
  .field input[type="password"]:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .field input::placeholder {
    color: color-mix(in srgb, var(--fg-dim) 50%, transparent);
  }

  .toggle-field {
    display: flex !important;
    align-items: center;
    gap: 0.75rem;
    cursor: pointer;
    font-size: 0.875rem;
    color: var(--fg) !important;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .toggle-field input[type="checkbox"] {
    width: 1.25rem;
    height: 1.25rem;
    accent-color: var(--accent);
    cursor: pointer;
    filter: drop-shadow(0 0 4px var(--accent-dim));
  }

  .hint {
    font-size: 0.8125rem;
    color: var(--fg-dim);
    margin-top: 0.5rem;
    line-height: 1.5;
    font-family: var(--font-mono);
  }

  .service-panel {
    display: grid;
    gap: 1rem;
    margin-top: 0.75rem;
  }

  .service-status-grid {
    display: grid;
    gap: 0.75rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, var(--border) 60%, transparent);
    border-radius: var(--radius);
    background: color-mix(in srgb, var(--bg-surface) 80%, transparent);
  }

  .service-status-row,
  .service-detail {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
  }

  .service-status-label {
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .service-pill {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 5.5rem;
    padding: 0.25rem 0.75rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
    background: color-mix(in srgb, var(--bg-surface) 75%, transparent);
  }

  .service-pill.active {
    color: var(--success);
    border-color: color-mix(in srgb, var(--success) 65%, transparent);
    box-shadow: 0 0 8px color-mix(in srgb, var(--success) 25%, transparent);
  }

  .service-pill.inactive {
    color: var(--fg-dim);
    border-color: color-mix(in srgb, var(--border) 80%, transparent);
  }

  .service-detail {
    align-items: flex-start;
  }

  .service-detail code {
    max-width: 28rem;
    white-space: normal;
    word-break: break-all;
    text-align: right;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
  }

  .service-actions {
    display: flex;
    gap: 0.75rem;
    flex-wrap: wrap;
  }

  .btn {
    padding: 0.5rem 1.25rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    margin-top: 0.75rem;
    text-shadow: var(--text-glow);
  }

  .secondary-btn {
    color: var(--fg-dim);
    border-color: color-mix(in srgb, var(--border) 80%, transparent);
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
    text-shadow: 0 0 5px var(--success);
  }

  .message.message-error {
    background: color-mix(in srgb, var(--error) 10%, transparent);
    border-color: var(--error);
    color: var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 30%, transparent);
    text-shadow: 0 0 5px var(--error);
  }

  .actions {
    padding-top: 1rem;
    border-top: 1px solid var(--border);
    display: flex;
    justify-content: flex-end;
  }

  .primary-btn {
    padding: 0.75rem 2rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 10px
      color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow:
      0 0 15px var(--border-glow),
      inset 0 0 15px color-mix(in srgb, var(--accent) 40%, transparent);
    text-shadow: 0 0 10px var(--accent);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    box-shadow: none;
    text-shadow: none;
  }

  @media (max-width: 640px) {
    .service-status-row,
    .service-detail {
      flex-direction: column;
      align-items: flex-start;
    }

    .service-detail code {
      text-align: left;
    }
  }
</style>
