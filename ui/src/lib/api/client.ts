const BASE = '/api';

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
  getComponents: () => request<any>('/components'),
  getInstances: () => request<any>('/instances'),
  getWizard: (component: string) => request<any>(`/wizard/${component}`),
  getVersions: (component: string) => request<any>(`/wizard/${component}/versions`),
  getFreePort: () => request<any>('/free-port'),
  postWizard: (component: string, data: any) =>
    request<any>(`/wizard/${component}`, { method: 'POST', body: JSON.stringify(data) }),
  startInstance: (c: string, n: string, mode?: string) =>
    request<any>(`/instances/${c}/${n}/start`, {
      method: 'POST',
      body: mode ? JSON.stringify({ launch_mode: mode }) : undefined
    }),
  stopInstance: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/stop`, { method: 'POST' }),
  restartInstance: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/restart`, { method: 'POST' }),
  deleteInstance: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}`, { method: 'DELETE' }),
  getConfig: (c: string, n: string) => request<any>(`/instances/${c}/${n}/config`),
  getProviderHealth: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/provider-health`),
  getUsage: (c: string, n: string, window: '24h' | '7d' | '30d' | 'all' = '24h') =>
    request<any>(`/instances/${c}/${n}/usage?window=${window}`),
  putConfig: (c: string, n: string, config: any) =>
    request<any>(`/instances/${c}/${n}/config`, { method: 'PUT', body: JSON.stringify(config) }),
  getLogs: (c: string, n: string, lines = 100) =>
    request<any>(`/instances/${c}/${n}/logs?lines=${lines}`),
  clearLogs: (c: string, n: string) =>
    request<any>(`/instances/${c}/${n}/logs`, { method: 'DELETE' }),
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
};
