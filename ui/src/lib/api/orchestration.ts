import { orchestrationApiPaths } from '$lib/orchestration/routes';

type RequestFn = <T>(path: string, options?: RequestInit) => Promise<T>;
type WithQueryFn = (
  path: string,
  params: Record<string, string | number | boolean | null | undefined>,
) => string;

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

function normalizeEventType(type: string | undefined): string {
  if (!type) return 'message';
  if (type === 'run.interrupted') return 'interrupted';
  return type.replaceAll('.', '_');
}

function normalizeStreamEvent(raw: any): { type: string; data: any; timestamp?: number } {
  const timestampMs = typeof raw?.ts_ms === 'number'
    ? raw.ts_ms
    : typeof raw?.timestamp_ms === 'number'
      ? raw.timestamp_ms
      : undefined;

  return {
    type: normalizeEventType(raw?.event || raw?.type || raw?.kind),
    data: raw?.data ?? raw,
    timestamp: timestampMs != null ? timestampMs / 1000 : undefined,
  };
}

export function createOrchestrationApi(request: RequestFn, withQuery: WithQueryFn) {
  return {
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
    listRuns: async (params?: { status?: string; workflow_id?: string }) => {
      const raw = await request<any>(withQuery(orchestrationApiPaths.runs(), params ?? {}));
      const list = Array.isArray(raw) ? raw : raw?.items ?? [];
      return list.map(normalizeRun);
    },
    getRun: async (id: string) => normalizeRun(await request<any>(orchestrationApiPaths.run(id))),
    cancelRun: (id: string) => request<any>(orchestrationApiPaths.runCancel(id), { method: 'POST' }),
    resumeRun: (id: string, updates: any) => request<any>(orchestrationApiPaths.runResume(id), { method: 'POST', body: JSON.stringify({ state_updates: updates }) }),
    forkRun: (checkpointId: string, overrides?: any) => request<any>(orchestrationApiPaths.runsFork(), { method: 'POST', body: JSON.stringify({ checkpoint_id: checkpointId, state_overrides: overrides }) }),
    replayRun: (id: string, checkpointId: string) => request<any>(orchestrationApiPaths.runReplay(id), { method: 'POST', body: JSON.stringify({ from_checkpoint_id: checkpointId }) }),
    injectState: (id: string, updates: any, afterStep?: string) => request<any>(orchestrationApiPaths.runState(id), { method: 'POST', body: JSON.stringify({ updates, apply_after_step: afterStep }) }),
    listCheckpoints: async (runId: string) => {
      const cps = await request<any[]>(orchestrationApiPaths.runCheckpoints(runId));
      return (cps || []).map(normalizeCheckpoint);
    },
    getCheckpoint: async (runId: string, cpId: string) => normalizeCheckpoint(await request<any>(orchestrationApiPaths.runCheckpoint(runId, cpId))),
    storeList: (namespace: string) => request<any[]>(orchestrationApiPaths.storeNamespace(namespace)),
    storeGet: (namespace: string, key: string) => request<any>(orchestrationApiPaths.storeEntry(namespace, key)),
    storePut: (namespace: string, key: string, value: any) => request<void>(orchestrationApiPaths.storeEntry(namespace, key), { method: 'PUT', body: JSON.stringify({ value }) }),
    storeDelete: (namespace: string, key: string) => request<void>(orchestrationApiPaths.storeEntry(namespace, key), { method: 'DELETE' }),
    streamRun: (runId: string, onEvent: (event: { type: string; data: any; timestamp?: number }) => void) => {
      let active = true;
      let deliveredInitialSnapshot = false;
      let afterSeq = 0;

      const emitEvent = (ev: any) => {
        if (!active) return;
        onEvent(normalizeStreamEvent(ev));
      };

      const poll = async () => {
        while (active) {
          try {
            const res = await request<any>(withQuery(orchestrationApiPaths.runStream(runId), {
              after_seq: afterSeq > 0 ? afterSeq : undefined,
            }));
            if (!active) break;
            if (res?.stream_events) {
              for (const ev of res.stream_events) emitEvent(ev);
            }
            if (!deliveredInitialSnapshot && res?.events) {
              for (const ev of res.events) emitEvent(ev);
              deliveredInitialSnapshot = true;
            }
            if (typeof res?.next_stream_seq === 'number') {
              afterSeq = Math.max(afterSeq, res.next_stream_seq);
            }
            if (res?.status && ['completed', 'failed', 'cancelled'].includes(res.status)) {
              break;
            }
          } catch {
            if (!active) break;
            // Ignore poll errors, will retry.
          }
          if (!active) break;
          await new Promise(r => setTimeout(r, 1000));
        }
      };

      void poll();
      return { close: () => { active = false; } } as EventSource;
    },
  };
}
