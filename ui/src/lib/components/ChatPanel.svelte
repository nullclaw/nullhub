<script lang="ts">
  import { api } from "$lib/api/client";
  import ModuleFrame from "./ModuleFrame.svelte";

  let {
    port = 0,
    moduleName = "",
    moduleVersion = "",
    instanceKey = "",
    onboardingPending = false,
    starterMessage = "Wake up, my friend!",
    onboardingMarker = "",
  } = $props<{
    port?: number;
    moduleName?: string;
    moduleVersion?: string;
    instanceKey?: string;
    onboardingPending?: boolean;
    starterMessage?: string;
    onboardingMarker?: string;
  }>();

  type HistorySession = {
    session_id: string;
    message_count: number;
  };

  type HistoryMessage = {
    role: string;
    content: string;
    created_at: string;
  };

  type ChatSeedMessage = {
    id: string;
    role: "user" | "assistant" | "system";
    content: string;
    timestamp: number;
  };

  const DEFAULT_HISTORY_LIMIT = 200;

  const wsUrl = $derived(port > 0 ? `ws://127.0.0.1:${port}/ws` : "");
  const hasModule = $derived(moduleName.length > 0 && moduleVersion.length > 0);
  const mountKey = $derived(`${instanceKey}:${moduleName}:${moduleVersion}:${wsUrl}`);

  let historyReady = $state(false);
  let initialMessages = $state<ChatSeedMessage[]>([]);
  let historyRequestSeq = 0;

  function safeSessionStorageGet(key: string): string | null {
    if (typeof sessionStorage === "undefined") return null;
    try {
      return sessionStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function safeSessionStorageSet(key: string, value: string) {
    if (typeof sessionStorage === "undefined") return;
    try {
      sessionStorage.setItem(key, value);
    } catch {
      /* ignore storage failures */
    }
  }

  function bootstrapAutostartKey(instance: string, marker: string): string {
    const suffix = marker.trim().length > 0 ? marker.trim() : "default";
    return `nullhub:bootstrap-autostart:${instance}:${suffix}`;
  }

  function shouldAutoStartBootstrap(
    instance: string,
    marker: string,
    pending: boolean,
    messages: ChatSeedMessage[],
  ): boolean {
    if (!pending || messages.length > 0 || !instance) return false;
    return safeSessionStorageGet(bootstrapAutostartKey(instance, marker)) !== "1";
  }

  function markBootstrapAutostarted(instance: string, marker: string) {
    if (!instance) return;
    safeSessionStorageSet(bootstrapAutostartKey(instance, marker), "1");
  }

  let autoSendMessage = $derived.by(() => {
    if (!shouldAutoStartBootstrap(instanceKey, onboardingMarker, onboardingPending, initialMessages)) {
      return "";
    }
    return starterMessage.trim();
  });

  function parseInstanceKey(value: string): { component: string; name: string } | null {
    const slashIndex = value.indexOf("/");
    if (slashIndex <= 0 || slashIndex === value.length - 1) return null;
    return {
      component: value.slice(0, slashIndex),
      name: value.slice(slashIndex + 1),
    };
  }

  function historyRoleToChatRole(role: string): ChatSeedMessage["role"] {
    switch ((role || "").toLowerCase()) {
      case "assistant":
        return "assistant";
      case "system":
      case "tool":
        return "system";
      default:
        return "user";
    }
  }

  async function loadLatestHistory(component: string, name: string): Promise<ChatSeedMessage[]> {
    const sessions = await api.getHistory(component, name, { limit: 1, offset: 0 });
    const latestSession = Array.isArray(sessions?.sessions)
      ? (sessions.sessions[0] as HistorySession | undefined)
      : undefined;
    if (!latestSession?.session_id) return [];

    const totalMessages = Math.max(0, Number(latestSession.message_count || 0));
    if (totalMessages === 0) return [];

    const limit = Math.min(DEFAULT_HISTORY_LIMIT, totalMessages);
    const offset = Math.max(totalMessages - limit, 0);
    const transcript = await api.getHistory(component, name, {
      sessionId: latestSession.session_id,
      limit,
      offset,
    });
    const messages = Array.isArray(transcript?.messages)
      ? (transcript.messages as HistoryMessage[])
      : [];

    return messages.map((message, index) => {
      const parsedTimestamp = Date.parse(message.created_at || "");
      return {
        id: `history-${latestSession.session_id}-${offset + index}`,
        role: historyRoleToChatRole(message.role),
        content: message.content || "",
        timestamp: Number.isFinite(parsedTimestamp) ? parsedTimestamp : Date.now() + index,
      };
    });
  }

  $effect(() => {
    const parsed = parseInstanceKey(instanceKey);
    if (!hasModule || !wsUrl || !parsed) {
      initialMessages = [];
      historyReady = true;
      return;
    }

    const requestSeq = ++historyRequestSeq;
    historyReady = false;
    initialMessages = [];

    void loadLatestHistory(parsed.component, parsed.name)
      .then((messages) => {
        if (requestSeq !== historyRequestSeq) return;
        initialMessages = messages;
        historyReady = true;
      })
      .catch(() => {
        if (requestSeq !== historyRequestSeq) return;
        initialMessages = [];
        historyReady = true;
      });
  });
</script>

<div class="chat-panel">
  {#if hasModule && wsUrl}
    {#if historyReady}
      {#key mountKey}
        <ModuleFrame
          {moduleName}
          {moduleVersion}
          instanceUrl={wsUrl}
          moduleProps={{
            wsUrl,
            pairingCode: "123456",
            initialMessages,
            autoSendMessage,
            onAutoSend: () => markBootstrapAutostarted(instanceKey, onboardingMarker),
          }}
        />
      {/key}
    {:else}
      <div class="chat-unavailable">Loading chat history...</div>
    {/if}
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
