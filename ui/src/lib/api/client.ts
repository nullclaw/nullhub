import { orchestrationApiPaths } from '$lib/orchestration/routes';

const BASE = '/api';

function withQuery(path: string, params: Record<string, string | number | boolean | null | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === null || value === undefined || value === '') continue;
    search.set(key, String(value));
  }
  const query = search.toString();
  return query ? `${path}?${query}` : path;
}

export { encodePathSegment } from '$lib/orchestration/routes';

export type LogSource = 'instance' | 'nullhub';
type InstanceStartOptions = {
  launch_mode?: string;
  verbose?: boolean;
};

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...options
  });
  if (!res.ok) {
    const body = await res.json().catch(() => null);
    const errMsg = typeof body?.error === 'string' ? body.error : body?.error?.message || `HTTP ${res.status}`;
    throw new Error(errMsg);
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  if (!text) return undefined as T;
  return JSON.parse(text);
}

function msToIso(ms: number | undefined | null): string | undefined {
  if (ms == null) return undefined;
  return new Date(ms).toISOString();
}

function tryParseJson(val: string | undefined | null): any {
  if (!val) return undefined;
  try { return JSON.parse(val); } catch { return val; }
}

function normalizeWorkflow(raw: any): any {
  if (!raw) return raw;
  // NullBoiler wraps nodes/edges inside a `definition` JSON string
  const def = raw.definition ? tryParseJson(raw.definition) : null;
  return {
    ...raw,
    nodes: raw.nodes ?? def?.nodes ?? {},
    edges: raw.edges ?? def?.edges ?? [],
    state_schema: raw.state_schema ?? def?.state_schema,
    created_at: raw.created_at ?? msToIso(raw.created_at_ms),
    updated_at: raw.updated_at ?? msToIso(raw.updated_at_ms),
  };
}

function normalizeStep(step: any): any {
  if (!step) return step;
  return {
    ...step,
    node_id: step.node_id ?? step.def_step_id ?? step.step,
  };
}

function normalizeRun(raw: any): any {
  if (!raw) return raw;
  const steps = raw.steps ? raw.steps.map(normalizeStep) : raw.steps;
  return {
    ...raw,
    steps,
    state: raw.state ?? tryParseJson(raw.state_json),
    workflow: raw.workflow ?? tryParseJson(raw.workflow_json),
    input: raw.input ?? tryParseJson(raw.input_json),
    config: raw.config ?? tryParseJson(raw.config_json),
    created_at: raw.created_at ?? msToIso(raw.created_at_ms),
    completed_at: raw.completed_at ?? raw.ended_at ?? msToIso(raw.ended_at_ms),
    updated_at: raw.updated_at ?? msToIso(raw.updated_at_ms),
    started_at: raw.started_at ?? msToIso(raw.started_at_ms),
    interrupt_message: raw.interrupt_message ?? raw.error_text,
  };
}

function normalizeCheckpoint(raw: any): any {
  if (!raw) return raw;
  return {
    ...raw,
    state: raw.state ?? tryParseJson(raw.state_json),
    completed_nodes: raw.completed_nodes ?? tryParseJson(raw.completed_nodes_json),
    metadata: raw.metadata ?? tryParseJson(raw.metadata_json),
    created_at: raw.created_at ?? msToIso(raw.created_at_ms),
    step_name: raw.step_name ?? raw.step_id,
    after_step: raw.after_step ?? raw.step_id,
  };
}

function normalizeValidation(raw: any): any {
  if (!raw) return raw;
  if (raw.errors && Array.isArray(raw.errors) && raw.errors.length > 0 && typeof raw.errors[0] === 'object') {
    return { ...raw, errors: raw.errors.map((e: any) => e.message || `${e.type || e.err_type}: ${e.key || e.node || 'unknown'}`) };
  }
  return raw;
}

export const api = {
  getStatus: () => request<any>('/status'),
  getGlobalUsage: (window: '24h' | '7d' | '30d' | 'all' = '24h') =>
    request<any>(`/usage?window=${window}`),
  getComponents: () => request<any>('/components'),
  getInstances: () => request<any>('/instances'),
  getWizard: (component: string) => request<any>(`/wizard/${component}`),
  getVersions: (component: string) => request<any>(`/wizard/${component}/versions`),
  getWizardModels: (component: string, provider: string, apiKey = '') =>
    request<any>(`/wizard/${component}/models`, {
      method: 'POST',
      body: JSON.stringify({ provider, api_key: apiKey }),
    }),
  getFreePort: () => request<any>('/free-port'),
  postWizard: (component: string, data: any) =>
    request<any>(`/wizard/${component}`, { method: 'POST', body: JSON.stringify(data) }),
  startInstance: (c: string, n: string, modeOrOptions?: string | InstanceStartOptions) =>
    request<any>(`/instances/${c}/${n}/start`, {
      method: 'POST',
      body:
        typeof modeOrOptions === 'string'
          ? JSON.stringify({ launch_mode: modeOrOptions })
          : modeOrOptions
            ? JSON.stringify(modeOrOptions)
            : undefined
    }),
  stopInstance: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/stop`, { method: 'POST' }),
  restartInstance: (c: string, n: string, options?: InstanceStartOptions) =>
    request<any>(`/instances/${c}/${n}/restart`, {
      method: 'POST',
      body: options ? JSON.stringify(options) : undefined
    }),
  deleteInstance: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}`, { method: 'DELETE' }),
  getConfig: (c: string, n: string) => request<any>(`/instances/${c}/${n}/config`),
  getProviderHealth: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/provider-health`),
  getUsage: (c: string, n: string, window: '24h' | '7d' | '30d' | 'all' = '24h') =>
    request<any>(`/instances/${c}/${n}/usage?window=${window}`),
  getHistory: (c: string, n: string, params?: { sessionId?: string; limit?: number; offset?: number }) =>
    request<any>(
      withQuery(`/instances/${c}/${n}/history`, {
        session_id: params?.sessionId,
        limit: params?.limit,
        offset: params?.offset,
      }),
    ),
  getOnboarding: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/onboarding`),
  getMemory: (
    c: string,
    n: string,
    params?: { stats?: boolean; key?: string; query?: string; category?: string; limit?: number },
  ) =>
    request<any>(
      withQuery(`/instances/${c}/${n}/memory`, {
        stats: params?.stats ? 1 : undefined,
        key: params?.key,
        query: params?.query,
        category: params?.category,
        limit: params?.limit,
      }),
    ),
  getSkills: (c: string, n: string, name?: string) =>
    request<any>(withQuery(`/instances/${c}/${n}/skills`, { name })),
  getIntegration: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/integration`),
  linkIntegration: (c: string, n: string, payload: any) =>
    request<any>(`/instances/${c}/${n}/integration`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  putConfig: (c: string, n: string, config: any) =>
    request<any>(`/instances/${c}/${n}/config`, { method: 'PUT', body: JSON.stringify(config) }),
  getLogs: (c: string, n: string, lines = 100, source: LogSource = 'instance') =>
    request<any>(withQuery(`/instances/${c}/${n}/logs`, { lines, source })),
  clearLogs: (c: string, n: string, source: LogSource = 'instance') =>
    request<any>(withQuery(`/instances/${c}/${n}/logs`, { source }), { method: 'DELETE' }),
  getUpdates: () => request<any>('/updates'),
  getSettings: () => request<any>('/settings'),
  putSettings: (settings: any) =>
    request<any>('/settings', { method: 'PUT', body: JSON.stringify(settings) }),

  patchConfig: (c: string, n: string, config: any) =>
    request<any>(`/instances/${c}/${n}/config`, { method: 'PATCH', body: JSON.stringify(config) }),

  patchInstance: (c: string, n: string, settings: any) =>
    request<any>(`/instances/${c}/${n}`, { method: 'PATCH', body: JSON.stringify(settings) }),

  getComponentManifest: (name: string) => request<any>(`/components/${name}/manifest`),

  refreshComponents: () => request<any>('/components/refresh', { method: 'POST' }),

  applyUpdate: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/update`, { method: 'POST' }),

  serviceInstall: () => request<any>('/service/install', { method: 'POST' }),

  serviceUninstall: () => request<any>('/service/uninstall', { method: 'POST' }),

  serviceStatus: () => request<any>('/service/status'),

  importInstance: (component: string) =>
    request<any>(`/instances/${component}/import`, { method: 'POST' }),

  getUiModules: () => request<{ modules: Record<string, string> }>('/ui-modules'),
  getAvailableUiModules: () => request<{ name: string; repo: string; component: string }[]>('/ui-modules/available'),
  installUiModule: (name: string) => request<any>(`/ui-modules/${name}/install`, { method: 'POST' }),
  uninstallUiModule: (name: string) => request<any>(`/ui-modules/${name}`, { method: 'DELETE' }),

  validateProviders: (component: string, providers: any[]) =>
    request<any>(`/wizard/${component}/validate-providers`, {
      method: 'POST',
      body: JSON.stringify({ providers }),
    }),

  validateChannels: (component: string, channels: Record<string, any>) =>
    request<any>(`/wizard/${component}/validate-channels`, {
      method: 'POST',
      body: JSON.stringify({ channels }),
    }),

  // Saved providers
  getSavedProviders: (reveal = false) =>
    request<any>(`/providers${reveal ? '?reveal=true' : ''}`),
  createSavedProvider: (data: { provider: string; api_key: string; model?: string }) =>
    request<any>('/providers', { method: 'POST', body: JSON.stringify(data) }),
  updateSavedProvider: (id: string, data: { name?: string; api_key?: string; model?: string }) =>
    request<any>(`/providers/${id.replace('sp_', '')}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteSavedProvider: (id: string) =>
    request<any>(`/providers/${id.replace('sp_', '')}`, { method: 'DELETE' }),
  revalidateSavedProvider: (id: string) =>
    request<any>(`/providers/${id.replace('sp_', '')}/validate`, { method: 'POST' }),

  // Saved channels
  getSavedChannels: (reveal = false) =>
    request<any>(`/channels${reveal ? '?reveal=true' : ''}`),
  createSavedChannel: (data: { channel_type: string; account: string; config: Record<string, any> }) =>
    request<any>('/channels', { method: 'POST', body: JSON.stringify(data) }),
  updateSavedChannel: (id: string, data: { name?: string; account?: string; config?: Record<string, any> }) =>
    request<any>(`/channels/${id.replace('sc_', '')}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteSavedChannel: (id: string) =>
    request<any>(`/channels/${id.replace('sc_', '')}`, { method: 'DELETE' }),
  revalidateSavedChannel: (id: string) =>
    request<any>(`/channels/${id.replace('sc_', '')}/validate`, { method: 'POST' }),

  // Orchestration - Workflows
  listWorkflows: async () => {
    const raw = await request<any>(orchestrationApiPaths.workflows());
    const list = Array.isArray(raw) ? raw : raw?.items ?? [];
    return list.map(normalizeWorkflow);
  },
  getWorkflow: async (id: string) => normalizeWorkflow(await request<any>(orchestrationApiPaths.workflow(id))),
  createWorkflow: (data: any) => request<any>(orchestrationApiPaths.workflows(), { method: 'POST', body: JSON.stringify(data) }),
  updateWorkflow: (id: string, data: any) => request<any>(orchestrationApiPaths.workflow(id), { method: 'PUT', body: JSON.stringify(data) }),
  deleteWorkflow: (id: string) => request<any>(orchestrationApiPaths.workflow(id), { method: 'DELETE' }),
  validateWorkflow: async (id: string) => normalizeValidation(await request<any>(orchestrationApiPaths.workflowValidate(id), { method: 'POST' })),
  runWorkflow: (id: string, input: any) => request<any>(orchestrationApiPaths.workflowRun(id), { method: 'POST', body: JSON.stringify(input) }),

  // Orchestration - Runs
  listRuns: async (params?: { status?: string; workflow_id?: string }) => {
    const raw = await request<any>(withQuery(orchestrationApiPaths.runs(), params ?? {}));
    // NullBoiler returns paginated {items, limit, offset, has_more} or raw array
    const list = Array.isArray(raw) ? raw : raw?.items ?? [];
    return list.map(normalizeRun);
  },
  getRun: async (id: string) => normalizeRun(await request<any>(orchestrationApiPaths.run(id))),
  cancelRun: (id: string) => request<any>(orchestrationApiPaths.runCancel(id), { method: 'POST' }),
  resumeRun: (id: string, updates: any) => request<any>(orchestrationApiPaths.runResume(id), { method: 'POST', body: JSON.stringify({ state_updates: updates }) }),
  forkRun: (checkpointId: string, overrides?: any) => request<any>(orchestrationApiPaths.runsFork(), { method: 'POST', body: JSON.stringify({ checkpoint_id: checkpointId, state_overrides: overrides }) }),
  replayRun: (id: string, checkpointId: string) => request<any>(orchestrationApiPaths.runReplay(id), { method: 'POST', body: JSON.stringify({ from_checkpoint_id: checkpointId }) }),
  injectState: (id: string, updates: any, afterStep?: string) => request<any>(orchestrationApiPaths.runState(id), { method: 'POST', body: JSON.stringify({ updates, apply_after_step: afterStep }) }),

  // Orchestration - Checkpoints
  listCheckpoints: async (runId: string) => {
    const cps = await request<any[]>(orchestrationApiPaths.runCheckpoints(runId));
    return (cps || []).map(normalizeCheckpoint);
  },
  getCheckpoint: async (runId: string, cpId: string) => normalizeCheckpoint(await request<any>(orchestrationApiPaths.runCheckpoint(runId, cpId))),

  // Store API (proxied through NullBoiler or direct to NullTickets)
  storeList: (namespace: string) => request<any[]>(orchestrationApiPaths.storeNamespace(namespace)),
  storeGet: (namespace: string, key: string) => request<any>(orchestrationApiPaths.storeEntry(namespace, key)),
  storePut: (namespace: string, key: string, value: any) => request<void>(orchestrationApiPaths.storeEntry(namespace, key), { method: 'PUT', body: JSON.stringify({ value }) }),
  storeDelete: (namespace: string, key: string) => request<void>(orchestrationApiPaths.storeEntry(namespace, key), { method: 'DELETE' }),

  // Orchestration - Stream (poll-based: NullBoiler returns JSON, not true SSE)
  // NullBoiler's HTTP/1.1 server returns complete JSON responses, not held-open
  // SSE connections. We poll every 1 second to approximate real-time streaming.
  streamRun: (runId: string, onEvent: (event: { type: string; data: any }) => void) => {
    let active = true;
    let deliveredInitialSnapshot = false;

    const emitEvent = (ev: any) => {
      onEvent({ type: ev.event || ev.type || ev.kind || 'message', data: ev.data ?? ev });
    };

    const poll = async () => {
      while (active) {
        try {
          const res = await request<any>(orchestrationApiPaths.runStream(runId));
          // NullBoiler returns {status, state?, events, stream_events}
          if (res?.stream_events) {
            for (const ev of res.stream_events) {
              emitEvent(ev);
            }
          }
          if (!deliveredInitialSnapshot && res?.events) {
            for (const ev of res.events) {
              emitEvent(ev);
            }
            deliveredInitialSnapshot = true;
          }
          // Stop polling if run is terminal
          if (res?.status && ['completed', 'failed', 'cancelled'].includes(res.status)) {
            break;
          }
        } catch {
          // Ignore poll errors, will retry
        }
        await new Promise(r => setTimeout(r, 1000));
      }
    };
    void poll();
    // Return an object with close() for cleanup compatibility
    return { close: () => { active = false; } } as EventSource;
  },
};
