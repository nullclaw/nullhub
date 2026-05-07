const std = @import("std");
const helpers = @import("helpers.zig");

pub const ParamSpec = struct {
    name: []const u8,
    location: []const u8,
    required: bool,
    description: []const u8,
};

pub const ExampleSpec = struct {
    command: []const u8,
    description: []const u8,
};

pub const RouteSpec = struct {
    id: []const u8,
    method: []const u8,
    path_template: []const u8,
    category: []const u8,
    summary: []const u8,
    destructive: bool = false,
    auth_required: bool = false,
    auth_mode: []const u8 = "optional_bearer",
    path_params: []const ParamSpec = &.{},
    query_params: []const ParamSpec = &.{},
    body: ?[]const u8 = null,
    response: ?[]const u8 = null,
    examples: []const ExampleSpec = &.{},
};

const Document = struct {
    version: u32,
    routes: []const RouteSpec,
};

const component_param = ParamSpec{
    .name = "component",
    .location = "path",
    .required = true,
    .description = "Component name such as nullclaw, nullhub, nullboiler, or nulltickets.",
};

const instance_name_param = ParamSpec{
    .name = "name",
    .location = "path",
    .required = true,
    .description = "Instance name within the component namespace.",
};

const module_name_param = ParamSpec{
    .name = "module",
    .location = "path",
    .required = true,
    .description = "UI module name.",
};

const component_name_param = ParamSpec{
    .name = "name",
    .location = "path",
    .required = true,
    .description = "Component name.",
};

const wizard_component_param = ParamSpec{
    .name = "component",
    .location = "path",
    .required = true,
    .description = "Component to inspect or configure through the setup wizard.",
};

const provider_id_param = ParamSpec{
    .name = "id",
    .location = "path",
    .required = true,
    .description = "Saved provider numeric identifier.",
};

const channel_id_param = ParamSpec{
    .name = "id",
    .location = "path",
    .required = true,
    .description = "Saved channel numeric identifier.",
};

const window_query = ParamSpec{
    .name = "window",
    .location = "query",
    .required = false,
    .description = "Usage window such as 24h, 7d, 30d, or all.",
};

const reveal_query = ParamSpec{
    .name = "reveal",
    .location = "query",
    .required = false,
    .description = "When true, include secret-like fields in the response for local admin usage.",
};

const lines_query = ParamSpec{
    .name = "lines",
    .location = "query",
    .required = false,
    .description = "How many log lines to return. Defaults to 100.",
};

const log_source_query = ParamSpec{
    .name = "source",
    .location = "query",
    .required = false,
    .description = "Log source selector: instance or nullhub.",
};

const history_limit_query = ParamSpec{
    .name = "limit",
    .location = "query",
    .required = false,
    .description = "Maximum number of history entries to return.",
};

const history_offset_query = ParamSpec{
    .name = "offset",
    .location = "query",
    .required = false,
    .description = "History pagination offset.",
};

const history_session_query = ParamSpec{
    .name = "session_id",
    .location = "query",
    .required = false,
    .description = "Optional nullclaw session identifier to scope history.",
};

const memory_stats_query = ParamSpec{
    .name = "stats",
    .location = "query",
    .required = false,
    .description = "When set, returns memory stats instead of entries.",
};

const memory_key_query = ParamSpec{
    .name = "key",
    .location = "query",
    .required = false,
    .description = "Fetch a single memory record by key.",
};

const memory_query_query = ParamSpec{
    .name = "query",
    .location = "query",
    .required = false,
    .description = "Keyword search query for instance memory.",
};

const memory_q_query = ParamSpec{
    .name = "q",
    .location = "query",
    .required = false,
    .description = "Short alias for the instance memory search query.",
};

const memory_category_query = ParamSpec{
    .name = "category",
    .location = "query",
    .required = false,
    .description = "Category filter for memory listing.",
};

const memory_limit_query = ParamSpec{
    .name = "limit",
    .location = "query",
    .required = false,
    .description = "Maximum number of memory results.",
};

const memory_offset_query = ParamSpec{
    .name = "offset",
    .location = "query",
    .required = false,
    .description = "Pagination offset for memory listing.",
};

const memory_include_internal_query = ParamSpec{
    .name = "include_internal",
    .location = "query",
    .required = false,
    .description = "When true, include internal/bootstrap memory keys in list responses.",
};

const memory_session_query = ParamSpec{
    .name = "session_id",
    .location = "query",
    .required = false,
    .description = "Optional nullclaw session identifier to scope memory reads or writes.",
};

const named_query = ParamSpec{
    .name = "name",
    .location = "query",
    .required = false,
    .description = "Optional name selector for detail routes implemented as query parameters.",
};

const session_query = ParamSpec{
    .name = "session_id",
    .location = "query",
    .required = false,
    .description = "Session identifier for detail or termination routes implemented as query parameters.",
};

const skill_name_query = ParamSpec{
    .name = "name",
    .location = "query",
    .required = false,
    .description = "Optional skill name filter.",
};

const skill_catalog_query = ParamSpec{
    .name = "catalog",
    .location = "query",
    .required = false,
    .description = "When true, return the recommended skill catalog instead of installed skills.",
};

const instance_channel_type_param = ParamSpec{
    .name = "channel_type",
    .location = "path",
    .required = true,
    .description = "Canonical nullclaw channel type such as telegram, discord, or web.",
};

const config_path_query = ParamSpec{
    .name = "path",
    .location = "query",
    .required = false,
    .description = "Optional dotted config path such as gateway.port or models.providers.openrouter.",
};

const cron_job_id_param = ParamSpec{
    .name = "id",
    .location = "path",
    .required = true,
    .description = "Cron job identifier from the managed instance store.",
};

const common_instance_params = [_]ParamSpec{ component_param, instance_name_param };
const component_only_params = [_]ParamSpec{component_param};
const provider_id_params = [_]ParamSpec{provider_id_param};
const channel_id_params = [_]ParamSpec{channel_id_param};
const module_name_params = [_]ParamSpec{module_name_param};
const component_name_params = [_]ParamSpec{component_name_param};
const wizard_component_params = [_]ParamSpec{wizard_component_param};
const usage_query_params = [_]ParamSpec{window_query};
const reveal_query_params = [_]ParamSpec{reveal_query};
const logs_query_params = [_]ParamSpec{ lines_query, log_source_query };
const history_query_params = [_]ParamSpec{ history_session_query, history_limit_query, history_offset_query };
const memory_query_params = [_]ParamSpec{ memory_stats_query, memory_key_query, memory_query_query, memory_q_query, memory_category_query, memory_limit_query, memory_offset_query, memory_include_internal_query, memory_session_query };
const skills_query_params = [_]ParamSpec{ skill_name_query, skill_catalog_query };
const config_query_params = [_]ParamSpec{config_path_query};
const named_query_params = [_]ParamSpec{named_query};
const session_query_params = [_]ParamSpec{session_query};
const limit_query_params = [_]ParamSpec{history_limit_query};
const cron_job_id_params = [_]ParamSpec{ component_param, instance_name_param, cron_job_id_param };

const route_examples_status = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/status --pretty",
        .description = "Inspect hub health, uptime, and instance summary.",
    },
};

const route_examples_instances = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/instances --pretty",
        .description = "List all managed instances.",
    },
};

const route_examples_instance_status = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/instances/nullclaw/instance-1/status --pretty",
        .description = "Read the managed nullclaw runtime status through the instance admin boundary.",
    },
};

const route_examples_delete_instance = [_]ExampleSpec{
    .{
        .command = "nullhub api DELETE /api/instances/nullclaw/instance-2",
        .description = "Delete a managed nullclaw instance and let nullhub clean related state.",
    },
};

const route_examples_provider_validate = [_]ExampleSpec{
    .{
        .command = "nullhub api POST /api/providers/2/validate",
        .description = "Run a live provider credential probe.",
    },
};

const route_examples_skill_catalog = [_]ExampleSpec{
    .{
        .command = "nullhub api GET '/api/instances/nullclaw/instance-1/skills?catalog=1' --pretty",
        .description = "Inspect the recommended skill catalog for a managed nullclaw instance.",
    },
};

const route_examples_skill_install = [_]ExampleSpec{
    .{
        .command = "nullhub api POST /api/instances/nullclaw/instance-1/skills --body '{\"bundled\":\"nullhub-admin\"}'",
        .description = "Install the bundled nullhub-admin skill into a managed nullclaw workspace.",
    },
    .{
        .command = "nullhub api POST /api/instances/nullclaw/instance-1/skills --body '{\"clawhub_slug\":\"my-skill\"}'",
        .description = "Install a skill from ClawHub when the host has the clawhub CLI available.",
    },
    .{
        .command = "nullhub api POST /api/instances/nullclaw/instance-1/skills --body '{\"name\":\"news-digest\"}'",
        .description = "Search the skill registry and install the best matching skill through the managed nullclaw CLI.",
    },
};

const route_examples_skill_remove = [_]ExampleSpec{
    .{
        .command = "nullhub api DELETE '/api/instances/nullclaw/instance-1/skills?name=nullhub-admin'",
        .description = "Remove a workspace-installed skill from a managed nullclaw instance.",
    },
};

const route_examples_channels = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/instances/nullclaw/instance-1/channels --pretty",
        .description = "List configured channel accounts for a managed nullclaw instance.",
    },
    .{
        .command = "nullhub api GET /api/instances/nullclaw/instance-1/channels/telegram --pretty",
        .description = "Inspect all configured accounts for a specific channel type.",
    },
};

const route_examples_meta = [_]ExampleSpec{
    .{
        .command = "nullhub routes --json",
        .description = "Inspect the machine-readable route catalog locally without a running server.",
    },
    .{
        .command = "nullhub api GET /api/meta/routes --pretty",
        .description = "Fetch the same route catalog over HTTP.",
    },
};

const routes = [_]RouteSpec{
    .{
        .id = "health",
        .method = "GET",
        .path_template = "/health",
        .category = "meta",
        .summary = "Lightweight liveness probe for load balancers and local checks.",
        .auth_mode = "public",
        .response = "Returns {\"status\":\"ok\"}.",
    },
    .{
        .id = "status.get",
        .method = "GET",
        .path_template = "/api/status",
        .category = "meta",
        .summary = "Hub status, access URLs, and live instance overview.",
        .auth_mode = "optional_bearer",
        .response = "Aggregated status document used by the dashboard.",
        .examples = route_examples_status[0..],
    },
    .{
        .id = "meta.routes.get",
        .method = "GET",
        .path_template = "/api/meta/routes",
        .category = "meta",
        .summary = "Machine-readable catalog of stable nullhub HTTP routes.",
        .auth_mode = "optional_bearer",
        .response = "JSON document with route ids, methods, paths, parameters, and examples.",
        .examples = route_examples_meta[0..],
    },
    .{
        .id = "meta.spec.get",
        .method = "GET",
        .path_template = "/api/spec",
        .category = "meta",
        .summary = "Alias for the machine-readable nullhub route catalog.",
        .auth_mode = "optional_bearer",
        .response = "JSON document with route ids, methods, paths, parameters, and examples.",
    },
    .{
        .id = "components.list",
        .method = "GET",
        .path_template = "/api/components",
        .category = "components",
        .summary = "List known ecosystem components and installation state.",
        .auth_mode = "optional_bearer",
        .response = "Component array with installed/version metadata.",
    },
    .{
        .id = "components.manifest.get",
        .method = "GET",
        .path_template = "/api/components/{name}/manifest",
        .category = "components",
        .summary = "Return cached component manifest JSON if available.",
        .auth_mode = "optional_bearer",
        .path_params = component_name_params[0..],
        .response = "Manifest JSON exported by the component binary.",
    },
    .{
        .id = "components.refresh",
        .method = "POST",
        .path_template = "/api/components/refresh",
        .category = "components",
        .summary = "Refresh the component registry and cached manifests.",
        .auth_mode = "optional_bearer",
        .response = "Refresh status payload.",
    },
    .{
        .id = "wizard.free_port",
        .method = "GET",
        .path_template = "/api/free-port",
        .category = "wizard",
        .summary = "Find an available local TCP port during setup flows.",
        .auth_mode = "optional_bearer",
        .response = "Returns {\"port\":<number>}.",
    },
    .{
        .id = "usage.global.get",
        .method = "GET",
        .path_template = "/api/usage",
        .category = "usage",
        .summary = "Aggregate usage across the whole hub.",
        .auth_mode = "optional_bearer",
        .query_params = usage_query_params[0..],
        .response = "Cross-instance usage summary.",
    },
    .{
        .id = "settings.get",
        .method = "GET",
        .path_template = "/api/settings",
        .category = "settings",
        .summary = "Read hub settings and published access URLs.",
        .auth_mode = "optional_bearer",
        .response = "Current nullhub settings document.",
    },
    .{
        .id = "settings.put",
        .method = "PUT",
        .path_template = "/api/settings",
        .category = "settings",
        .summary = "Update hub settings such as port or access behavior.",
        .auth_mode = "optional_bearer",
        .body = "Settings JSON payload.",
        .response = "Saved settings payload.",
    },
    .{
        .id = "service.install",
        .method = "POST",
        .path_template = "/api/service/install",
        .category = "settings",
        .summary = "Install nullhub as an OS service.",
        .auth_mode = "optional_bearer",
        .response = "Platform-specific install result.",
    },
    .{
        .id = "service.uninstall",
        .method = "POST",
        .path_template = "/api/service/uninstall",
        .category = "settings",
        .summary = "Remove the OS service installation for nullhub.",
        .auth_mode = "optional_bearer",
        .destructive = true,
        .response = "Service uninstall result.",
    },
    .{
        .id = "service.status",
        .method = "GET",
        .path_template = "/api/service/status",
        .category = "settings",
        .summary = "Inspect whether the OS service is installed and running.",
        .auth_mode = "optional_bearer",
        .response = "Service status payload.",
    },
    .{
        .id = "updates.list",
        .method = "GET",
        .path_template = "/api/updates",
        .category = "updates",
        .summary = "List available component updates.",
        .auth_mode = "optional_bearer",
        .response = "Pending update list.",
    },
    .{
        .id = "ui_modules.list",
        .method = "GET",
        .path_template = "/api/ui-modules",
        .category = "ui",
        .summary = "List installed UI modules and selected versions.",
        .auth_mode = "optional_bearer",
        .response = "Map of UI module names to selected versions.",
    },
    .{
        .id = "ui_modules.available",
        .method = "GET",
        .path_template = "/api/ui-modules/available",
        .category = "ui",
        .summary = "List UI modules available from known component sources.",
        .auth_mode = "optional_bearer",
        .response = "Available UI module records.",
    },
    .{
        .id = "ui_modules.install",
        .method = "POST",
        .path_template = "/api/ui-modules/{module}/install",
        .category = "ui",
        .summary = "Install or refresh a UI module.",
        .auth_mode = "optional_bearer",
        .path_params = module_name_params[0..],
        .response = "Install status payload.",
    },
    .{
        .id = "ui_modules.delete",
        .method = "DELETE",
        .path_template = "/api/ui-modules/{module}",
        .category = "ui",
        .summary = "Uninstall a UI module.",
        .auth_mode = "optional_bearer",
        .path_params = module_name_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "wizard.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}",
        .category = "wizard",
        .summary = "Fetch wizard metadata and defaults for a component.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Wizard definition JSON.",
    },
    .{
        .id = "wizard.post",
        .method = "POST",
        .path_template = "/api/wizard/{component}",
        .category = "wizard",
        .summary = "Create or update a component instance from wizard form data.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Wizard submission JSON.",
        .response = "Created instance payload or validation error.",
    },
    .{
        .id = "wizard.versions.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}/versions",
        .category = "wizard",
        .summary = "List installable versions for a component.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Version options for installer flows.",
    },
    .{
        .id = "wizard.models.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}/models",
        .category = "wizard",
        .summary = "List model options for a component/provider pairing.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Model list payload.",
    },
    .{
        .id = "wizard.models.post",
        .method = "POST",
        .path_template = "/api/wizard/{component}/models",
        .category = "wizard",
        .summary = "Resolve model options from posted credentials or provider selection.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Provider/model discovery request JSON.",
        .response = "Model list payload or validation error.",
    },
    .{
        .id = "wizard.validate_providers",
        .method = "POST",
        .path_template = "/api/wizard/{component}/validate-providers",
        .category = "wizard",
        .summary = "Validate provider credentials during setup.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Provider validation request JSON.",
        .response = "Validation result array.",
    },
    .{
        .id = "wizard.validate_channels",
        .method = "POST",
        .path_template = "/api/wizard/{component}/validate-channels",
        .category = "wizard",
        .summary = "Validate channel credentials during setup.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Channel validation request JSON.",
        .response = "Validation result array.",
    },
    .{
        .id = "providers.list",
        .method = "GET",
        .path_template = "/api/providers",
        .category = "providers",
        .summary = "List saved providers.",
        .auth_mode = "optional_bearer",
        .query_params = reveal_query_params[0..],
        .response = "Saved provider list.",
    },
    .{
        .id = "providers.create",
        .method = "POST",
        .path_template = "/api/providers",
        .category = "providers",
        .summary = "Create a saved provider entry.",
        .auth_mode = "optional_bearer",
        .body = "Provider create payload.",
        .response = "Created provider record.",
    },
    .{
        .id = "providers.update",
        .method = "PUT",
        .path_template = "/api/providers/{id}",
        .category = "providers",
        .summary = "Update a saved provider entry.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .body = "Provider update payload.",
        .response = "Updated provider record.",
    },
    .{
        .id = "providers.delete",
        .method = "DELETE",
        .path_template = "/api/providers/{id}",
        .category = "providers",
        .summary = "Delete a saved provider entry.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "providers.validate",
        .method = "POST",
        .path_template = "/api/providers/{id}/validate",
        .category = "providers",
        .summary = "Run a live provider probe using the saved config.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .response = "Provider validation result.",
        .examples = route_examples_provider_validate[0..],
    },
    .{
        .id = "channels.list",
        .method = "GET",
        .path_template = "/api/channels",
        .category = "channels",
        .summary = "List saved channels.",
        .auth_mode = "optional_bearer",
        .query_params = reveal_query_params[0..],
        .response = "Saved channel list.",
    },
    .{
        .id = "channels.create",
        .method = "POST",
        .path_template = "/api/channels",
        .category = "channels",
        .summary = "Create a saved channel entry.",
        .auth_mode = "optional_bearer",
        .body = "Channel create payload.",
        .response = "Created channel record.",
    },
    .{
        .id = "channels.update",
        .method = "PUT",
        .path_template = "/api/channels/{id}",
        .category = "channels",
        .summary = "Update a saved channel entry.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .body = "Channel update payload.",
        .response = "Updated channel record.",
    },
    .{
        .id = "channels.delete",
        .method = "DELETE",
        .path_template = "/api/channels/{id}",
        .category = "channels",
        .summary = "Delete a saved channel entry.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "channels.validate",
        .method = "POST",
        .path_template = "/api/channels/{id}/validate",
        .category = "channels",
        .summary = "Run a live channel probe using the saved config.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .response = "Channel validation result.",
    },
    .{
        .id = "instances.list",
        .method = "GET",
        .path_template = "/api/instances",
        .category = "instances",
        .summary = "List all managed instances across components.",
        .auth_mode = "optional_bearer",
        .response = "Instance collection grouped by component.",
        .examples = route_examples_instances[0..],
    },
    .{
        .id = "instances.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Read a single instance detail record.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Instance detail payload.",
    },
    .{
        .id = "instances.status",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/status",
        .category = "instances",
        .summary = "Read managed nullclaw runtime status using the instance admin CLI when available.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Nullclaw-style status payload with version, pid, uptime, overall_status, and components.",
        .examples = route_examples_instance_status[0..],
    },
    .{
        .id = "instances.patch",
        .method = "PATCH",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Update instance launch metadata such as auto_start or verbose mode.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Partial instance settings JSON.",
        .response = "Updated instance status payload.",
    },
    .{
        .id = "instances.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Delete an instance and let nullhub clean its managed files.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
        .examples = route_examples_delete_instance[0..],
    },
    .{
        .id = "instances.start",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/start",
        .category = "instances",
        .summary = "Start an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Optional launch overrides such as launch_mode or verbose.",
        .response = "Start status payload.",
    },
    .{
        .id = "instances.stop",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/stop",
        .category = "instances",
        .summary = "Stop an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Stop status payload.",
    },
    .{
        .id = "instances.restart",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/restart",
        .category = "instances",
        .summary = "Restart an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Optional launch overrides such as launch_mode or verbose.",
        .response = "Restart status payload.",
    },
    .{
        .id = "instances.provider_health",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/provider-health",
        .category = "instances",
        .summary = "Probe the live provider config of an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Provider probe result.",
    },
    .{
        .id = "instances.models",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/models",
        .category = "instances",
        .summary = "List provider entries configured for a managed nullclaw instance without exposing secret values.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Instance-scoped default provider/model and provider has_key summary.",
    },
    .{
        .id = "instances.models.info",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/models?name=...",
        .category = "instances",
        .summary = "Inspect a single model/provider entry for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = named_query_params[0..],
        .response = "Model detail payload with provider and canonical name.",
    },
    .{
        .id = "instances.models.refresh",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/models",
        .category = "instances",
        .summary = "Request model catalog refresh for a managed instance. Currently returns 501 because refresh remains CLI-only.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Not implemented payload.",
    },
    .{
        .id = "instances.doctor",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/doctor",
        .category = "instances",
        .summary = "Read deep runtime health diagnostics for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Per-component diagnostic JSON with uptime, restart counts, and last error metadata.",
    },
    .{
        .id = "instances.capabilities",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/capabilities",
        .category = "instances",
        .summary = "Read the runtime capabilities manifest for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Runtime manifest with tools, channels, memory engines, and active backend.",
    },
    .{
        .id = "instances.mcp",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/mcp",
        .category = "instances",
        .summary = "List configured MCP servers or inspect one server detail via the name query parameter.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = named_query_params[0..],
        .response = "MCP server array or one server detail with redacted env keys and optional tool_count.",
    },
    .{
        .id = "instances.usage",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/usage",
        .category = "instances",
        .summary = "Read per-instance usage aggregates.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = usage_query_params[0..],
        .response = "Instance usage payload.",
    },
    .{
        .id = "instances.history",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/history",
        .category = "instances",
        .summary = "Read persisted conversation history for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = history_query_params[0..],
        .response = "Paginated history payload.",
    },
    .{
        .id = "instances.agent.invoke",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/agent",
        .category = "instances",
        .summary = "Invoke a stateful managed nullclaw agent turn.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with message plus optional session_key, provider, model, temperature, or agent.",
        .response = "Agent turn response payload.",
    },
    .{
        .id = "instances.agent.stream",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/agent-stream",
        .category = "instances",
        .summary = "Streaming agent turns are not supported through nullhub; this route returns 501.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Not implemented payload.",
    },
    .{
        .id = "instances.agent.sessions",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/agent-sessions",
        .category = "instances",
        .summary = "List agent sessions or fetch one session detail via the session_id query parameter.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = session_query_params[0..],
        .response = "Agent session list or single session metadata payload.",
    },
    .{
        .id = "instances.agent.sessions.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/agent-sessions",
        .category = "instances",
        .summary = "Terminate a managed nullclaw agent session selected by session_id.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = session_query_params[0..],
        .destructive = true,
        .response = "Session termination payload.",
    },
    .{
        .id = "instances.onboarding",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/onboarding",
        .category = "instances",
        .summary = "Read onboarding/bootstrap status for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Onboarding status payload.",
    },
    .{
        .id = "instances.memory",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/memory",
        .category = "instances",
        .summary = "Inspect instance memory stats, records, or searches.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = memory_query_params[0..],
        .response = "Memory stats or memory entry list depending on query mode.",
    },
    .{
        .id = "instances.memory.write",
        .method = "POST|PATCH|DELETE",
        .path_template = "/api/instances/{component}/{name}/memory",
        .category = "instances",
        .summary = "Create, update, or delete a managed nullclaw memory entry.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = memory_query_params[0..],
        .body = "POST/PATCH body with key, content, optional category, and optional session_id. DELETE may use query parameters.",
        .response = "Memory mutation payload.",
    },
    .{
        .id = "instances.memory.reindex",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/memory-reindex",
        .category = "instances",
        .summary = "Trigger vector reindex for a managed nullclaw memory backend.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Memory reindex result payload.",
    },
    .{
        .id = "instances.memory.drain_outbox",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/memory-drain-outbox",
        .category = "instances",
        .summary = "Drain the durable memory outbox queue for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Outbox drain result payload.",
    },
    .{
        .id = "instances.channels",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/channels",
        .category = "instances",
        .summary = "List configured channel accounts for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Configured channel account list with per-type health status.",
        .examples = route_examples_channels[0..1],
    },
    .{
        .id = "instances.channels.detail",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/channels/{channel_type}",
        .category = "instances",
        .summary = "Inspect a specific configured nullclaw channel type.",
        .auth_mode = "optional_bearer",
        .path_params = &.{ component_param, instance_name_param, instance_channel_type_param },
        .response = "Channel type detail with configured accounts and health status.",
        .examples = route_examples_channels[1..2],
    },
    .{
        .id = "instances.skills",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "List installed skills for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .response = "Skill list or single skill detail.",
    },
    .{
        .id = "instances.skills.catalog",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/skills?catalog=1",
        .category = "instances",
        .summary = "List recommended managed skills for the instance component.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .response = "Recommended skill catalog entries.",
        .examples = route_examples_skill_catalog[0..],
    },
    .{
        .id = "instances.skills.install",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "Install a skill into a managed nullclaw workspace from a bundled skill, ClawHub slug, registry search name, or source URL/path.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with exactly one of bundled, clawhub_slug, name, source, or url.",
        .response = "Install result payload.",
        .examples = route_examples_skill_install[0..],
    },
    .{
        .id = "instances.skills.remove",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "Remove a workspace-installed skill from a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .body = null,
        .response = "Remove result payload.",
        .examples = route_examples_skill_remove[0..],
    },
    .{
        .id = "instances.integration.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/integration",
        .category = "instances",
        .summary = "Read integration status for linked orchestration and tracker components.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Integration status and linkage payload.",
    },
    .{
        .id = "instances.integration.post",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/integration",
        .category = "instances",
        .summary = "Link or relink supported components such as nullboiler and nulltickets.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Integration update payload.",
        .response = "Integration update result.",
    },
    .{
        .id = "instances.import",
        .method = "POST",
        .path_template = "/api/instances/{component}/import",
        .category = "instances",
        .summary = "Import a standalone installation into nullhub management.",
        .auth_mode = "optional_bearer",
        .path_params = component_only_params[0..],
        .response = "Imported instance payload.",
    },
    .{
        .id = "instances.config.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Read the raw instance config.json managed by nullhub.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = config_query_params[0..],
        .response = "Raw instance config JSON.",
    },
    .{
        .id = "instances.config.value",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/config?path=...",
        .category = "instances",
        .summary = "Read a single dotted-path value from the managed instance config.json.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = config_query_params[0..],
        .response = "JSON object with the requested path and value.",
    },
    .{
        .id = "instances.config.put",
        .method = "PUT",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Replace the raw instance config.json managed by nullhub.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Complete config.json replacement body.",
        .response = "Save status payload.",
    },
    .{
        .id = "instances.config.patch",
        .method = "PATCH",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Patch the raw instance config.json. Currently treated the same as PUT.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Complete config.json replacement body.",
        .response = "Save status payload.",
    },
    .{
        .id = "instances.config.set",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/config-set",
        .category = "instances",
        .summary = "Set a single dotted config value through the managed nullclaw CLI boundary.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with path and value.",
        .response = "Config mutation payload.",
    },
    .{
        .id = "instances.config.unset",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/config-unset",
        .category = "instances",
        .summary = "Unset or reset a single dotted config value through the managed nullclaw CLI boundary.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with path.",
        .response = "Config mutation payload.",
    },
    .{
        .id = "instances.config.reload",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/config-reload",
        .category = "instances",
        .summary = "Validate and re-read config.json from disk for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Reload status payload.",
    },
    .{
        .id = "instances.config.validate",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/config-validate",
        .category = "instances",
        .summary = "Validate current or proposed config JSON for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Optional raw JSON config proposal.",
        .response = "Validation result payload.",
    },
    .{
        .id = "instances.cron.list",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/cron",
        .category = "instances",
        .summary = "List scheduled cron jobs for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "JSON object containing the jobs array.",
    },
    .{
        .id = "instances.cron.create",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/cron",
        .category = "instances",
        .summary = "Create a recurring shell or agent cron job for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with expression plus either command or prompt; optional model/session_target for agent jobs.",
        .response = "Created cron job payload.",
    },
    .{
        .id = "instances.cron.once",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/cron/once",
        .category = "instances",
        .summary = "Create a one-shot delayed shell or agent job for a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with delay plus either command or prompt; optional model/session_target for agent jobs.",
        .response = "Created cron job payload.",
    },
    .{
        .id = "instances.cron.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/cron/{id}",
        .category = "instances",
        .summary = "Fetch one managed cron job by identifier.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .response = "Cron job payload or 404.",
    },
    .{
        .id = "instances.cron.runs",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/cron/{id}/runs",
        .category = "instances",
        .summary = "Read paginated run history for one managed cron job.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .query_params = limit_query_params[0..],
        .response = "Cron run history payload.",
    },
    .{
        .id = "instances.cron.run",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/cron/{id}/run",
        .category = "instances",
        .summary = "Execute a managed cron job immediately.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .response = "Updated cron job payload.",
    },
    .{
        .id = "instances.cron.pause",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/cron/{id}/pause",
        .category = "instances",
        .summary = "Pause a managed cron job.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .response = "Updated cron job payload.",
    },
    .{
        .id = "instances.cron.resume",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/cron/{id}/resume",
        .category = "instances",
        .summary = "Resume a paused managed cron job.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .response = "Updated cron job payload.",
    },
    .{
        .id = "instances.cron.update",
        .method = "PATCH",
        .path_template = "/api/instances/{component}/{name}/cron/{id}",
        .category = "instances",
        .summary = "Update a managed cron job expression, payload, enabled flag, or session target.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .body = "Partial cron job update JSON.",
        .response = "Updated cron job payload.",
    },
    .{
        .id = "instances.cron.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/cron/{id}",
        .category = "instances",
        .summary = "Delete a managed cron job.",
        .auth_mode = "optional_bearer",
        .path_params = cron_job_id_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "instances.logs.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/logs",
        .category = "instances",
        .summary = "Read the log tail for an instance or its nullhub supervisor log.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .response = "Log tail payload.",
    },
    .{
        .id = "instances.logs.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/logs",
        .category = "instances",
        .summary = "Clear stored log files for an instance or its nullhub supervisor log.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "instances.logs.stream",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/logs/stream",
        .category = "instances",
        .summary = "Snapshot current log tail in a stream-shaped response.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .response = "Log stream payload.",
    },
    .{
        .id = "instances.update",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/update",
        .category = "instances",
        .summary = "Apply an available update to a managed instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Update result payload.",
    },
    .{
        .id = "orchestration.proxy",
        .method = "ANY",
        .path_template = "/api/orchestration/{...}",
        .category = "orchestration",
        .summary = "Proxy orchestration requests to NullBoiler, or store requests to NullTickets.",
        .auth_mode = "optional_bearer",
        .body = "Forwarded as-is to the orchestration backend.",
        .response = "Forwarded upstream JSON response.",
    },
    .{
        .id = "observability.proxy",
        .method = "ANY",
        .path_template = "/api/observability/{...}",
        .category = "observability",
        .summary = "Proxy observability requests to a managed or configured NullWatch instance.",
        .auth_mode = "optional_bearer",
        .body = "Forwarded as-is to NullWatch.",
        .response = "Forwarded upstream JSON response.",
    },
};

pub fn allRoutes() []const RouteSpec {
    return routes[0..];
}

pub fn isRoutesPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/meta/routes") or
        std.mem.startsWith(u8, target, "/api/meta/routes?") or
        std.mem.eql(u8, target, "/api/spec") or
        std.mem.startsWith(u8, target, "/api/spec?");
}

pub fn jsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Document{
        .version = 1,
        .routes = allRoutes(),
    }, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

pub fn textAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.print("nullhub routes ({d})\n", .{routes.len});

    var current_category: ?[]const u8 = null;
    for (allRoutes()) |route| {
        if (current_category == null or !std.mem.eql(u8, current_category.?, route.category)) {
            current_category = route.category;
            try buf.print("\n[{s}]\n", .{route.category});
        }

        try buf.print("{s: >6} {s}", .{ route.method, route.path_template });
        if (route.destructive) {
            try buf.appendSlice("  [destructive]");
        }
        try buf.appendSlice("\n");
        try buf.print("  {s}\n", .{route.summary});

        if (route.query_params.len > 0) {
            try buf.appendSlice("  query:");
            for (route.query_params, 0..) |param, index| {
                if (index > 0) try buf.appendSlice(",");
                try buf.print(" {s}", .{param.name});
            }
            try buf.appendSlice("\n");
        }
    }

    return buf.toOwnedSlice();
}

pub fn handleRoutes(allocator: std.mem.Allocator) helpers.ApiResponse {
    const body = jsonAlloc(allocator) catch return helpers.serverError();
    return helpers.jsonOk(body);
}

test "jsonAlloc includes stable route metadata" {
    const json = try jsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": \"meta.routes.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/api/instances/{component}/{name}") != null);
}

test "textAlloc renders grouped route list" {
    const text = try textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[meta]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GET /api/meta/routes") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GET /api/spec") != null);
}

test "isRoutesPath matches meta routes endpoint" {
    try std.testing.expect(isRoutesPath("/api/meta/routes"));
    try std.testing.expect(isRoutesPath("/api/meta/routes?format=json"));
    try std.testing.expect(isRoutesPath("/api/spec"));
    try std.testing.expect(isRoutesPath("/api/spec?format=json"));
    try std.testing.expect(!isRoutesPath("/api/status"));
}
