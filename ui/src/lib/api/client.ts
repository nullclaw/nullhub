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
    throw new Error(body?.error || `HTTP ${res.status}`);
  }
  return res.json();
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
  listWorkflows: () => request<any[]>('/orchestration/workflows'),
  getWorkflow: (id: string) => request<any>(`/orchestration/workflows/${id}`),
  createWorkflow: (data: any) => request<any>('/orchestration/workflows', { method: 'POST', body: JSON.stringify(data) }),
  updateWorkflow: (id: string, data: any) => request<any>(`/orchestration/workflows/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteWorkflow: (id: string) => request<void>(`/orchestration/workflows/${id}`, { method: 'DELETE' }),
  validateWorkflow: (id: string) => request<any>(`/orchestration/workflows/${id}/validate`, { method: 'POST' }),
  runWorkflow: (id: string, input: any) => request<any>(`/orchestration/workflows/${id}/run`, { method: 'POST', body: JSON.stringify(input) }),

  // Orchestration - Runs
  listRuns: (params?: { status?: string; workflow_id?: string }) => request<any[]>(withQuery('/orchestration/runs', params ?? {})),
  getRun: (id: string) => request<any>(`/orchestration/runs/${id}`),
  cancelRun: (id: string) => request<void>(`/orchestration/runs/${id}/cancel`, { method: 'POST' }),
  resumeRun: (id: string, updates: any) => request<any>(`/orchestration/runs/${id}/resume`, { method: 'POST', body: JSON.stringify({ state_updates: updates }) }),
  forkRun: (checkpointId: string, overrides?: any) => request<any>('/orchestration/runs/fork', { method: 'POST', body: JSON.stringify({ checkpoint_id: checkpointId, state_overrides: overrides }) }),
  injectState: (id: string, updates: any, afterStep?: string) => request<any>(`/orchestration/runs/${id}/state`, { method: 'POST', body: JSON.stringify({ updates, apply_after_step: afterStep }) }),

  // Orchestration - Checkpoints
  listCheckpoints: (runId: string) => request<any[]>(`/orchestration/runs/${runId}/checkpoints`),
  getCheckpoint: (runId: string, cpId: string) => request<any>(`/orchestration/runs/${runId}/checkpoints/${cpId}`),

  // Store API (proxied through NullBoiler or direct to NullTickets)
  storeList: (namespace: string) => request<any[]>(`/orchestration/store/${namespace}`),
  storeGet: (namespace: string, key: string) => request<any>(`/orchestration/store/${namespace}/${key}`),
  storePut: (namespace: string, key: string, value: any) => request<any>(`/orchestration/store/${namespace}/${key}`, { method: 'PUT', body: JSON.stringify({ value }) }),
  storeDelete: (namespace: string, key: string) => request<void>(`/orchestration/store/${namespace}/${key}`, { method: 'DELETE' }),

  // Orchestration - SSE
  streamRun: (runId: string, onEvent: (event: { type: string; data: any }) => void) => {
    const source = new EventSource(`${BASE}/orchestration/runs/${runId}/stream`);
    source.onmessage = (e) => onEvent({ type: 'message', data: JSON.parse(e.data) });
    ['state_update', 'step_started', 'step_completed', 'step_failed', 'agent_event', 'interrupted', 'run_completed', 'run_failed', 'send_progress'].forEach(type => {
      source.addEventListener(type, (e: any) => onEvent({ type, data: JSON.parse(e.data) }));
    });
    return source;
  },
};
