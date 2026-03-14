export function encodePathSegment(value: string): string {
  return encodeURIComponent(value);
}

const uiRoot = '/orchestration';
const apiRoot = '/orchestration';
const workflowsBase = `${uiRoot}/workflows`;
const runsBase = `${uiRoot}/runs`;
const storeBase = `${apiRoot}/store`;

export const orchestrationUiRoutes = {
  dashboard: () => uiRoot,
  workflows: () => workflowsBase,
  newWorkflow: () => `${workflowsBase}/new`,
  workflow: (id: string) => `${workflowsBase}/${encodePathSegment(id)}`,
  runs: () => runsBase,
  run: (id: string) => `${runsBase}/${encodePathSegment(id)}`,
  runFork: (id: string) => `${runsBase}/${encodePathSegment(id)}/fork`,
  store: () => `${uiRoot}/store`,
};

export const orchestrationApiPaths = {
  workflows: () => `${apiRoot}/workflows`,
  workflow: (id: string) => `${apiRoot}/workflows/${encodePathSegment(id)}`,
  workflowValidate: (id: string) => `${apiRoot}/workflows/${encodePathSegment(id)}/validate`,
  workflowRun: (id: string) => `${apiRoot}/workflows/${encodePathSegment(id)}/run`,
  runs: () => `${apiRoot}/runs`,
  run: (id: string) => `${apiRoot}/runs/${encodePathSegment(id)}`,
  runCancel: (id: string) => `${apiRoot}/runs/${encodePathSegment(id)}/cancel`,
  runResume: (id: string) => `${apiRoot}/runs/${encodePathSegment(id)}/resume`,
  runReplay: (id: string) => `${apiRoot}/runs/${encodePathSegment(id)}/replay`,
  runState: (id: string) => `${apiRoot}/runs/${encodePathSegment(id)}/state`,
  runsFork: () => `${apiRoot}/runs/fork`,
  runCheckpoints: (runId: string) => `${apiRoot}/runs/${encodePathSegment(runId)}/checkpoints`,
  runCheckpoint: (runId: string, checkpointId: string) => `${apiRoot}/runs/${encodePathSegment(runId)}/checkpoints/${encodePathSegment(checkpointId)}`,
  runStream: (runId: string) => `${apiRoot}/runs/${encodePathSegment(runId)}/stream`,
  storeNamespace: (namespace: string) => `${storeBase}/${encodePathSegment(namespace)}`,
  storeEntry: (namespace: string, key: string) => `${storeBase}/${encodePathSegment(namespace)}/${encodePathSegment(key)}`,
};
