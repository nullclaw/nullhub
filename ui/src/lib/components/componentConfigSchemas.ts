export type GenericFieldType =
  | "text"
  | "password"
  | "number"
  | "toggle"
  | "select"
  | "list"
  | "json"
  | "textarea";

export interface GenericFieldDef {
  key: string;
  label: string;
  type: GenericFieldType;
  default?: any;
  options?: string[];
  hint?: string;
  min?: number;
  max?: number;
  step?: number;
  rows?: number;
}

export interface GenericSectionDef {
  key: string;
  label: string;
  description?: string;
  fields: GenericFieldDef[];
}

const nullboilerSections: GenericSectionDef[] = [
  {
    key: "service",
    label: "Service",
    description: "Core API and local storage settings.",
    fields: [
      { key: "host", label: "Bind Host", type: "text", default: "127.0.0.1" },
      { key: "port", label: "API Port", type: "number", default: 8080, min: 1, max: 65535 },
      { key: "db", label: "Database Path", type: "text", default: "nullboiler.db" },
      { key: "api_token", label: "API Token", type: "password" },
      { key: "strategies_dir", label: "Strategies Directory", type: "text", default: "strategies" },
      {
        key: "workers",
        label: "Workers JSON",
        type: "json",
        default: [],
        rows: 8,
        hint: "Array of push-mode worker definitions.",
      },
    ],
  },
  {
    key: "engine",
    label: "Engine",
    description: "Push-mode orchestration timing, retries, and worker health controls.",
    fields: [
      { key: "engine.poll_interval_ms", label: "Poll Interval", type: "number", default: 500, min: 1 },
      { key: "engine.default_timeout_ms", label: "Default Timeout", type: "number", default: 300000, min: 1 },
      { key: "engine.default_max_attempts", label: "Default Max Attempts", type: "number", default: 1, min: 1 },
      { key: "engine.health_check_interval_ms", label: "Health Check Interval", type: "number", default: 30000, min: 1 },
      { key: "engine.worker_failure_threshold", label: "Worker Failure Threshold", type: "number", default: 3, min: 1 },
      { key: "engine.worker_circuit_breaker_ms", label: "Circuit Breaker Duration", type: "number", default: 60000, min: 1 },
      { key: "engine.retry_base_delay_ms", label: "Retry Base Delay", type: "number", default: 1000, min: 0 },
      { key: "engine.retry_max_delay_ms", label: "Retry Max Delay", type: "number", default: 30000, min: 0 },
      { key: "engine.retry_jitter_ms", label: "Retry Jitter", type: "number", default: 250, min: 0 },
      { key: "engine.retry_max_elapsed_ms", label: "Retry Max Elapsed", type: "number", default: 900000, min: 0 },
      { key: "engine.shutdown_grace_ms", label: "Shutdown Grace", type: "number", default: 30000, min: 0 },
    ],
  },
  {
    key: "tracker",
    label: "Tracker",
    description: "Native NullTickets pull-mode connection and lease management.",
    fields: [
      { key: "tracker.url", label: "Tracker URL", type: "text" },
      { key: "tracker.api_token", label: "Tracker API Token", type: "password" },
      { key: "tracker.agent_id", label: "Agent ID", type: "text", default: "nullboiler" },
      { key: "tracker.poll_interval_ms", label: "Tracker Poll Interval", type: "number", default: 10000, min: 1 },
      { key: "tracker.stall_timeout_ms", label: "Stall Timeout", type: "number", default: 300000, min: 1 },
      { key: "tracker.lease_ttl_ms", label: "Lease TTL", type: "number", default: 60000, min: 1 },
      { key: "tracker.heartbeat_interval_ms", label: "Heartbeat Interval", type: "number", default: 30000, min: 1 },
      { key: "tracker.workflows_dir", label: "Workflows Directory", type: "text", default: "workflows" },
    ],
  },
  {
    key: "concurrency",
    label: "Concurrency",
    description: "Global and scoped claim limits for tracker mode.",
    fields: [
      { key: "tracker.concurrency.max_concurrent_tasks", label: "Max Concurrent Tasks", type: "number", default: 1, min: 1 },
      {
        key: "tracker.concurrency.per_pipeline",
        label: "Per-Pipeline Limits",
        type: "json",
        default: {},
        rows: 6,
        hint: 'JSON map like {"pipeline-id": 2}',
      },
      {
        key: "tracker.concurrency.per_role",
        label: "Per-Role Limits",
        type: "json",
        default: {},
        rows: 6,
        hint: 'JSON map like {"reviewer": 1}',
      },
    ],
  },
  {
    key: "workspace",
    label: "Workspace",
    description: "Per-task workspace root and lifecycle hooks.",
    fields: [
      { key: "tracker.workspace.root", label: "Workspace Root", type: "text", default: "workspaces" },
      { key: "tracker.workspace.hook_timeout_ms", label: "Hook Timeout", type: "number", default: 30000, min: 1 },
      { key: "tracker.workspace.hooks.after_create", label: "After Create Hook", type: "text" },
      { key: "tracker.workspace.hooks.before_run", label: "Before Run Hook", type: "text" },
      { key: "tracker.workspace.hooks.after_run", label: "After Run Hook", type: "text" },
      { key: "tracker.workspace.hooks.before_remove", label: "Before Remove Hook", type: "text" },
    ],
  },
  {
    key: "subprocess",
    label: "Subprocess",
    description: "Default executor settings for spawned NullClaw-compatible subprocesses.",
    fields: [
      { key: "tracker.subprocess.command", label: "Command", type: "text", default: "nullclaw" },
      {
        key: "tracker.subprocess.args",
        label: "Arguments",
        type: "list",
        default: [],
        rows: 4,
        hint: "One argument per line.",
      },
      { key: "tracker.subprocess.base_port", label: "Base Port", type: "number", default: 9200, min: 1, max: 65535 },
      { key: "tracker.subprocess.health_check_retries", label: "Health Check Retries", type: "number", default: 10, min: 1 },
      { key: "tracker.subprocess.max_turns", label: "Max Turns", type: "number", default: 20, min: 1 },
      { key: "tracker.subprocess.turn_timeout_ms", label: "Turn Timeout", type: "number", default: 600000, min: 1 },
      {
        key: "tracker.subprocess.continuation_prompt",
        label: "Continuation Prompt",
        type: "textarea",
        default: "Continue working on this task. Your previous context is preserved.",
        rows: 4,
      },
    ],
  },
];

const nullticketsSections: GenericSectionDef[] = [
  {
    key: "service",
    label: "Service",
    description: "Core tracker process settings.",
    fields: [
      { key: "port", label: "API Port", type: "number", default: 7700, min: 1, max: 65535 },
      { key: "db", label: "Database Path", type: "text", default: "nulltickets.db" },
      { key: "api_token", label: "API Token", type: "password" },
    ],
  },
];

export function getComponentConfigSchema(component: string): GenericSectionDef[] {
  switch (component) {
    case "nullboiler":
      return nullboilerSections;
    case "nulltickets":
      return nullticketsSections;
    default:
      return [];
  }
}

export function supportsStructuredConfig(component: string): boolean {
  return getComponentConfigSchema(component).length > 0;
}
